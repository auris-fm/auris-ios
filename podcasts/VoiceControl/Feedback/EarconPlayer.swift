import AVFoundation
import PocketCastsUtils

open class EarconPlayer {
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private var cachedEarcons: [EarconId: AVAudioPCMBuffer] = [:]

    init(engine: AVAudioEngine) {
        self.engine = engine
        preloadAll()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: cachedEarcons.values.first?.format)
        engine.prepare()
    }

    /// Returns true if the earcon asset is loaded and can be played.
    func hasEarcon(_ id: EarconId) -> Bool {
        cachedEarcons[id] != nil
    }

    func play(_ id: EarconId) {
        guard let buffer = cachedEarcons[id] else {
            FileLog.shared.addMessage("[VoiceControl/Earcon] Missing: \(id)")
            return
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                FileLog.shared.addMessage("[VoiceControl/Earcon] Failed to start audio engine: \(error)")
                return
            }
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts) {
            // Earcon finished
        }
        if !player.isPlaying { player.play() }
    }

    func stop() { player.stop() }

    func release() {
        player.stop()
        engine.detach(player)
        cachedEarcons.removeAll()
    }

    private func preloadAll() {
        for id in EarconId.allCases {
            guard let url = Bundle.main.url(forResource: id.rawValue, withExtension: "wav", subdirectory: "earcons") else {
                FileLog.shared.addMessage("[VoiceControl/Earcon] Missing asset: \(id.rawValue).wav")
                continue
            }
            guard let file = try? AVAudioFile(forReading: url) else {
                FileLog.shared.addMessage("[VoiceControl/Earcon] Failed to read: \(id.rawValue).wav")
                continue
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                FileLog.shared.addMessage("[VoiceControl/Earcon] Failed to create buffer: \(id.rawValue)")
                continue
            }
            do {
                try file.read(into: buffer)
                cachedEarcons[id] = buffer
            } catch {
                FileLog.shared.addMessage("[VoiceControl/Earcon] Read error for \(id.rawValue): \(error)")
            }
        }
    }
}
