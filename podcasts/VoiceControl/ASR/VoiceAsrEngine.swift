import Foundation

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
        segmenter.onUtterance = { [weak self] utterance in
            Task { await self?.processUtterance(utterance) }
        }
        capture.onSamples = { [weak self] samples in
            self?.segmenter.process(samples)
        }
        try? capture.start()
    }

    func stop() {
        capture.stop()
    }

    private func processUtterance(_ utterance: [Float]) async {
        if isExposedSpeakerRoute, signalFilter.isPlaybackBleed(mic: utterance, playback: playbackBuffer) {
            return // drop bleed
        }
        let result = await backend.transcribe(samples: utterance, sampleRateHz: 16000)
        guard !result.text.isEmpty else { return }
        onTranscript?(result.text)
    }

    func updatePlaybackBuffer(_ samples: [Float]) {
        playbackBuffer = samples
    }

    func setExposedSpeakerRoute(_ exposed: Bool) {
        isExposedSpeakerRoute = exposed
    }
}
