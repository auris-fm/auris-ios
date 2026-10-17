import Foundation
import PocketCastsUtils

class VoiceAsrEngine {
    private let capture: NativeAudioCapture
    private let segmenter: NativeVadSegmenter
    private let backend: AsrBackend
    private let signalFilter: SignalFilter
    private let wakeWordDetector: WakeWordDetectorProtocol
    private let gracePeriodSignal: GracePeriodSignal
    private let stageTimer: RecognitionStageTimer
    private let wakeThreshold: Float
    private let translationStage: TranslationStage?

    /// Observe-only contribution observer. Nil by default, so voice control behaves exactly as before until
    /// the Voice Sharing feature wires it; every call site below is a guarded notification that cannot change
    /// a recognition outcome.
    var contributionCollector: VoiceSharingCollector?
    /// Keeps this engine build's coordinator gate-loss registration alive exactly as long as the
    /// collector it notifies; when the engine (and its collector) die, the registration unwinds.
    var voiceSharingGateLostSubscription: AnyObject?

    private var isExposedSpeakerRoute = false
    private var playbackBuffer: [Float] = []

    /// Test seam: production fills `playbackBuffer` from the playback tap, which a unit test cannot drive
    /// without an active audio session. Setting this makes the bleed branch reachable with real correlation
    /// input instead of skipping the filter.
    var playbackBufferForTesting: [Float]? {
        get { playbackBuffer }
        set { playbackBuffer = newValue ?? [] }
    }
    var listeningMode: ListeningMode = .wakeWord

    /// Forwards the immutable routing envelope (source + English router text).
    var onRoutingInput: ((IntentRoutingInput) -> Void)?
    /// Called on every positive detection so the service can reset grace and
    /// play the `WAKE_WORD` earcon exactly once.
    var onWakeWordDetected: (() -> Void)?
    /// Called when a positive wake result leaves no routable transcript, i.e. the
    /// user woke the assistant and said nothing else. Silent by contract: the wake
    /// is the start of a session, not a failed question, so nothing is played.
    var onWakeOnly: (() -> Void)?
    /// Called when a capture was heard but cannot be routed (a translation failed,
    /// so the English-only intent model must not see it). This — not `onWakeOnly`
    /// — is what the service renders as the `ERROR` earcon: the capture was a
    /// question we could not understand, which is a different event.
    var onUnroutable: (() -> Void)?
    /// Emitted after ASR with monotonic stage durations per
    /// recognition-pipeline.md "Production Recognition Latency Metrics".
    var onStageTiming: ((PipelineStageTiming) -> Void)?

    init(
        capture: NativeAudioCapture,
        segmenter: NativeVadSegmenter,
        backend: AsrBackend,
        signalFilter: SignalFilter,
        wakeWordDetector: WakeWordDetectorProtocol,
        gracePeriodSignal: GracePeriodSignal,
        clock: MonotonicClock = SystemMonotonicClock(),
        wakeThreshold: Float = 0.8,
        translationStage: TranslationStage? = nil
    ) {
        self.capture = capture
        self.segmenter = segmenter
        self.backend = backend
        self.signalFilter = signalFilter
        self.wakeWordDetector = wakeWordDetector
        self.gracePeriodSignal = gracePeriodSignal
        self.stageTimer = RecognitionStageTimer(clock: clock)
        self.wakeThreshold = wakeThreshold
        self.translationStage = translationStage
    }

    private final class BackendReadyTaskBox {
        var task: Task<Result<Void, Error>, Never>?
    }

    private let backendReadyBox = BackendReadyTaskBox()
    private let backendReadyLock = NSLock()

    /// Kick off SenseVoice/Canary download+init before capture starts so the
    /// first wake is not blocked behind a silent backend-ready wait.
    /// Only successes are cached: a failed preload clears the task so a later
    /// `start()` (gate restart) re-attempts `ensureReady()` instead of reusing
    /// the failure forever.
    ///
    /// Concurrency note: `preloadBackend()`'s check-then-set is not atomic — two
    /// concurrent calls can both spawn `ensureReady()` (last writer wins the
    /// cache; the identity guard still prevents stale clears). Backends must
    /// therefore tolerate concurrent `ensureReady()` calls ( SenseVoice/Canary/
    /// Whisper all do: the call is idempotent per instance).
    func preloadBackend() {
        backendReadyLock.lock()
        let existing = backendReadyBox.task
        backendReadyLock.unlock()
        guard existing == nil else { return }
        let box = BackendReadyTaskBox()
        // Intentional box→task→box cycle: the strong capture keeps `box` alive
        // until the task completes so the failure path can always clear the
        // cache; the cycle frees itself when the task returns.
        let task = Task { [backend, self] in
            let result = await backend.ensureReady()
            switch result {
            case .success:
                FileLog.shared.addMessage("[VoicePipeline] backend ready \(backend.requiredModel.id)")
            case .failure(let error):
                FileLog.shared.addMessage("[VoicePipeline] backend FAILED \(backend.requiredModel.id): \(error)")
                self.clearBackendReadyTask(box)
            }
            return result
        }
        box.task = task
        backendReadyLock.lock()
        backendReadyBox.task = task
        backendReadyLock.unlock()
    }

    private func clearBackendReadyTask(_ box: BackendReadyTaskBox) {
        backendReadyLock.lock()
        defer { backendReadyLock.unlock() }
        guard let cached = backendReadyBox.task, box.task != nil, cached == box.task else { return }
        backendReadyBox.task = nil
    }

    /// Starts capture and returns whether it actually started. Capture errors
    /// are reported rather than swallowed: the caller must not treat a failed
    /// start as listening, and must release any acquired input route.
    @discardableResult
    func start() -> Bool {
        FileLog.shared.addMessage("[VoicePipeline] engine starting backend=\(backend.requiredModel.id)")
        segmenter.onUtterance = { [weak self] utterance in
            guard let self else { return }
            // Freeze, then DETACH, both synchronously before the outcome Task exists: the completed
            // segment's audio leaves `current` here, so a successor starting first cannot turn it
            // into an audio-carrying cancel, and the async outcome emits exactly once from the ring.
            let frozen = self.contributionCollector?.currentCaptureContext()
            self.contributionCollector?.segmentationEnded(frozen)
            self.beginUtteranceProcessing(utterance, preFrozenContext: frozen)
        }
        // Contribution observation attaches to the SAME segmenter the pipeline already drives, so there is
        // one segmentation truth and no second buffer. These are synchronous and observe-only: the collector
        // does its own work off these signals and never returns anything that could alter recognition.
        segmenter.onSpeechStarted = { [weak self] confirmationFrameSamples in
            self?.contributionCollector?.speechStarted(confirmationFrameSamples: confirmationFrameSamples)
        }
        segmenter.onSpeechAccumulated = { [weak self] newSamples, bufferCount in
            // Byte-for-byte handoff of the ACTUAL new PCM. No placeholder synthesis, no count-only path:
            // the collector's retained buffer grows by exactly the samples the segmenter produced.
            // The Array conversion happens only when a collector is attached — with the feature disabled
            // this callback must not allocate per frame.
            guard let collector = self?.contributionCollector else { return }
            collector.appendSamples(Array(newSamples), reportedTotal: bufferCount)
        }
        segmenter.onSpeechCancelled = { [weak self] in
            self?.contributionCollector?.speechCancelled()
        }
        capture.onSamples = { [weak self] samples in
            self?.segmenter.process(samples)
        }

        preloadBackend()

        do {
            try capture.start()
            FileLog.shared.addMessage("[VoicePipeline] engine started mode=\(listeningMode)")
            return true
        } catch {
            FileLog.shared.addMessage("[VoicePipeline] engine start failed: \(error)")
            // Clean up a partially started capture (configure succeeded, engine
            // start failed) so teardown still restores the playback category
            // and releases a session capture owned.
            capture.stop()
            return false
        }
    }

    func stop() {
        FileLog.shared.addMessage("[VoicePipeline] engine stopped")
        capture.stop()
        // Closing listening ends the current partial contribution (spec: it releases collection buffers but
        // does NOT withdraw enrollment or delete completed contributions). Routing this through the segmenter's
        // own reset keeps ONE source of truth: onSpeechCancelled fires only when speech was actually open, so
        // an idle stop is never reported as a discarded example, and a live one is released by the same hook
        // that opened it rather than by a parallel bookkeeping path that could disagree.
        let wasOpen = contributionCollector?.currentCaptureIDForTesting != nil
        segmenter.reset()
        if !wasOpen {
            // The segmenter had nothing open, so its reset emitted nothing. Ask the collector directly as a
            // no-op guard: it drops the request when it holds no capture either.
            contributionCollector?.pipelineStopped()
        }
    }

    /// Test seam: the capture→segmenter closure installed by `start()`. Reading it proves the production
    /// wiring exists without needing a live audio session; production callers use `start()` itself.
    var captureCallbackForTesting: (([Float]) -> Void)? {
        capture.onSamples
    }

    /// Test seam: the route condition the bleed branch reads. Production derives it from the audio route;
    /// forcing it here lets the branch be exercised without a simulator-wide route change.
    var isExposedSpeakerRouteForTesting: Bool {
        get { effectiveExposedSpeakerRoute }
        set { _forcedExposedRoute = newValue }
    }

    private var _forcedExposedRoute: Bool?

    /// The value every bleed check actually consults: the forced override when a test set one, otherwise the
    /// route the service reported.
    private var effectiveExposedSpeakerRoute: Bool { _forcedExposedRoute ?? isExposedSpeakerRoute }

    /// Exposed for focused translate-drop tests (`@testable`).
    /// Entry point for one segmented utterance. The capture identity is frozen SYNCHRONOUSLY here — before
    /// the Task exists — so a queued-but-not-yet-running utterance A keeps A's identity even if B starts and
    /// opens its own capture before A's body ever runs. Reading "what is current" inside the async body would
    /// hand A's audio to B.
    /// `taskBodyGate`, when provided (tests only), runs as the Task body's first statement — AFTER the
    /// freeze, so tests can hold the body back and mutate collector state in between deterministically.
    /// Test-only body gate used by the PRODUCTION closure path too, so the start()-installed
    /// `onUtterance` closure can be held mid-flight deterministically (nil in production).
    var utteranceBodyGateForTesting: (() -> Void)?

    func beginUtteranceProcessing(_ utterance: [Float], taskBodyGate: (() -> Void)? = nil) -> Task<Void, Never> {
        let frozenContext = contributionCollector?.currentCaptureContext()
        return beginUtteranceProcessing(utterance, preFrozenContext: frozenContext, taskBodyGate: taskBodyGate)
    }

    /// Outcome launch for a context ALREADY frozen synchronously (production onUtterance path).
    func beginUtteranceProcessing(_ utterance: [Float], preFrozenContext: VoiceSharingCollector.CaptureContext?, taskBodyGate: (() -> Void)? = nil) -> Task<Void, Never> {
        let bodyGate = taskBodyGate ?? utteranceBodyGateForTesting
        return Task {
            bodyGate?()
            await self.processUtterance(utterance, frozenContext: preFrozenContext)
        }
    }

    /// `frozenContext` is captured by the synchronous `onUtterance` closure BEFORE this Task was created.
    /// `processUtterance` itself must not read "current" state: by the time an async body runs, a successor
    /// may have started.
    func processUtterance(_ utterance: [Float], frozenContext: VoiceSharingCollector.CaptureContext? = nil) async {
        stageTimer.mark() // VAD segment ready
        let utteranceContext = frozenContext

        if effectiveExposedSpeakerRoute, signalFilter.isPlaybackBleed(mic: utterance, playback: playbackBuffer) {
            FileLog.shared.addMessage("[VoicePipeline] → drop (bleed filter)")
            // Observed bleed decision, not a discard: the spec requires collecting bleed-rejected segments
            // and retaining the decision rather than treating all rejects as playback-only ground truth.
            contributionCollector?.segmentRejected(kind: .rejectedBleed, samples: utterance.count, context: utteranceContext)
            return
        }

        // The detector observes every segment in both listening modes.
        let result = wakeWordDetector.detect(samples: utterance, sampleRate: 16000)
        stageTimer.mark() // wake result

        let score = wakeScore(of: result)
        let wakeCmp: String = {
            guard let score else { return "error" }
            let op = score >= wakeThreshold ? ">=" : "<"
            return "\(String(format: "%.3f", score)) \(op) \(String(format: "%.3f", wakeThreshold))"
        }()

        let detectedConfidence: Float?
        let completionSample: Int
        switch WakeGate.decide(result: result, listeningMode: listeningMode, graceActive: gracePeriodSignal.isActive) {
        case .discardProcessing(let errorCode):
            FileLog.shared.addMessage("[VoicePipeline] wake error \(errorCode) → drop")
            contributionCollector?.segmentRejected(kind: .rejectedWake, samples: utterance.count, context: utteranceContext)
            return
        case .dropUtterance:
            FileLog.shared.addMessage("[VoicePipeline] wake \(wakeCmp) → drop (no grace)")
            // Wake-negative: collectable audio. Notifying here adds NO ASR/router/action work — the very
            // next statement returns, and nothing downstream runs for this segment either way.
            contributionCollector?.segmentRejected(kind: .rejectedWake, samples: utterance.count, context: utteranceContext)
            return
        case .forward(let detected):
            if detected {
                onWakeWordDetected?()
                detectedConfidence = confidence(of: result)
                completionSample = self.completionSample(of: result)
                FileLog.shared.addMessage("[VoicePipeline] wake \(wakeCmp) → ASR (hit, mode=\(listeningMode))")
            } else {
                detectedConfidence = nil
                completionSample = 0
                FileLog.shared.addMessage("[VoicePipeline] wake \(wakeCmp) → ASR (grace/continuous)")
            }
        }

        // Segment accepted by wake gating: hand the completed capture AND its immutable context to the
        // collector before any ASR work. The context — not whatever is current inside the collector — decides
        // whether this completion belongs.
        contributionCollector?.speechCompleted(utterance, context: utteranceContext)

        guard !utterance.isEmpty else { return }
        let ready: Result<Void, Error>
        backendReadyLock.lock()
        let cachedReadyTask = backendReadyBox.task
        backendReadyLock.unlock()
        if let cachedReadyTask {
            let waitStarted = Date()
            ready = await cachedReadyTask.value
            let waitMs = Int(Date().timeIntervalSince(waitStarted) * 1000)
            if waitMs > 50 {
                FileLog.shared.addMessage("[VoicePipeline] asr waited \(waitMs)ms for backend")
            }
        } else {
            ready = await backend.ensureReady()
        }
        if case .failure(let error) = ready {
            FileLog.shared.addMessage("[VoicePipeline] → drop (backend not ready: \(error))")
            return
        }
        stageTimer.mark() // ASR start
        let asrStartedAt = Date()
        let asrResult = await backend.transcribe(samples: utterance, sampleRateHz: 16000)
        let asrMs = Int(Date().timeIntervalSince(asrStartedAt) * 1000)
        stageTimer.mark() // ASR result
        emitStageTiming(detectedConfidence: detectedConfidence)

        let isWakePositive = detectedConfidence != nil
        let trimmedText = WakeTranscriptTrimmer.commandText(
            result: asrResult,
            wakePositive: isWakePositive,
            completionSample: completionSample,
            sampleRateHz: 16000,
            samples: utterance
        )
        let trimNote: String? = {
            guard isWakePositive, asrResult.text != trimmedText else { return nil }
            return "trim '\(asrResult.text)' → '\(trimmedText)'"
        }()

        if trimmedText.isEmpty {
            let reason = isWakePositive ? "wake-only" : "empty"
            FileLog.shared.addMessage(
                "[VoicePipeline] asr \(backend.requiredModel.id) \(asrMs)ms lang=\(asrResult.detectedLanguage ?? "?") '\(asrResult.text)'\(trimNote.map { " \($0)" } ?? "") → drop (\(reason))"
            )
            if isWakePositive {
                onWakeOnly?()
            }
            return
        }

        // Translate to English when the ASR backend did not already translate and the
        // detected language is not English (the SenseVoice CJK path). Trim first so we
        // only translate the command remainder (matches Android).
        let trimmedResult = AsrResult(text: trimmedText, detectedLanguage: asrResult.detectedLanguage)
        let (finalized, translateNote) = await maybeTranslate(trimmedResult, backend: backend)
        // Source-first: lang + first quote are ASR; translate note carries the English result.
        FileLog.shared.addMessage(
            "[VoicePipeline] asr \(backend.requiredModel.id) \(asrMs)ms lang=\(trimmedResult.detectedLanguage ?? "?") '\(trimmedResult.text)'\(trimNote.map { " \($0)" } ?? "")\(translateNote.map { " \($0)" } ?? "")"
        )
        if Self.isNonEnglishTranslateFailure(translateNote) {
            // Don't feed untranslated CJK into the English-only intent model.
            FileLog.shared.addMessage("[VoicePipeline] → drop (\(translateNote ?? "translate"))")
            onUnroutable?()
            return
        }
        onRoutingInput?(Self.makeRoutingInput(
            source: trimmedResult,
            routerText: finalized.text,
            translateNote: translateNote
        ))
    }

    /// Builds the immutable envelope. Platform success keeps trimmed native source;
    /// backend translate omits source (Canary exposes English only).
    static func makeRoutingInput(
        source: AsrResult,
        routerText: String,
        translateNote: String?
    ) -> IntentRoutingInput {
        if let translateNote, translateNote.hasPrefix("translate=skip(backend)") {
            return IntentRoutingInput(
                sourceTranscript: nil,
                sourceLanguage: source.detectedLanguage,
                routerTranscript: routerText,
                translationKind: .backend
            )
        }
        if let translateNote,
           translateNote.contains("→en"),
           translateNote.hasPrefix("translate=") {
            return IntentRoutingInput(
                sourceTranscript: source.text,
                sourceLanguage: source.detectedLanguage,
                routerTranscript: routerText,
                translationKind: .platform
            )
        }
        return IntentRoutingInput.english(
            transcript: routerText,
            language: source.detectedLanguage ?? "en"
        )
    }

    /// Android `isNonEnglishTranslateFailure` parity — fail / blank / noop / no-stage notes drop.
    static func isNonEnglishTranslateFailure(_ translateNote: String?) -> Bool {
        guard let translateNote else { return false }
        return translateNote.hasPrefix("translate=fail(")
            || translateNote.hasPrefix("translate=blank(")
            || translateNote.hasPrefix("translate=noop(")
            || translateNote.hasPrefix("translate=skip(no stage)")
    }

    private func wakeScore(of result: WakeWordResult) -> Float? {
        switch result {
        case .detected(let confidence, _): return confidence
        case .notDetected(let confidence): return confidence
        case .error: return nil
        }
    }

    private func confidence(of result: WakeWordResult) -> Float? {
        if case .detected(let confidence, _) = result { return confidence }
        return nil
    }

    private func completionSample(of result: WakeWordResult) -> Int {
        if case .detected(_, let completionSample) = result { return completionSample }
        return 0
    }

    /// Translates a non-English, non-self-translating ASR result to English before
    /// intent routing. Fail / blank / no-op notes are dropped by the caller (ERROR earcon).
    private func maybeTranslate(_ result: AsrResult, backend: AsrBackend) async -> (AsrResult, String?) {
        guard let detected = result.detectedLanguage?.lowercased() else {
            return (result, "translate=skip(no lang)")
        }
        if detected == "en" {
            return (result, nil)
        }
        if backend.capabilities.canTranslateToEnglish {
            return (result, "translate=skip(backend)")
        }
        guard let translationStage else {
            // Missing platform translation is a hard failure for non-English SenseVoice text —
            // never relabel native text as english_v1.
            return (result, "translate=skip(no stage)")
        }

        if case .failure = await translationStage.ensureReady(sourceLanguage: detected) {
            return (result, "translate=fail(\(detected))")
        }
        let translated = await translationStage.translate(text: result.text, sourceLanguage: detected)
        guard !translated.isEmpty else {
            return (result, "translate=blank(\(detected))")
        }
        // Reject no-op "translations" that would mislabel CJK as English.
        if translated == result.text {
            return (result, "translate=noop(\(detected))")
        }
        return (
            AsrResult(text: translated, detectedLanguage: "en"),
            "translate=\(detected)→en '\(translated)'"
        )
    }

    /// Computes and emits the per-utterance stage timings. `detectedConfidence`
    /// is the wake detector score for positive detections; nil otherwise.
    private func emitStageTiming(detectedConfidence: Float?) {
        let wakeResult = detectedConfidence.map { $0 >= wakeThreshold ? "detected" : "not_detected" }
        guard let timing = stageTimer.build(
            wakeResult: wakeResult ?? "not_detected",
            confidenceMargin: confidenceMargin(detectedConfidence),
            listeningMode: listeningMode == .continuous ? "continuous" : "wake_word",
            backend: backend.requiredModel.id
        ) else { return }
        onStageTiming?(timing)
    }

    private func confidenceMargin(_ confidence: Float?) -> String? {
        guard let confidence, confidence >= wakeThreshold else { return nil }
        let margin = confidence - wakeThreshold
        if margin < 0.05 { return "near" }
        if margin < 0.20 { return "medium" }
        return "high"
    }

    func updatePlaybackBuffer(_ samples: [Float]) {
        playbackBuffer = samples
    }

    func setExposedSpeakerRoute(_ exposed: Bool) {
        if isExposedSpeakerRoute != exposed {
            FileLog.shared.addMessage("[VoicePipeline] exposedSpeaker=\(exposed)")
        }
        isExposedSpeakerRoute = exposed
    }
}
