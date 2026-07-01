import AVFoundation

class EarconPlayer {
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private var cachedEarcons: [EarconId: AVAudioPCMBuffer] = [:]

    init(engine: AVAudioEngine) {
        self.engine = engine
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        preloadAll()
    }

    func play(_ id: EarconId) {
        guard let buffer = cachedEarcons[id] else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts) {
            // Earcon finished
        }
        if !player.isPlaying { player.play() }
    }

    func stop() { player.stop() }

    private func preloadAll() {
        for id in EarconId.allCases {
            guard let url = Bundle.main.url(forResource: id.rawValue, withExtension: "wav", subdirectory: "earcons"),
                  let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
            else { continue }
            try? file.read(into: buffer)
            cachedEarcons[id] = buffer
        }
    }
}
