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
        wakeThreshold: Float = 0.8
    ) {
        self.capture = capture
        self.segmenter = segmenter
        self.backend = backend
        self.signalFilter = signalFilter
        self.wakeWordDetector = wakeWordDetector
        self.gracePeriodSignal = gracePeriodSignal
        self.stageTimer = RecognitionStageTimer(clock: clock)
        self.wakeThreshold = wakeThreshold
    }

    func start() {
        FileLog.shared.addMessage("[VoiceControl/ASR] Engine starting")
        segmenter.onUtterance = { [weak self] utterance in
            Task { await self?.processUtterance(utterance) }
        }
        capture.onSamples = { [weak self] samples in
            self?.segmenter.process(samples)
        }

        // Load ASR model asynchronously — capture can start in parallel
        Task {
            let result = await backend.ensureReady()
            switch result {
            case .success:
                FileLog.shared.addMessage("[VoiceControl/ASR] Whisper model ready")
            case .failure(let error):
                FileLog.shared.addMessage("[VoiceControl/ASR] Whisper model FAILED: \(error)")
            }
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
                FileLog.shared.addMessage("[VoiceControl/ASR] Wake word detected (confidence: \(detectedConfidence ?? 0)), sending full segment to ASR")
            } else {
                detectedConfidence = nil
            }
        }

        guard !utterance.isEmpty else { return }
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
        let transcript = isWakePositive ? WakePhraseNormalizer.normalize(asrResult.text) : asrResult.text
        if transcript.isEmpty {
            // Wake-only: after ASR and supported-prefix removal there is no
            // command. Play ERROR once and skip intent routing.
            if isWakePositive {
                FileLog.shared.addMessage("[VoiceControl/ASR] Wake-only utterance — no command remainder")
                onWakeOnly?()
            }
            return
        }
        onTranscript?(transcript)
    }

    private func confidence(of result: WakeWordResult) -> Float? {
        if case .detected(let confidence) = result { return confidence }
        return nil
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
