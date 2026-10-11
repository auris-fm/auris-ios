import AVFoundation
import PocketCastsUtils

open class EarconPlayer {
    private let engine: AVAudioEngine?
    private let player = AVAudioPlayerNode()
    private var cachedEarcons: [EarconId: AVAudioPCMBuffer] = [:]

    /// The session's emitted-audio reference, set once by assembly.
    ///
    /// An earcon is audio the microphone can hear, so it must be in the reference for
    /// the same reason the cloud answer is: otherwise a chime played while the user is
    /// speaking forms a segment in the microphone signal that nothing recognises as our
    /// output, and the utterance is transcribed as if the user had said it.
    var emittedPCMReference: PlaybackEchoReference?

    /// The bounded handoff used to publish earcon audio.
    ///
    /// Earcons do not need it for the deadline reason the tap producers do — `play` runs on
    /// a `Task`, not the real-time audio thread. They use it because the alternative is a
    /// **second path** that appends directly, and the reference's `append` takes the same
    /// lock and does the same memmove regardless of which thread calls it. One route for
    /// every producer is easier to reason about than two, and it means a change to the
    /// publishing rules cannot be applied to one path and missed in the other.
    var handoff: EchoReferenceHandoff?

    /// - Parameter engine: the playback engine. Optional so the publishing route can be
    ///   exercised without building an `AVAudioEngine`, which interferes with the process
    ///   audio session that capture activates — a test-side hazard, not a production one.
    init(engine: AVAudioEngine?) {
        self.engine = engine
        guard let engine else { return }
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
        if let engine, !engine.isRunning {
            do {
                try engine.start()
            } catch {
                FileLog.shared.addMessage("[VoicePipeline] Failed to start audio engine: \(error)")
                return
            }
        }
        // Two facts, recorded at the two moments they become true.
        //
        // The samples go in first, so there is no window where the earcon is audible and
        // the filter does not know about it — an utterance formed in that window would be
        // attributed to the user. Doing this inside `play` rather than at each call site
        // means a new caller cannot forget it, and that failure is silent.
        //
        // The position is recorded only after the audio is rendering. Read before
        // `scheduleBuffer`, `lastRenderTime` describes whatever played earlier, so the
        // reference would align these samples to the previous earcon's timeline — the
        // queue-lead error, where audio still queued is reported as already emitted.
        publishForEchoReference(buffer)
        guard let engine else {
            // No graph to render into: the earcon's samples are still published, because
            // what the microphone can hear is decided by the caller's intent to play, not by
            // whether this process happens to have an output. Scheduling is skipped.
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts) {
            // Earcon finished
        }
        if !player.isPlaying { player.play() }
        referenceAnchorAfterScheduling()
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
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frame = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))

        // One route, no fallback. A nil-checked second path is still a second path: it
        // differs from this one in *when* it is chosen rather than in what it does, so a
        // context that fails to attach a handoff silently keeps an older behaviour instead
        // of failing. That is the failure this avoids — the reference's `append` is not
        // called from here at all, so there is no behaviour to diverge.
        //
        // `emittedPCMReference` is therefore only used for the render-position anchor and
        // for the retire path; publishing goes through the handoff or not at all.
        guard let handoff else { return }
        handoff.submit(frame, sampleRate: buffer.format.sampleRate, renderedAt: nil)
    }

    /// Records the render position once the audio is actually rendering.
    ///
    /// Separate from publishing because the two become true at different moments: the
    /// samples are audible as soon as they are submitted, but the position that places
    /// them on the shared timeline exists only after the node renders. Recording it at
    /// submission would state that queued audio had already been emitted.
    ///
    /// Recorded **through the handoff** rather than on the reference directly, so the
    /// samples and their position travel the same route. Recording the anchor here while
    /// the samples went through the handoff would reintroduce exactly the divergence the
    /// routing change removed: two paths to one reference, one of which a future edit could
    /// miss.
    private func referenceAnchorAfterScheduling() {
        handoff?.submitRenderPosition(renderPosition())
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
        engine?.detach(player)
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
