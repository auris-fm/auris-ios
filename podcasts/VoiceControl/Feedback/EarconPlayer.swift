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
        // failure this explicit format removes. The assets are mono 16-bit at 44.1 kHz, not the pipeline rate, so this also declares the rate
          // the graph is connected at instead of leaving it to be inferred.
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
    /// The samples are published with the buffer's OWN rate rather than the pipeline's, so
    /// the handoff resamples them: the assets on disk are 44.1 kHz, not 16 kHz. Declaring the
    /// buffer's rate is what keeps the reference's timeline honest — passing the pipeline rate
    /// for audio that is not at it would compress the samples' apparent duration and shift the
    /// instant the reference claims they were rendered.
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

        // The block's producer-local range, captured from the node's own clock: the count when
        // these samples begin, plus their length. Carrying it is what lets the handoff map a
        // later position observation against this block — without a retained range there is
        // nothing to convert through, and an observation is refused rather than guessed at.
        // A node clock that is not yet readable leaves the metadata nil, honestly: an
        // unmappable block is better than one anchored at an invented zero.
        let blockStart = nodeSampleTime()
        handoff.submit(
            frame,
            producer: producerIdentity,
            sampleRate: buffer.format.sampleRate,
            renderedAt: nil,
            renderedFramesInProducer: blockStart.map { $0 + Double(frame.count) },
            producerBlockStart: blockStart
        )
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
        handoff?.submitRenderPosition(renderPosition(), producer: producerIdentity)
    }

    /// The player node's rendered position, or nil when it is not rendering.
    ///
    /// Mirrors the cloud renderer: `lastRenderTime` converted through
    /// `playerTime(forNodeTime:)` gives the position in the played audio's own frames and
    /// the host instant, so a queue lead or a restart shows as a jump rather than the
    /// reference claiming audio is audible before it is.
    /// This node's current frame count in its own clock, or nil when it cannot be read.
    ///
    /// Uses the same `playerTime(forNodeTime:)` conversion as `renderPosition()`; both must
    /// agree on the clock or a position observation and its containing block would disagree.
    /// Reading the render time requires the node to be attached to an engine — on the
    /// no-graph path there is no render clock, and nil metadata is the honest answer: the
    /// samples are published, but nothing has rendered that a position could describe.
    private func nodeSampleTime() -> Double? {
        guard engine != nil else { return nil }
        guard let lastRender = player.lastRenderTime,
              lastRender.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: lastRender),
              playerTime.isSampleTimeValid else { return nil }
        return Double(playerTime.sampleTime)
    }

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

    /// This producer's clock incarnation, rotated whenever the node restarts.
    ///
    /// `AVAudioPlayerNode.playerTime` counts from the node's start, and `stop()` returns it to
    /// zero. A position observed before that reset therefore uses the same numbers as one after
    /// it, while describing different audio, so the incarnation changes HERE — at the reset —
    /// and travels with every block and position this producer submits. Rotating it anywhere
    /// else, or on an unrelated producer, would retire positions that are still valid.
    private var nodeIncarnation: UInt64 = 0

    /// Retires the current incarnation and begins a new one. Called wherever this producer's
    /// node clock returns to zero.
    private func rotateNodeIncarnation() {
        nodeIncarnation &+= 1
    }

    /// The identity this producer is currently submitting under.
    ///
    /// Readable so a test can observe a real reset through the lifecycle rather than
    /// constructing both values by hand: the restart case captures this before `stop()` and
    /// expects the post-restart incarnation to be the captured one advanced by exactly one.
    var currentIdentity: EchoReferenceHandoff.ProducerIdentity { producerIdentity }

    /// The identity every submission from this producer carries.
    private var producerIdentity: EchoReferenceHandoff.ProducerIdentity {
        EchoReferenceHandoff.ProducerIdentity(kind: .earcon, incarnation: nodeIncarnation)
    }

    /// Stopping the node returns its clock to zero, so the incarnation this producer has been
    /// submitting under is retired here rather than at the next submission: a position observed
    /// after the restart must not be matched to a block from before it.
    func stop() {
        player.stop()
        rotateNodeIncarnation()
        handoff?.rotateIncarnation(for: .earcon, to: nodeIncarnation)
    }

    func release() {
        player.stop()
        rotateNodeIncarnation()
        handoff?.rotateIncarnation(for: .earcon, to: nodeIncarnation)
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
