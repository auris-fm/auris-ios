import AVFoundation
import PocketCastsUtils

open class EarconPlayer {
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private var cachedEarcons: [EarconId: AVAudioPCMBuffer] = [:]

    /// The session's emitted-audio reference, set once by assembly.
    ///
    /// An earcon is audio the microphone can hear, so it must be in the reference for
    /// the same reason the cloud answer is: otherwise a chime played while the user is
    /// speaking forms a segment in the microphone signal that nothing recognises as our
    /// output, and the utterance is transcribed as if the user had said it.
    var emittedPCMReference: PlaybackEchoReference?

    init(engine: AVAudioEngine) {
        self.engine = engine
        preloadAll()
        engine.attach(player)
        // Connected with an explicit format rather than `cachedEarcons.values.first?.format`.
        // Deriving it from the cache makes the graph depend on an asset having loaded: if
        // none did — a missing resource, a bundle change — the format silently becomes the
        // mixer default, and every `scheduleBuffer` then fails the audio graph's own
        // channel-count check. Earcons would go silent with one log line, which is the
        // failure this explicit format removes. The assets are mono at the pipeline rate.
        engine.connect(player, to: engine.mainMixerNode, format: Self.earconFormat(sampleRate: PlaybackEchoReference.pipelineSampleRate))
        engine.prepare()
    }

    /// Returns true if the earcon asset is loaded and can be played.
    func hasEarcon(_ id: EarconId) -> Bool {
        cachedEarcons[id] != nil
    }

    /// The format the player's node graph is connected with.
    ///
    /// The connection uses the loaded earcon's format, and `scheduleBuffer` requires the
    /// scheduled buffer to match the node's connection format. Exposed so a test builds a
    /// buffer the player can actually schedule rather than one that fails the audio
    /// graph's own check for an unrelated reason.
    static func earconFormat(sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// Loads a buffer for an earcon as if it had been preloaded from its asset.
    ///
    /// `preloadAll` reads from `Bundle.main`, and the earcon assets belong to the app
    /// target, so under test no asset loads and `play` takes its not-found branch. This
    /// lets a case exercise `play` — including that it publishes to the echo reference —
    /// with the same code path production uses.
    func loadForTesting(_ id: EarconId, buffer: AVAudioPCMBuffer) {
        cachedEarcons[id] = buffer
    }

    func play(_ id: EarconId) {
        guard let buffer = cachedEarcons[id] else {
            FileLog.shared.addMessage("[VoicePipeline] Missing: \(id)")
            return
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                FileLog.shared.addMessage("[VoicePipeline] Failed to start audio engine: \(error)")
                return
            }
        }
        // Publish before scheduling, at the submission point: the reference holds what
        // the microphone can hear. Doing this inside `play` rather than at each call site
        // means a new caller cannot forget it — the failure that matters here is an
        // earcon the filter never knew about, and that failure is silent.
        publishForEchoReference(buffer)
        player.scheduleBuffer(buffer, at: nil, options: .interrupts) {
            // Earcon finished
        }
        if !player.isPlaying { player.play() }
    }

    /// Publishes an earcon's samples as audio about to be emitted.
    ///
    /// Called at submission, matching the cloud renderer: the reference holds what the
    /// microphone can hear, and the render position is read from the node rather than
    /// assumed, because scheduling a buffer does not mean it is audible yet.
    ///
    /// The samples are not resampled when they are already at the pipeline rate. Earcons
    /// are loaded at that rate, and resampling would shift the timing the reference
    /// claims was rendered.
    func publishForEchoReference(_ buffer: AVAudioPCMBuffer) {
        guard let reference = emittedPCMReference,
              let channel = buffer.floatChannelData?[0] else { return }
        let frame = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let resampled = PlaybackResampler.toPipelineRate(
            frame,
            sourceRate: buffer.format.sampleRate
        )
        reference.append(resampled)
        reference.recordRenderPosition(renderPosition())
    }

    /// The player node's rendered position, or nil when it is not rendering.
    ///
    /// Mirrors the cloud renderer: `lastRenderTime` converted through
    /// `playerTime(forNodeTime:)` gives the position in the played audio's own frames and
    /// the host instant, so a queue lead or a restart shows as a jump rather than the
    /// reference claiming audio is audible before it is.
    private func renderPosition() -> PlaybackRenderAnchor? {
        guard let lastRender = player.lastRenderTime,
              lastRender.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: lastRender),
              playerTime.isSampleTimeValid else { return nil }
        return PlaybackRenderAnchor(
            renderedFrames: Double(playerTime.sampleTime),
            sourceSampleRate: playerTime.sampleRate,
            hostTime: lastRender.hostTime > 0
                ? AVAudioTime.seconds(forHostTime: lastRender.hostTime)
                : 0
        )
    }

    /// The loaded samples for an earcon and their source rate.
    ///
    /// Exists so a test can state the expected reference length from the real asset
    /// rather than a hard-coded number that would drift when the asset changes.
    func publishedEarconSamples(_ id: EarconId) -> (samples: [Float], sourceSampleRate: Double)? {
        guard let buffer = cachedEarcons[id],
              let channel = buffer.floatChannelData?[0] else { return nil }
        let frame = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return (frame, buffer.format.sampleRate)
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
                FileLog.shared.addMessage("[VoicePipeline] Missing asset: \(id.rawValue).wav")
                continue
            }
            guard let file = try? AVAudioFile(forReading: url) else {
                FileLog.shared.addMessage("[VoicePipeline] Failed to read: \(id.rawValue).wav")
                continue
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                FileLog.shared.addMessage("[VoicePipeline] Failed to create buffer: \(id.rawValue)")
                continue
            }
            do {
                try file.read(into: buffer)
                cachedEarcons[id] = buffer
            } catch {
                FileLog.shared.addMessage("[VoicePipeline] Read error for \(id.rawValue): \(error)")
            }
        }
    }
}
