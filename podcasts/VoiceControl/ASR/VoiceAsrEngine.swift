import Foundation
import PocketCastsUtils

class VoiceAsrEngine {
    private let capture: NativeAudioCapture
    private let segmenter: NativeVadSegmenter
    private let backend: AsrBackend
    private let signalFilter: SignalFilter
    private let wakeWordDetector: WakeWordDetectorProtocol
    private let commandWindow: CommandWindowManager

    private var isExposedSpeakerRoute = false
    private var playbackBuffer: [Float] = []
    var listeningMode: ListeningMode = .wakeWord

    var onTranscript: ((String) -> Void)?

    init(
        capture: NativeAudioCapture,
        segmenter: NativeVadSegmenter,
        backend: AsrBackend,
        signalFilter: SignalFilter,
        wakeWordDetector: WakeWordDetectorProtocol,
        commandWindow: CommandWindowManager
    ) {
        self.capture = capture
        self.segmenter = segmenter
        self.backend = backend
        self.signalFilter = signalFilter
        self.wakeWordDetector = wakeWordDetector
        self.commandWindow = commandWindow
    }

    func start() {
        FileLog.shared.addMessage("[VoiceControl/ASR] Engine starting")
        commandWindow.reset()
        segmenter.onUtterance = { [weak self] utterance in
            Task { await self?.processUtterance(utterance) }
        }
        capture.onSamples = { [weak self] samples in
            self?.segmenter.process(samples)
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
        commandWindow.close()
    }

    private func processUtterance(_ utterance: [Float]) async {
        if isExposedSpeakerRoute, signalFilter.isPlaybackBleed(mic: utterance, playback: playbackBuffer) {
            FileLog.shared.addMessage("[VoiceControl/ASR] Utterance dropped (playback bleed)")
            return
        }

        // Determine which audio to transcribe based on listening mode
        let audioForAsr: [Float]?
        switch listeningMode {
        case .continuous:
            audioForAsr = utterance

        case .wakeWord:
            if commandWindow.isActive {
                // Follow-up command in open window — no wake word needed
                commandWindow.onSpeechActivity()
                audioForAsr = utterance
            } else {
                let result = wakeWordDetector.detect(samples: utterance, sampleRate: 16000)
                if result.detected {
                    commandWindow.onWakeWordDetected()
                    // Strip the wake word: use remainder if available, otherwise full audio
                    audioForAsr = result.remainderSamples ?? utterance
                    FileLog.shared.addMessage("[VoiceControl/ASR] Wake word detected (confidence: \(result.confidence)), sending to ASR")
                } else {
                    FileLog.shared.addMessage("[VoiceControl/ASR] Utterance dropped (no wake word)")
                    return
                }
            }
        }

        guard let audio = audioForAsr, !audio.isEmpty else { return }
        let result = await backend.transcribe(samples: audio, sampleRateHz: 16000)
        if !result.text.isEmpty {
            FileLog.shared.addMessage("[VoiceControl/ASR] Transcript: \"\(result.text)\"")
        }
        guard !result.text.isEmpty else { return }
        onTranscript?(result.text)
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
