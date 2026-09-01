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
        FileLog.shared.addMessage("[VoiceControl/ASR] Engine starting")
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
                FileLog.shared.addMessage("[VoiceControl/ASR] Whisper model ready")
            case .failure(let error):
                FileLog.shared.addMessage("[VoiceControl/ASR] Whisper model FAILED: \(error)")
            }
            return result
        }

        do {
            try capture.start()
            FileLog.shared.addMessage("[VoiceControl/ASR] Engine started")
        } catch {
            FileLog.shared.addMessage("[VoiceControl/ASR] Engine start failed: \(error)")
        }
    }

    func stop() {
        FileLog.shared.addMessage("[VoiceControl/ASR] Engine stopping")
        capture.stop()
    }

    private func processUtterance(_ utterance: [Float]) async {
        stageTimer.mark() // VAD segment ready

        if isExposedSpeakerRoute, signalFilter.isPlaybackBleed(mic: utterance, playback: playbackBuffer) {
            FileLog.shared.addMessage("[VoiceControl/ASR] Utterance dropped (playback bleed)")
            return
        }

        // The detector observes every segment in both listening modes.
        let result = wakeWordDetector.detect(samples: utterance, sampleRate: 16000)
        stageTimer.mark() // wake result

        let detectedConfidence: Float?
        let completionSample: Int
        switch WakeGate.decide(result: result, listeningMode: listeningMode, graceActive: gracePeriodSignal.isActive) {
        case .discardProcessing(let errorCode):
            FileLog.shared.addMessage("[VoiceControl/ASR] Wake detector error \(errorCode) — segment discarded")
            return
        case .dropUtterance:
            FileLog.shared.addMessage("[VoiceControl/ASR] Utterance dropped (no wake word outside grace)")
            return
        case .forward(let detected):
            if detected {
                onWakeWordDetected?()
                detectedConfidence = confidence(of: result)
                completionSample = self.completionSample(of: result)
                FileLog.shared.addMessage("[VoiceControl/ASR] Wake word detected (confidence: \(detectedConfidence ?? 0)), sending full segment to ASR")
            } else {
                detectedConfidence = nil
                completionSample = 0
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
            FileLog.shared.addMessage("[VoiceControl/ASR] Skipping transcription; Whisper not ready: \(error)")
            return
        }
        stageTimer.mark() // ASR start
        let asrResult = await backend.transcribe(samples: utterance, sampleRateHz: 16000)
        stageTimer.mark() // ASR result
        emitStageTiming(detectedConfidence: detectedConfidence)

        if !asrResult.text.isEmpty {
            FileLog.shared.addMessage("[VoiceControl/ASR] Transcript: \"\(asrResult.text)\"")
        } else {
            FileLog.shared.addMessage("[VoiceControl/ASR] Transcription empty (audio: \(utterance.count)samp)")
        }

        let isWakePositive = detectedConfidence != nil
        let durationMs = utterance.count * 1000 / 16000
        let trimmedText = WakeTranscriptTrimmer.commandText(
            result: asrResult,
            wakePositive: isWakePositive,
            completionSample: completionSample,
            sampleRateHz: 16000,
            utteranceDurationMs: durationMs
        )
        if trimmedText.isEmpty {
            if isWakePositive {
                FileLog.shared.addMessage("[VoiceControl/ASR] Wake-only utterance — no command remainder")
                onWakeOnly?()
            }
            return
        }

        // Translate to English when the ASR backend did not already translate and the
        // detected language is not English (the SenseVoice CJK path). Trim first so we
        // only translate the command remainder (matches Android).
        let trimmedResult = AsrResult(text: trimmedText, detectedLanguage: asrResult.detectedLanguage)
        let finalized = await maybeTranslate(trimmedResult, backend: backend)
        onTranscript?(finalized.text)
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
    private func maybeTranslate(_ result: AsrResult, backend: AsrBackend) async -> AsrResult {
        guard let detected = result.detectedLanguage?.lowercased(), detected != "en" else {
            return result
        }
        if backend.capabilities.canTranslateToEnglish { return result }
        guard let translationStage else { return result }

        if case .failure = await translationStage.ensureReady(sourceLanguage: detected) {
            FileLog.shared.addMessage("[VoiceControl/ASR] Translation stage not ready for \(detected), using native transcript")
            return result
        }
        let translated = await translationStage.translate(text: result.text, sourceLanguage: detected)
        guard !translated.isEmpty else {
            FileLog.shared.addMessage("[VoiceControl/ASR] Translation returned blank for \(detected), using native transcript")
            return result
        }
        FileLog.shared.addMessage("[VoiceControl/ASR] Translated \(detected) -> en")
        return AsrResult(text: translated, detectedLanguage: "en")
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
            FileLog.shared.addMessage("[VoiceControl/ASR] ExposedSpeakerRoute: \(exposed)")
        }
        isExposedSpeakerRoute = exposed
    }
}
