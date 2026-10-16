import AVFoundation
import PocketCastsUtils

open class EarconPlayer {
    private let engine: AVAudioEngine?
    private let player = AVAudioPlayerNode()
    private var cachedEarcons: [EarconId: AVAudioPCMBuffer] = [:]
    /// The rate the node graph is connected at, decided ONCE from the first successfully
    /// preloaded asset. Falls back to the assets' authored rate when nothing loaded.
    /// Optional because there is no graph on the publishing-only route (`engine: nil`).
    ///
    /// Declared `var` with an explicit default, NOT a `let` assigned later: every stored
    /// property must be initialized before `self` is used in an instance method, and
    /// `preloadAll()` reads `cachedEarcons`. With a deferred assignment the `engine: nil`
    /// path returned from `init` without ever setting this, which does not compile.
    private var connectionSampleRate: Double?

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
        // Connect at the ASSETS' own rate, not the echo pipeline's.
        //
        // The six shipped earcons are mono 16-bit at 44.1 kHz (review thread 4237185302).
        // Connecting the node at 16 kHz made every `scheduleBuffer` resample down to 16 kHz
        // BEFORE the mixer, which then upsampled for the hardware — a double conversion,
        // bandwidth-limited to an 8 kHz band, with no purpose: the echo reference keeps its
        // own 16 kHz copy separately via `publishForEchoReference`, converted through the
        // handoff's resampler. What the user hears should go through the graph at the rate
        // it was authored at; what the filter needs is the 16 kHz reference copy. Those are
        // two consumers with two rates, and this is the listener-side half of that split.
        //
        // The explicit format stays (the empty-cache fallback is why): deriving it from
        // `cachedEarcons.values.first?.format` makes the graph depend on an asset having
        // loaded — if none did, the format silently becomes the mixer default and every
        // `scheduleBuffer` fails the graph's channel-count check, muting earcons with one
        // log line.
        connectionSampleRate = Self.assetSampleRate(from: cachedEarcons) ?? Self.authoredAssetSampleRate
        guard let connectionSampleRate else {
            // Unreachable by construction: the right-hand side falls back to a non-optional
            // constant. Checked rather than force-unwrapped so a future edit that makes the
            // fallback nil cannot silently skip the connect and leave a detached node that
            // fails every later `scheduleBuffer` with no signal.
            preconditionFailure("connectionSampleRate must be set before the graph is connected")
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.earconFormat(sampleRate: connectionSampleRate))
        engine.prepare()
    }

    /// The rate the shipped earcon assets are authored at (all six measured: 44.1 kHz mono).
    static let authoredAssetSampleRate: Double = 44_100

    /// The rate the preloaded assets report, or nil when nothing loaded. All shipped assets
    /// share one rate; the first non-empty buffer's format answers for the rest.
    private static func assetSampleRate(from cache: [EarconId: AVAudioPCMBuffer]) -> Double? {
        cache.values.first?.format.sampleRate
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

    /// The rate the node graph is ACTUALLY connected at, read back from the engine rather
    /// than from the value we intended to use. Exposed so a test can pin the real path:
    /// scheduling a buffer whose format does NOT match the connection format fails the
    /// graph's own check, so building a buffer at this rate exercises the same contract
    /// production does.
    ///
    /// Reading the node's own input format is deliberate (review follow-up): reporting
    /// `connectionSampleRate` would stay green even if `engine.connect(...)` were deleted
    /// or given the wrong format, because the stored value and the graph would disagree.
    /// nil when there is no graph (the publishing-route tests).
    var negotiatedSampleRateForTesting: Double? {
        guard let engine else { return nil }
        // The mixer BUS THIS PLAYER FEEDS, and its format, read from the live graph.
        //
        // Why not the obvious probes (each was tried and failed for an AVFoundation reason):
        //   * `engine.inputNode.inputFormat(forBus: 0)` reported 0.0. This player never touches
        //     the input node, so that answer describes capture, not the earcon graph.
        //   * `player.inputFormat(forBus: 0)` raised an ObjC NSRangeException ("index 0 beyond
        //     bounds for empty array") on a node with no incoming connection. Not a Swift error,
        //     so it cannot be caught; it aborts the test host outright.
        //   * `player.numberOfInputs` is 0 here BY DESIGN: `init` connects the player only
        //     OUTGOING (`connect(player, to: mainMixerNode, format:)`). Any guard that asks
        //     whether something feeds the player is therefore guaranteed to answer "no", which
        //     is why an earlier version of this probe returned nil even when the code under test
        //     was correct. A probe that can only fail measures nothing.
        //   * `AVAudioEngine.connectionPoints(forInputNode:)`, `AVAudioMixerNode.inputBuses` and
        //     `AVAudioMixerNode.inputConnectionPoint(for:)` do not exist; each failed to compile.
        //
        // `inputConnectionPoint(for:inputBus:)` on the ENGINE is the accessor this codebase
        // already uses for the same question (EpisodeOutputTap's feeder search). It returns a
        // non-optional wrapper whose `.node` is optional, hence `?.node`.
        let mixer = engine.mainMixerNode
        for bus in 0..<mixer.numberOfInputs where engine.inputConnectionPoint(for: mixer, inputBus: bus)?.node === player {
            return mixer.inputFormat(forBus: bus).sampleRate
        }
        return nil
    }

    /// The engine this player connected into, exposed so a case can inspect the graph's
    /// mixer/output side as well as the node's own format.
    var engineForTesting: AVAudioEngine? { engine }

    /// The stored rate this player chose for its connection, exposed separately from the
    /// actual graph format so a case can assert the two agree. If they diverge, the connect
    /// call used something other than what was chosen.
    var chosenSampleRateForTesting: Double? { engine == nil ? nil : connectionSampleRate }

    /// The rate the preloaded assets report, exposed so a case can pin the derivation
    /// without reading WAV headers. nil when nothing loaded.
    var assetSampleRateForTesting: Double? { Self.assetSampleRate(from: cachedEarcons) }

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
    /// Called at submission, publishing what the microphone can hear. Unlike the cloud
    /// renderer it records NO render position: the node read was measured to be nil on a
    /// first play and negative immediately after one, so no block range is submitted and
    /// an observation that cannot be placed is refused rather than guessed.
    ///
    /// **The listener-side half of the rate split (review thread 4237185302).** The graph
    /// now renders at the assets' authored rate (44.1 kHz), so the buffer handed here is no
    /// longer pre-downsampled by the connection format. The echo filter needs 16 kHz, so
    /// THIS route converts explicitly — through the same `PlaybackResampler` the handoff
    /// applies to any producer — and declares the converted rate to the handoff. Before,
    /// the double conversion happened invisibly in the audio graph; now the reference's rate
    /// is decided where the reference is written, and playback quality is not paid for it.
    /// Declaring a rate that does not match the samples would compress their apparent
    /// duration and shift the instant the reference claims they were rendered — which is
    /// what the explicit conversion below keeps honest.
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

        // No block range is submitted, and that is a measured decision rather than an omission.
        //
        // The mapping needs the new buffer's local start in the node's clock. Reading the node's
        // render position before the schedule does not give it: measured against the real node,
        // that read is nil on a first play after stop and NEGATIVE (-342 frames) immediately
        // after a play. Neither value is "where this buffer begins" — the pre-schedule read
        // describes the previous render, and the post-schedule one is an artefact of the node's
        // render-time arithmetic, not a buffer offset.
        //
        // Submitting either would anchor a later observation to PCM it does not describe — the
        // exact mismatch this mapping exists to prevent. An observation whose block cannot be
        // placed is therefore refused, and the earcon's audio stays unalignable in the filter
        // rather than misalignable. Establishing the true scheduling origin (e.g. from a
        // render-thread timestamp whose provenance is verified) is a separate change.
        lastSubmittedBlockRange = nil
        let pipelineRate = PlaybackEchoReference.pipelineSampleRate
        let sourceRate = buffer.format.sampleRate
        // Convert to the pipeline rate HERE rather than leaving it to the handoff, so the
        // declared rate and the samples agree by construction either way; the identity case
        // (a buffer already at 16 kHz) skips the work.
        let published: [Float]
        if sourceRate == pipelineRate {
            published = frame
        } else {
            published = PlaybackResampler.toPipelineRate(frame, sourceRate: sourceRate)
        }
        handoff.submit(
            published,
            producer: producerIdentity,
            sampleRate: pipelineRate,
            renderedAt: nil,
            renderedFramesInProducer: lastSubmittedBlockRange?.renderedFramesInProducer,
            producerBlockStart: lastSubmittedBlockRange?.producerBlockStart
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
        if let override = nodeSampleTimeOverride { return override }
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

    /// The node's current frame count, readable so a test can measure the scheduling origin
    /// against the real node rather than asserting over an unverified assumption.
    var nodeSampleTimeForTesting: Double? { nodeSampleTime() }

    /// Test-only: the value `nodeSampleTime()` should report instead of reading the node.
    ///
    /// The harness's node never renders, so its clock is unreadable there and a fabricated
    /// range would be nil and thus invisible. Injecting a readable clock is what makes the
    /// withdrawal observable at all: with a value supplied, a submission that uses it differs
    /// from one that withholds it.
    var nodeSampleTimeOverride: Double?

    /// The producer-local range the last publish submitted, or nil when it submitted none.
    ///
    /// Exists so the withdrawal is covered as a decision rather than inferred from the node
    /// clock: a case that only reads the clock passes whether or not the earcon submits a
    /// range, which is how the first version of this coverage came to be inert.
    private(set) var lastSubmittedBlockRange: (renderedFramesInProducer: Double, producerBlockStart: Double)?

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

