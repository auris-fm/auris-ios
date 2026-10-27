import Foundation
import PocketCastsUtils

class VoiceAsrEngine {
    private let capture: any AudioCaptureSource
    private let segmenter: NativeVadSegmenter
    private let backend: AsrBackend
    private let signalFilter: SignalFilter
    private let wakeWordDetector: WakeWordDetectorProtocol
    private let gracePeriodSignal: GracePeriodSignal
    private let stageTimer: RecognitionStageTimer
    private let wakeThreshold: Float
    private let translationStage: TranslationStage?

    /// Which echo-filter scope applies to the current output route.
    ///
    /// `recognition-pipeline.md` "Signal Filter" distinguishes route classes rather
    /// than treating "exposed" as a single flag: the built-in loudspeaker uses aligned
    /// playback cross-correlation against the shared reference, external routes must
    /// use delay tracking instead of that window, and an isolated route reduces
    /// exposure without proving echo is absent.
    enum EchoFilterRoute {
        /// Built-in loudspeaker: cross-correlation against the reference applies.
        case builtInSpeaker
        /// External output: codec latency is large and variable, so the built-in
        /// correlation window's alignment assumption does not hold.
        case external
        /// Headset/earbud. Reduced acoustic exposure, but **not** proof of no echo.
        case isolated

        /// Whether the built-in-speaker correlation window may be applied.
        var appliesCorrelationWindow: Bool { self == .builtInSpeaker }

        /// Whether this route is evidence that echo cannot occur. It never is: the
        /// owning clause says an isolated route reduces exposure, not that it removes it.
        var provesEchoImpossible: Bool { false }

        /// Maps an observed output port to the filter scope it implies.
        ///
        /// Only the built-in loudspeaker allows the aligned correlation window: its
        /// local latency is bounded and the emitted buffer matches what leaves the
        /// device. Every other output — wired, Bluetooth, AirPlay — has large and
        /// variable codec latency, so alignment is unreliable and the window is not
        /// applied. A headset input does not change the output's alignment properties.
        static func forOutput(_ output: AudioRouteOutput) -> EchoFilterRoute {
            switch output {
            case .builtInSpeaker:
                return .builtInSpeaker
            case .headphones, .bluetoothLE:
                return .isolated
            case .bluetoothHFP, .bluetoothA2DP, .airPlay, .unknown:
                return .external
            }
        }
    }

    private(set) var echoFilterRoute: EchoFilterRoute = .external
    /// How long the reference survives a route change so the handover is still filtered.
    ///
    /// **This is a chosen software limit, not a measurement of audibility.** It bounds
    /// how much emitted audio is kept after the output path changes; it does not claim
    /// that sound stops reaching the microphone at 0.25 s. Output latency, route delay
    /// and the device's own buffering all contribute to the real figure, and none of
    /// them is measured here. The value exists so the handover window is filtered at
    /// all rather than cleared instantly, and it is expected to be revised if a
    /// measured acoustic figure becomes available.
    static let acousticTailSeconds: Double = 0.25
    /// The shared emitted-PCM reference the echo filter correlates against. Producers
    /// append what they send to the output; the filter reads it on the segment path.
    /// When no reference is attached the filter has nothing to correlate and cannot
    /// reject anything, so the scope alone is not sufficient wiring.
    private var echoReference: PlaybackEchoReference?

    /// Attaches the shared emitted-PCM reference.
    func setEchoReference(_ reference: PlaybackEchoReference) {
        echoReference = reference
    }

    /// Where the segment about to be examined begins within the retained reference.
    ///
    /// Returns a negative offset when the segment cannot be placed: without an observed
    /// render position the node may not be rendering, or may have restarted, and the
    /// retained audio's position relative to the segment is then unknown. A negative
    /// offset makes the filter decline to claim alignment rather than align against the
    /// wrong instant — the failure this exists to avoid.
    ///
    /// **The offset is deliberately coarse while the capture side carries no segment
    /// instant.** A segment arriving now is at the newest end of what has been emitted,
    /// so the window is anchored to the reference's end; that is correct under steady
    /// playback and is not correct across a queue lead or a restart, which is why the
    /// segment instant is required before this closes. It is written this way rather
    /// than guessing a precise value from the render anchor alone, because a precise
    /// wrong offset is worse than an honest coarse one.
    /// Where the audible end of the emitted stream sits in the retained window.
    ///
    /// Placed from the output node's **rendered** position, not from the retained end: the
    /// retained end is the newest *submitted* sample, which is ahead of what has been
    /// heard by however much audio is still queued. Using it is misaligned whenever the
    /// queue is non-empty, which is most of streaming playback — not only across a
    /// restart. A negative value means the position is unknown and the filter declines to
    /// align rather than aligning against the wrong instant.
    ///
    /// **Still coarse:** the segment instant is not carried yet, so a segment is assumed
    /// to end at the current audible position. That holds when the segment arrives as it
    /// is captured and not when capture buffering delays it, which is why the capture-side
    /// timestamp is required before alignment acceptance can close.
    func playbackEndOffsetForTesting(capturedAt: MonotonicTime?, segmentSamples: Int) -> Int {
        playbackEndOffsetForSegment(
            capturedAt: capturedAt, segmentSamples: segmentSamples,
            observation: echoReference?.consistentObservation())
    }

    /// TEST-ONLY: fires between the filter-path observation and the filter call. See call site.
    var echoObservationTakenForTesting: (() -> Void)?

    /// TEST SEAM (r4357901593): the offset arithmetic applied to a CALLER-SUPPLIED observation,
    /// so a control can prove the filter uses the observation it took rather than a fresh
    /// (post-append, displaced) read.
    func engineOffsetFromObservationForTesting(
        observation: PlaybackEchoReference.ConsistentObservation
    ) -> Int {
        playbackEndOffsetForSegment(
            capturedAt: 0, segmentSamples: 0, observation: observation)
    }

    private func playbackEndOffsetForSegment(
        capturedAt: MonotonicTime?, segmentSamples: Int,
        observation: PlaybackEchoReference.ConsistentObservation?
    ) -> Int {
        guard let observation, let anchor = observation.renderAnchor else { return -1 }
        // Without the segment's own instant the position is unknown, so no alignment
        // claim is made. The callback's arrival time is not a substitute: the tap runs on
        // a processing queue, so arrival lags capture by an indeterminate amount and would
        // place the segment later than it was spoken.
        guard let capturedAt else { return -1 }
        // How far the render position in the reference window is *behind* the segment's
        // capture: emitted audio keeps playing while the segment is being captured, so the
        // audible position at capture is earlier than the audible position now.
        // `capturedAt` is the instant of the segment's FIRST sample
        // (`NativeVadSegmenter.utteranceCapturedAt` is set when the buffer first fills), while
        // the value returned here is used as `segmentEndOffset` — the position the compared
        // window ENDS at. Using the first sample's instant for the end places the whole window
        // one segment-length early, and the displacement is not absorbable by the correlation:
        // the window is exactly `mic.count` long, so the real alignment falls outside it and
        // the filter stops rejecting the echo it exists for.
        let segmentEndInstant = capturedAt
            + Double(segmentSamples) / PlaybackEchoReference.pipelineSampleRate

        // How far the render position is *behind* the segment's end: emitted audio keeps playing
        // while the segment is captured, so the audible position then is earlier than now.
        let latency = max(0, anchor.hostTime - segmentEndInstant)
        let latencySamples = Int(latency * PlaybackEchoReference.pipelineSampleRate)
        // The offset is the one computed WITH these samples under the same lock — not a fresh
        // read, which could describe a window an append has already shifted.
        let nowOffset = observation.audibleEndOffset ?? -1
        guard nowOffset >= 0 else { return -1 }
        return max(0, nowOffset - latencySamples)
    }
    var listeningMode: ListeningMode = .wakeWord
    /// INJECTABLE for controls: mints the utterance identity at ADMISSION. Production uses a fresh
    /// UUID; a control can supply a known sequence so it can prove the id the routing input carries
    /// is the ADMITTED one rather than a value rebuilt downstream (spec delta3b1def9).
    var utteranceIdGeneratorForTesting: (() -> String)?

    /// TEST SEAM: the engine's live grace signal, so controls can prove a discarded capture did
    /// NOT renew the window (generation unchanged) — cleanup, not consumption (reviewer 1f2c96ce).
    var gracePeriodSignalForTesting: GracePeriodSignal { gracePeriodSignal }

    /// Invoked once the wake decision has established THIS turn's window origin and BEFORE the
    /// backend wait, so the turn can be recorded as admitted while its window is still live.
    ///
    /// It has to be here rather than at `onRoutingInput`: that callback runs AFTER recognition, and
    /// on a cold backend the deadline can pass first — in which case a reservation recorded there
    /// would be rejected outright and the turn silently lost (spec `voice-control-core.md:270`: an
    /// utterance observed before the deadline stays eligible through recognition). It also has to
    /// be after the wake decision, not at the top of the method: a wake-selected turn opens its own
    /// window there, and reserving earlier would sample the preceding window's origin.
    var onTurnAdmitted: ((_ utteranceId: String, _ origin: Int?) -> Void)?

    /// Hands the router an input. It returns the ROUTER'S OWN acceptance result: a rejection (e.g.
    /// the service stopped) means nobody took ownership, so the engine keeps the turn and its
    /// `defer` releases rather than assuming a chain that never started will.
    ///
    /// This is deliberately the same single operation that enqueues. A separate "can you accept?"
    /// precheck would be a DIFFERENT operation from the one that takes ownership, so a stop landing
    /// between them could reject the enqueue with no owner left to release.
    var onRoutingInput: ((IntentRoutingInput) -> Bool)?

    /// Invoked when a turn that was admitted leaves the engine WITHOUT reaching routing — a
    /// backend/recognition/translation drop or a cancellation. The routing path does not call it;
    /// ownership transfers to the routing chain there.
    var onTurnReleased: ((_ utteranceId: String) -> Void)?
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

    /// Surfaces a segmentation fault the user must be told about.
    ///
    /// `recognition-pipeline.md`: a detector stuck active is a **surfaced** segmentation fault,
    /// and `arch/ios.md` requires an explicit duration-limit interruption with an inspectable
    /// fault state. A flag private to the segmenter is not surfaced — nothing outside it could
    /// observe the interruption, so the user would see silence with no explanation.
    var onSegmentationFault: ((SegmentationFault) -> Void)?

    /// Surfaces that speech classification cannot run at all.
    ///
    /// Distinct from a segmentation fault: no classifier means no trustworthy endpoint, so the
    /// engine cannot capture. Reporting this as ordinary listening would present a broken
    /// pipeline as a working one.
    var onClassifierUnavailable: ((String) -> Void)?

    /// A fault the user-facing layer can render.
    struct SegmentationFault: Equatable {
        public enum Kind: Equatable {
            /// Reached the supported utterance-duration ceiling.
            case durationLimitReached
            /// No speech classifier available.
            case classifierUnavailable
        }

        public let kind: Kind
        public let discardedSamples: Int
        public let elapsedMs: Int
        public let reason: String?
    }

    init(
        capture: any AudioCaptureSource = NativeAudioCapture(),
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
    /// TEST SEAM: installs the capture/segmenter callbacks without opening the microphone, so a
    /// control can prove a fault reaches an observer through the engine's own forwarding.
    func installCaptureCallbacksForTesting() {
        wireCaptureCallbacks()
    }

    /// Single definition of the capture wiring, so the fault forwarding cannot exist on one path
    /// and be missing on another.
    private func wireCaptureCallbacks() {
        segmenter.onUtterance = { [weak self] utterance, capturedAt in
            Task { await self?.processUtterance(utterance, capturedAt: capturedAt) }
        }
        // Segmentation faults are forwarded so the interruption is observable outside this
        // component. A private flag would leave the user with unexplained silence.
        segmenter.onStuckActiveFault = { [weak self] fault in
            self?.onSegmentationFault?(SegmentationFault(
                kind: .durationLimitReached,
                discardedSamples: fault.discardedSamples,
                elapsedMs: fault.elapsedMs,
                reason: nil
            ))
        }
        segmenter.onClassifierUnavailable = { [weak self] fault in
            self?.onSegmentationFault?(SegmentationFault(
                kind: .classifierUnavailable,
                discardedSamples: 0,
                elapsedMs: 0,
                reason: fault.reason
            ))
            self?.onClassifierUnavailable?(fault.reason)
        }
        capture.onCapturedSamples = { [weak self] samples, capturedAt in
            self?.segmenter.process(samples, capturedAt: capturedAt)
        }
    }

    func start() -> Bool {
        FileLog.shared.addMessage("[VoicePipeline] engine starting backend=\(backend.requiredModel.id)")
        wireCaptureCallbacks()

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
    }

    /// Exposed for focused translate-drop tests (`@testable`).
    func processUtterance(_ utterance: [Float], capturedAt: MonotonicTime? = nil) async {
        stageTimer.mark() // VAD segment ready
        // ONE IDENTITY FROM ADMISSION (spec delta3b1def9): the utterance is admitted HERE, so its
        // identity is minted here — not rebuilt later. Retries/duplicates that re-emit the SAME
        // capture carry this id; an independent utterance has its own. It flows unchanged through
        // trimming, router diagnostics, the prepared wire request_id and server diagnostics.
        let utteranceId = utteranceIdGeneratorForTesting?() ?? UUID().uuidString
        FileLog.shared.addMessage("[VoicePipeline] utterance admitted id=\(utteranceId)")

        if echoFilterRoute.appliesCorrelationWindow {
            // ONE CONSISTENT OBSERVATION (PR50 review r4357901593): samples, offset and anchor
            // come from a single lock acquisition, so the offset always describes exactly the
            // samples the mic segment is correlated against — an append landing between two
            // separate reads can no longer shift the window out from under the offset.
            let observation = echoReference?.consistentObservation()
            // TEST-ONLY boundary hook (r4366062986 disposition): fires AFTER the observation is
            // taken and BEFORE the filter call, so a control can force an append/anchor advance
            // into the exact window a split-read regression would read across — deterministically,
            // no timing. Nil in production.
            echoObservationTakenForTesting?()
            let segmentEndOffset = playbackEndOffsetForSegment(
                capturedAt: capturedAt,
                segmentSamples: utterance.count,
                observation: observation)
            if signalFilter.isPlaybackBleed(
                mic: utterance,
                reference: observation?.samples ?? [],
                segmentEndOffset: segmentEndOffset) {
                FileLog.shared.addMessage("[VoicePipeline] → drop (bleed filter)")
                return
            }
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
        // What SELECTED this utterance, captured from the gate's own decision. A detected wake
        // is a new conversation even during grace; a non-detected pass is a follow-up continuing
        // the current one. Read from live `isActive` instead, the two are identical — both arrive
        // with grace active — so the distinction has to come from here, where it is actually made.
        let selection: CloudConversationSelection
        switch WakeGate.decide(result: result, listeningMode: listeningMode, graceActive: gracePeriodSignal.isActive) {
        case .discardProcessing(let errorCode):
            FileLog.shared.addMessage("[VoicePipeline] wake error \(errorCode) → drop")
            return
        case .dropUtterance:
            FileLog.shared.addMessage("[VoicePipeline] wake \(wakeCmp) → drop (no grace)")
            return
        case .forward(let detected):
            if detected {
                onWakeWordDetected?()
                detectedConfidence = confidence(of: result)
                completionSample = self.completionSample(of: result)
                selection = .wakeWord
                FileLog.shared.addMessage("[VoicePipeline] wake \(wakeCmp) → ASR (hit, mode=\(listeningMode))")
            } else {
                detectedConfidence = nil
                completionSample = 0
                selection = .followUp
                FileLog.shared.addMessage("[VoicePipeline] wake \(wakeCmp) → ASR (grace/continuous)")
            }
        }

        guard !utterance.isEmpty else { return }
        // THIS turn is admitted: its window origin is settled (the wake decision above opened the
        // window for a wake-selected turn), and recognition has not begun. Recording it here is
        // what keeps it eligible if the deadline passes during the backend wait. A discarded
        // capture (bleed, no grace, wake error) has already returned, so it cannot gain
        // eligibility; an empty utterance is excluded by the guard above.
        let admittedOrigin = gracePeriodSignal.currentGeneration()
        onTurnAdmitted?(utteranceId, admittedOrigin)
        // The reservation is owned for exactly as long as this turn is in the engine. Every exit
        // below — backend failure, wake-only, empty/non-content transcript, translation failure,
        // cancellation — passes through this defer and releases it. The routing path sets the flag
        // to transfer ownership to the chain instead, which then releases on its own terminal
        // outcome. Without this, an early return leaves the reservation permanently in flight.
        var admissionHandedToRouting = false
        defer {
            if !admissionHandedToRouting { onTurnReleased?(utteranceId) }
        }
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
            return "trim[ut=\(utteranceId)] '\(asrResult.text)' → '\(trimmedText)'"
        }()

        if trimmedText.isEmpty {
            let reason = isWakePositive ? "wake-only" : "empty"
            FileLog.shared.addMessage(
                "[VoicePipeline] asr \(backend.requiredModel.id) \(asrMs)ms ut=\(utteranceId) lang=\(asrResult.detectedLanguage ?? "?") '\(asrResult.text)'\(trimNote.map { " \($0)" } ?? "") → drop (\(reason))"
            )
            if isWakePositive {
                onWakeOnly?()
            }
            return
        }

        // NON-CONTENT OUTPUT (task #78, spec 77eacc9b): a transcript with NO Unicode letter or
        // number carries no command — whitespace-only, punctuation-only, or any other non-content
        // the recogniser returns. It is discarded SILENTLY, before translation, the router, the
        // dialog, or any cloud work. No minimum length: a short MEANINGFUL utterance ("yes", "停",
        // "嗯", digits, text-with-punctuation) contains a letter or number and survives; only text
        // with neither is rejected. Silence is correct here — the user said nothing a machine can
        // act on, so it must not consume a dialog, speak an error, or extend grace.
        if Self.isNonContent(trimmedText) {
            FileLog.shared.addMessage(
                "[VoicePipeline] asr \(backend.requiredModel.id) \(asrMs)ms ut=\(utteranceId) lang=\(asrResult.detectedLanguage ?? "?") '\(trimmedText)'\(trimNote.map { " \($0)" } ?? "") → drop (non-content)"
            )
            return
        }

        // Translate to English when the ASR backend did not already translate and the
        // detected language is not English (the SenseVoice CJK path). Trim first so we
        // only translate the command remainder (matches Android).
        let trimmedResult = AsrResult(text: trimmedText, detectedLanguage: asrResult.detectedLanguage)
        let (finalized, translateNote) = await maybeTranslate(trimmedResult, backend: backend)
        // Source-first: lang + first quote are ASR; translate note carries the English result.
        FileLog.shared.addMessage(
            "[VoicePipeline] asr \(backend.requiredModel.id) \(asrMs)ms ut=\(utteranceId) lang=\(trimmedResult.detectedLanguage ?? "?") '\(trimmedResult.text)'\(trimNote.map { " \($0)" } ?? "")\(translateNote.map { " \($0)" } ?? "")"
        )
        if Self.isNonEnglishTranslateFailure(translateNote) {
            // Don't feed untranslated CJK into the English-only intent model.
            FileLog.shared.addMessage("[VoicePipeline] → drop (\(translateNote ?? "translate"))")
            onUnroutable?()
            return
        }
        // OWNERSHIP TRANSFER, CONDITIONAL ON ACCEPTANCE: only a router that actually took the
        // input will release the reservation on its terminal outcome. If it refuses — a late
        // completion after `stop()`, say — nobody owns the turn, so the engine keeps ownership and
        // its `defer` releases. Transferring unconditionally would leak in exactly that case.
        let routingInput = Self.makeRoutingInput(
            source: trimmedResult,
            routerText: finalized.text,
            translateNote: translateNote,
            selection: selection,
            utteranceId: utteranceId
        )
        if onRoutingInput?(routingInput) ?? false {
            admissionHandedToRouting = true
        }
    }

    /// Builds the immutable envelope. Platform success keeps trimmed native source;
    /// backend translate omits source (Canary exposes English only).
    static func makeRoutingInput(
        source: AsrResult,
        routerText: String,
        translateNote: String?,
        selection: CloudConversationSelection? = nil,
        utteranceId: String
    ) -> IntentRoutingInput {
        if let translateNote, translateNote.hasPrefix("translate=skip(backend)") {
            return IntentRoutingInput(
                sourceTranscript: nil,
                sourceLanguage: source.detectedLanguage,
                routerTranscript: routerText,
                translationKind: .backend,
                selection: selection,
                utteranceId: utteranceId
            )
        }
        if let translateNote,
           translateNote.contains("→en"),
           translateNote.hasPrefix("translate=") {
            return IntentRoutingInput(
                sourceTranscript: source.text,
                sourceLanguage: source.detectedLanguage,
                routerTranscript: routerText,
                translationKind: .platform,
                selection: selection,
                utteranceId: utteranceId
            )
        }
        // NO FABRICATED LANGUAGE: an unknown LID stays nil on the input (and is omitted on the
        // wire) — defaulting to "en" mislabeled an undetected-language utterance as English.
        return IntentRoutingInput.english(
            transcript: routerText,
            language: source.detectedLanguage,
            selection: selection,
            utteranceId: utteranceId
        )
    }

    /// True when the text carries NO Unicode letter or number — i.e. no content a machine can
    /// act on (task #78, spec 77eacc9b). Uses Unicode character classes, so every script counts:
    /// CJK, Hangul, Arabic, digits in any script. Punctuation and whitespace alone do not qualify.
    /// Deliberately NOT a length rule: "yes", "停", "嗯" and "3" all pass.
    static func isNonContent(_ text: String) -> Bool {
        // Unicode general categories, not CharacterSet: the spec's rule is L (letters) and N
        // (numbers) — and `CharacterSet.decimalDigits` covers only Nd, which would silently
        // DISCARD other numbers such as "²" (No), "½" (No) and "Ⅻ" (Nl) though the shared rule
        // treats them as content (spec clarification + reviewer 68afef6f). Counting is over
        // CHARACTERS for letters (multi-scalar letters such as "Ǆ" carry one letter category).
        text.unicodeScalars.contains { scalar in
            let category = scalar.properties.generalCategory
            switch category {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                return true
            default:
                return false
            }
        } == false
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
        // BACKEND PROVENANCE FIRST: a backend that translates to English has already produced the
        // English router text — including when it reported no language. Asking for a language id
        // before the backend capability mislabeled that translated-only output as original text.
        if backend.capabilities.canTranslateToEnglish {
            return (result, "translate=skip(backend)")
        }
        guard let detected = result.detectedLanguage?.lowercased() else {
            return (result, "translate=skip(no lang)")
        }
        if detected == "en" {
            return (result, nil)
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

    /// Test seam: replaces the retained reference contents.
    ///
    /// Production code does not call this — producers append through the shared
    /// reference — so a test that relies on it is exercising the filter's logic, not
    /// the wiring. The wiring cases drive the real producers instead.
    func updatePlaybackBuffer(_ samples: [Float]) {
        guard let echoReference else { return }
        echoReference.invalidate()
        echoReference.append(samples)
        // Mirror the production rule that a reference without an observed render
        // position cannot be aligned: the seam supplies one so cases exercise the
        // aligned path rather than silently taking the unaligned branch.
        echoReference.recordRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: Double(samples.count),
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 0
            )
        )
    }

    /// Sets the echo-filter scope for the current output route and retires the
    /// reference when the filter no longer applies, so stale state from a previous
    /// route cannot keep dropping audio after the route changes.
    func setEchoFilterRoute(_ route: EchoFilterRoute) {
        guard echoFilterRoute != route else { return }
        FileLog.shared.addMessage("[VoicePipeline] echoFilterRoute=\(route)")
        echoFilterRoute = route
        // Retire on EVERY transition, in both directions. The retained audio belongs to
        // the outgoing route and is not an aligned reference for the incoming one —
        // including built-in → external *and* external → built-in, where audio captured
        // on the old path would otherwise be correlated against the new path's window.
        // The acoustic tail is kept rather than discarded, because audio already
        // submitted is still audible while the old path drains; clearing outright would
        // leave exactly that echo unfiltered during the handover.
        echoReference?.retire(retainingAcousticTail: Self.acousticTailSeconds)
    }

    /// Whether the current route is being treated as proof that echo cannot occur.
    /// Always `false`: no route proves that, and an isolated route only reduces exposure.
    var echoFilterRouteConsidersEchoImpossible: Bool {
        echoFilterRoute.provesEchoImpossible
    }
}
