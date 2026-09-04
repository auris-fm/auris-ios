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

    private var isExposedSpeakerRoute = false
    private var playbackBuffer: [Float] = []
    var listeningMode: ListeningMode = .wakeWord

    var onTranscript: ((String) -> Void)?
    /// Called on every positive detection so the service can reset grace and
    /// play the `WAKE_WORD` earcon exactly once.
    var onWakeWordDetected: (() -> Void)?
    /// Called when a positive wake result leaves no routable transcript
    /// (wake-only utterance); the service plays the `ERROR` earcon.
    var onWakeOnly: (() -> Void)?
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

    private var backendReadyTask: Task<Result<Void, Error>, Never>?

    func start() {
        FileLog.shared.addMessage("[VoicePipeline] engine starting backend=\(backend.requiredModel.id)")
        segmenter.onUtterance = { [weak self] utterance in
            Task { await self?.processUtterance(utterance) }
        }
        capture.onSamples = { [weak self] samples in
            self?.segmenter.process(samples)
        }

        backendReadyTask = Task {
            let result = await backend.ensureReady()
            switch result {
            case .success:
                FileLog.shared.addMessage("[VoicePipeline] backend ready \(backend.requiredModel.id)")
            case .failure(let error):
                FileLog.shared.addMessage("[VoicePipeline] backend FAILED \(backend.requiredModel.id): \(error)")
            }
            return result
        }

        do {
            try capture.start()
            FileLog.shared.addMessage("[VoicePipeline] engine started mode=\(listeningMode)")
        } catch {
            FileLog.shared.addMessage("[VoicePipeline] engine start failed: \(error)")
        }
    }

    func stop() {
        FileLog.shared.addMessage("[VoicePipeline] engine stopped")
        capture.stop()
    }

    private func processUtterance(_ utterance: [Float]) async {
        stageTimer.mark() // VAD segment ready

        if isExposedSpeakerRoute, signalFilter.isPlaybackBleed(mic: utterance, playback: playbackBuffer) {
            FileLog.shared.addMessage("[VoicePipeline] → drop (bleed filter)")
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
            return
        case .dropUtterance:
            FileLog.shared.addMessage("[VoicePipeline] wake \(wakeCmp) → drop (no grace)")
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

        guard !utterance.isEmpty else { return }
        let ready: Result<Void, Error>
        if let backendReadyTask {
            ready = await backendReadyTask.value
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
        let durationMs = utterance.count * 1000 / 16000
        let trimmedText = WakeTranscriptTrimmer.commandText(
            result: asrResult,
            wakePositive: isWakePositive,
            completionSample: completionSample,
            sampleRateHz: 16000,
            utteranceDurationMs: durationMs
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
        FileLog.shared.addMessage(
            "[VoicePipeline] asr \(backend.requiredModel.id) \(asrMs)ms lang=\(asrResult.detectedLanguage ?? "?") '\(finalized.text)'\(trimNote.map { " \($0)" } ?? "")\(translateNote.map { " \($0)" } ?? "")"
        )
        onTranscript?(finalized.text)
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
    /// intent routing. Falls back to the native transcript if the translation stage
    /// is unavailable or fails (best-effort, per the spec).
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
            return (result, "translate=skip(no stage)")
        }

        if case .failure = await translationStage.ensureReady(sourceLanguage: detected) {
            return (result, "translate=fail(\(detected))")
        }
        let translated = await translationStage.translate(text: result.text, sourceLanguage: detected)
        guard !translated.isEmpty else {
            return (result, "translate=blank(\(detected))")
        }
        return (
            AsrResult(text: translated, detectedLanguage: "en"),
            "translate=\(detected)→en '\(result.text)'"
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
