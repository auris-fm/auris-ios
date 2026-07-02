import Foundation
import PocketCastsUtils

class VoiceAsrEngine {
    private let capture: NativeAudioCapture
    private let segmenter: NativeVadSegmenter
    private let backend: AsrBackend
    private let signalFilter: SignalFilter

    private var isExposedSpeakerRoute = false
    private var playbackBuffer: [Float] = []

    var onTranscript: ((String) -> Void)?

    init(capture: NativeAudioCapture, segmenter: NativeVadSegmenter, backend: AsrBackend, signalFilter: SignalFilter) {
        self.capture = capture
        self.segmenter = segmenter
        self.backend = backend
        self.signalFilter = signalFilter
    }

    func start() {
        FileLog.shared.addMessage("[VoiceControl/ASR] Engine starting")
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
    }

    private func processUtterance(_ utterance: [Float]) async {
        if isExposedSpeakerRoute, signalFilter.isPlaybackBleed(mic: utterance, playback: playbackBuffer) {
            FileLog.shared.addMessage("[VoiceControl/ASR] Utterance dropped (playback bleed)")
            return
        }
        let result = await backend.transcribe(samples: utterance, sampleRateHz: 16000)
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
