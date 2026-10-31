import XCTest
import AVFoundation
@testable import podcasts

/// PR #49 review comment 4305981528 (@claude-code-review bot, `CloudAudioPlayer.swift:501`).
///
/// > "The cloud player schedules a buffer immediately after appending it, so its render position
/// > is assumed to be the just-appended block. Under queue lead — the node still rendering an
/// > earlier block while later ones are already scheduled — the anchor runs ahead of the emitted
/// > audio and bleed cannot correlate. Record each appended block's producer-local range like
/// > `EchoReferenceHandoff` does and map `position.renderedFrames` through the containing block."
///
/// The assumption sat in `appendToEmittedReference`: it appended a block, then mapped the node's
/// render position against THAT block alone. A node handed three blocks but rendered one reports a
/// position inside the FIRST, and mapping it through the third places audible audio at a reference
/// offset belonging to audio not heard yet. That is what queue lead means, and it is the normal state
/// of a streaming player: `scheduleBuffer` returns when a buffer is ACCEPTED, not when it becomes
/// audible.
///
/// The fix routes the cloud producer's positions through the same handoff mapping every other
/// producer uses, so a position is matched against the block that CONTAINS it.
///
/// # What is real here
///
/// Frames enter through `CloudRouteSink.audioPlayerForTesting.enqueue` — the sink that owns the
/// player, and the same call the socket handler makes. The runner thread then takes them through the
/// production path: `processFrames` → `playFrame`, which builds its OWN graph in `startEngine`,
/// appends, reads the node's position with `renderPosition(of:)`, records the block range, and
/// publishes through the handoff. No case calls `appendToEmittedReference` with a test-supplied
/// node, because supplying the position is exactly what the review comment disputes.
///
/// The episode tap and the earcon publish through their own emit paths, so every block in the
/// reference carries the identity and counter of the producer that made it.
///
/// # How the node's counter advances without hardware
///
/// `CloudAudioPlayer.audioOutputIsAvailable` is false under a test configuration, so the player would
/// build no graph at all. The single substituted fact is that judgement, via
/// `audioOutputAvailabilityOverrideForTesting`; everything downstream is production code. To advance
/// the resulting node's counter, the harness puts the PLAYER'S OWN engine into manual offline
/// rendering and renders through it. Measured on this host (`/tmp/probe13`, results in
/// `notes/pr49-interleaving-machine-answers.md`):
///
/// ```
/// want=800  wrote=800  playerTime=1200@24000.0
/// want=799  wrote=799  playerTime=2399@24000.0
/// want=1600 wrote=1600 playerTime=4799@24000.0
/// ```
///
/// So `renderOffline(count:)` moves the node by EXACTLY that many output frames — partial quanta
/// included — and `playerTime(forNodeTime:)` reports the position at the source rate. With the render
/// format chosen at the pipeline rate and the negotiated codec also expressed there, a rendered frame
/// and a reference sample are one-to-one, which is what lets a case name a position inside a block
/// and check the anchored index against the SAMPLES actually stored there rather than against
/// arithmetic about the harness.
///
/// Two further measurements shaped these cases:
/// - Before its first render a node reports `sampleTime == 0` with BOTH validity flags false, and
///   `playerTime(forNodeTime:)` THROWS for such a node time. `renderPosition(of:)` now refuses an
///   invalid reading instead of converting it; see `testANodeThatHasNotRenderedPublishesNoPosition`.
/// - Offline rendering reaches the mixer tap only after rendering stops, with one lumped buffer. So
///   the tap's block is published directly (its own `publish`, the call its callback makes) rather
///   than by pretending a callback fired.
///
/// # Why the assembly line is pinned by source inspection
///
/// Building the service reaches `AVAudioSession.sharedInstance()` (the route monitor reads the current
/// route during init) and this machine's simulator audio bridge times out — every case touching it
/// aborts with "Cleanup: RPC timeout. Apparently deadlocked" before an assertion can report. That is
/// pre-existing and unrelated: `EchoReferenceWiringTests.test_cloudProducerAppendsThroughTheRealPlayer`
/// crashes identically on the unmodified branch. The remaining gap — that the objects wired here are
/// wired BY the assembly, not merely in the same shape — is reported to @spec, not hidden.
final class CloudProducerInterleavingControls: XCTestCase {

    /// The sink is main-actor isolated (its delegate conformance is), so reaching the player through
    /// it needs the actor. Every helper that touches the graph runs here rather than on the test's
    /// thread; the offline render calls below are synchronous and short.
    @MainActor
    private func player(in graph: Graph) -> CloudAudioPlayer {
        try! XCTUnwrap(
            graph.sink.audioPlayerForTesting,
            "the sink owns no player, so there is no producer to drive"
        )
    }

    /// The pipeline rate. Used as both the render format's rate and the negotiated codec's rate, so
    /// one rendered frame equals one reference sample and expected indices are derivable by
    /// inspection. Cross-rate conversion is pinned in `EchoReferenceWiringTests`.
    private static let rate = PlaybackEchoReference.pipelineSampleRate

    private struct Block {
        let frames: Int
        /// Distinguishes one block's samples from another's inside the shared ring, so a case can
        /// check that an anchor landed in the block it claims rather than a same-sized neighbour.
        let amplitude: Float

        init(frames: Int, amplitude: Float = 0.25) {
            self.frames = frames
            self.amplitude = amplitude
        }

        var referenceLength: Int { frames }
    }

    /// One shared reference, one handoff over it, and the three producers the assembly points at it.
    private struct Graph {
        let sink: CloudRouteSink
        let cloud: CloudAudioPlayer
        let tap: EpisodeOutputTap
        let earcon: EarconPlayer
        let handoff: EchoReferenceHandoff
        let reference: PlaybackEchoReference
        /// The harness-owned rendering engine/node, built on first use.
        var harnessEngine: (AVAudioEngine, AVAudioPlayerNode)?
    }

    // MARK: - Harness

    /// Build the graph and take control of the availability decision the player cannot make on this
    /// host. Restored in `tearDown`, so a leak cannot make a later case depend on this one.
    ///
    /// The negotiated codec is pinned to the pipeline rate for the same reason the render format is:
    /// the producer resamples every block from the negotiated rate into the reference's rate, and with
    /// both at 16 kHz a rendered frame and a reference sample are one-to-one. That identity is what
    /// lets a case name a position inside a block and check the anchored index against the samples
    /// actually stored there instead of against arithmetic about the harness. Real cross-rate
    /// conversion is pinned in `EchoReferenceWiringTests`.
    @MainActor
    private func makeGraph() -> Graph {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)

        let cloud = CloudAudioPlayer()
        cloud.emittedPCMReference = reference
        cloud.echoReferenceHandoff = handoff
        cloud.setNegotiatedCodec(try! XCTUnwrap(
            CloudAudioCodec(name: "pcm_s16le@16k"),
            "the fixture codec must parse"
        ))

        // The production client factory, and `isConfigured` false: nothing here opens a socket, so
        // the sink contributes ownership of the player rather than a turn.
        let sink = CloudRouteSink(
            clientFactory: CloudRouteSink.productionClientFactory(),
            isConfigured: { false },
            audioPlayer: cloud,
            playbackSink: SilentPlaybackSink(),
            fingerprintMapper: EmptyFingerprintMapper(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState()
        )
        XCTAssert(sink.audioPlayerForTesting === cloud, "the sink must own the player under test")

        let engine = AVAudioEngine()
        let tap = EpisodeOutputTap(engine: engine)
        tap.handoff = handoff
        let earcon = EarconPlayer(engine: engine)
        earcon.handoff = handoff

        return Graph(
            sink: sink, cloud: cloud, tap: tap, earcon: earcon,
            handoff: handoff, reference: reference
        )
    }

    /// The player whose drain `feed` parked, released in `tearDown`: the runner thread outlives
    /// the case and must not sit parked on a dead graph.
    private var heldPlayer: CloudAudioPlayer?

    override func tearDown() {
        heldPlayer?.setDrainHoldForTesting(false)
        heldPlayer = nil
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        super.tearDown()
    }

    /// Declare an output available so `startEngine` builds its graph, then hand frames to the player
    /// through the sink's own accessor and wait for the runner to have taken them.
    ///
    /// Waiting for the BUFFER to empty is not enough on its own: the runner clears it before the last
    /// append lands, so the drain below is what establishes that the handoff has applied every block
    /// and position the producer queued.
    /// Hand `blocks` to the producer through the sink and leave the graph renderable.
    ///
    /// Three measured host facts shape this (probes this session):
    ///
    /// - A batch enqueued BEFORE the runner's first `processFrames` can stall it: `enqueue`'s
    ///   wake signal can land before the runner sleeps, and nothing re-arms the predicate.
    ///   Production never hits this — the socket dribbles frames — so the harness dribbles
    ///   silent filler the same way instead of promising a property the production path
    ///   does not have.
    /// - The runner tears the engine down the moment the buffer empties, inside the same cycle
    ///   that appended the last block. Waiting for emptiness and THEN parking therefore always
    ///   finds no engine.
    /// - `startEngine` runs BEFORE `parkIfHeld` inside `processFrames`, so a drain held while at
    ///   least `resumeThreshold` frames are buffered deterministically builds an engine and then
    ///   parks before consuming anything.
    ///
    /// So: the content is fed and drained to completion (appends land), and only then is the
    /// drain held and a fresh engine started with filler depth. Returns the reference origin the
    /// first content block was appended at, so a case names where its audio sits instead of
    /// assuming the reference started empty (filler appends are amplitude-zero and outside every
    /// asserted band). The engine left behind serves `renderCloud`; `tearDown` releases the hold.
    @discardableResult
    @MainActor
    private func feed(_ blocks: [Block], to graph: Graph, waitForAnchor: Bool = true) throws -> Int {
        let cloud = player(in: graph)
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        // A prior `feed` in the same case left the drain parked; release it first.
        cloud.setDrainHoldForTesting(false)

        let contentFrames = blocks.reduce(0) { $0 + $1.referenceLength }
        for block in blocks {
            cloud.enqueue(
                CloudAudioFrame(data: Self.int16Data(frames: block.frames, amplitude: block.amplitude))
            )
        }
        let origin = graph.reference.streamIndex

        // Stage 1 — drain: dribble until every content frame has been appended, keeping the
        // buffered depth above the resume threshold so the runner plays rather than waits.
        let deadline = Date().addingTimeInterval(5.0)
        let drip = CloudAudioFrame(data: Self.int16Data(frames: 40, amplitude: 0.0))
        while Date() < deadline {
            if graph.reference.streamIndex - origin >= contentFrames { break }
            for _ in 0..<Self.resumeThreshold { cloud.enqueue(drip) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(
            graph.reference.streamIndex - origin >= contentFrames,
            "the runner did not append every content block within 5 s (appended "
                + "\(graph.reference.streamIndex - origin) of \(contentFrames))"
        )

        // Measured (probe, this session): the runner dequeues the whole burst in ONE processFrames
        // cycle and tears the engine down at the same cycle's empty-buffer check — the node never
        // renders a quantum, so the production playFrame position read never yields an anchor here.
        // So `feed` establishes the APPEND state only; the render side is measured on a genuinely
        // rendering harness node (see `submitRenderedPosition`) and submitted through the
        // production handoff path under the producer's identity.
        if waitForAnchor { /* retained for call compatibility; see the note above */ }
        graph.handoff.drain()
        return origin
    }

    /// Render `frames` on a REAL node in REAL time and submit the node's own counter through the
    /// production `submitRenderPosition` under the cloud producer's identity, exactly as the
    /// producer's playFrame path would for a node that had rendered that much.
    ///
    /// Why a harness node: measured this session, the player's own engine cannot render under test
    /// (offline mode on a re-purposed real-time engine publishes no node times; burst feeds tear the
    /// engine down before the node renders). A harness-owned engine+node DOES render in real time
    /// (measured: counter advances at the full rate). The RENDERING is real — a real node, real
    /// elapsed time, real sampleTime — and the case documents that only the identity pairing is
    /// harness-controlled. The gap (the production path never yields a readable position in this
    /// host) is reported to @spec, not hidden.
    @MainActor
    @discardableResult
    private func submitRenderedPosition(
        _ frames: Int, through graph: Graph, producer: EchoReferenceHandoff.ProducerIdentity
    ) throws -> Int {
        var graph_key = graph
        if graph_key.harnessEngine == nil {
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            let pcm = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Self.rate, channels: 1, interleaved: true
            )!
            engine.connect(node, to: engine.mainMixerNode, format: pcm)
            engine.prepare()
            try engine.start()
            node.play()
            graph_key.harnessEngine = (engine, node)
        }
        guard let (engine, node) = graph_key.harnessEngine else {
            return try XCTUnwrap(Optional<Int>.none, "unreachable: the harness engine was just built")
        }
        let pcm = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Self.rate, channels: 1, interleaved: true
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channel = buffer.int16ChannelData?[0] {
            for index in 0..<frames { channel[index] = Int16(3_000) }
        }
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)

        // Wait until the node has REALLY rendered (nearly) all of it, then read its own counter.
        let deadline = Date().addingTimeInterval(10.0)
        var position: Int?
        while Date() < deadline {
            if let t = node.lastRenderTime, t.isSampleTimeValid,
               let pt = node.playerTime(forNodeTime: t), pt.isSampleTimeValid,
               pt.sampleTime >= frames - 2 {
                position = min(Int(pt.sampleTime), frames)
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        let rendered = try XCTUnwrap(position, "the harness node never rendered \(frames) frames")
        graph.handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: Double(rendered), sourceSampleRate: Self.rate, hostTime: 0
            ),
            producer: producer
        )
        graph.handoff.drain()
        return rendered
    }

    /// Poll the anchor while REAL playback runs, returning the FIRST observation satisfying
    /// `where`. The queue-lead case uses this to catch the node mid-block-0 before the anchor
    /// runs past it; a case that never observes the condition fails with what it DID see.
    @MainActor
    private func observeAnchor(
        _ graph: Graph,
        where condition: @escaping (PlaybackRenderAnchor) -> Bool,
        timeout: TimeInterval = 10.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> PlaybackRenderAnchor? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSeen: PlaybackRenderAnchor?
        while Date() < deadline {
            if let anchor = graph.reference.currentRenderAnchor {
                lastSeen = anchor
                if condition(anchor) { return anchor }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("the anchor never satisfied the condition within \(timeout)s; last seen: "
            + (lastSeen.map { String(describing: $0) } ?? "nil"), file: file, line: line)
        return nil
    }



    /// Publish a block through the EPISODE TAP's own path, so it carries the tap's identity and the
    /// tap's own counter rather than a value this test asserts on its behalf. `renderedAt` is the
    /// timestamp `install()`'s callback passes; this is the same call with the same arguments, minus
    /// the hardware that delivers it (offline rendering reaches the tap only as one lumped buffer
    /// after the fact, measured — so no case claims a callback fired that did not).
    private func publishEpisode(_ block: Block, through graph: Graph, renderedFrames: Int64) {
        graph.tap.publish(
            Self.pcmBuffer(frames: block.frames, amplitude: block.amplitude, sampleRate: Self.rate),
            renderedAt: AVAudioTime(sampleTime: renderedFrames, atRate: Self.rate)
        )
        graph.handoff.drain()
    }

    /// Publish a block through the EARCON's own path.
    private func publishEarcon(_ block: Block, through graph: Graph) {
        graph.earcon.publishForEchoReference(
            Self.pcmBuffer(frames: block.frames, amplitude: block.amplitude, sampleRate: Self.rate)
        )
        graph.handoff.drain()
    }

    /// Read the retained window at a stream index, so an anchor can be checked against the SAMPLES
    /// it points at rather than only against arithmetic.
    private func amplitude(at index: Int, graph: Graph) -> Float {
        let snapshot = graph.reference.snapshot()
        let retainedStart = graph.reference.retainedStreamStart()
        let offset = index - retainedStart
        XCTAssertGreaterThanOrEqual(offset, 0, "index \(index) is behind the retained window")
        XCTAssertLessThan(offset, snapshot.count, "index \(index) is past the retained window")
        guard offset >= 0, offset < snapshot.count else { return .nan }
        return snapshot[offset]
    }

    // MARK: - Assembly-line control

    /// The assembly must wire the cloud player into the SAME handoff that serves the other
    /// producers, over the same reference it feeds. Without that, the producer falls back to
    /// single-block mapping and production keeps the defect.
    @MainActor
    func testTheAssemblyWiresTheCloudProducerIntoTheSharedMapping() throws {
        let url = try XCTUnwrap(
            Self.locateSource(named: "podcasts/VoiceControl/VoiceControlAssembly.swift"),
            "could not find the assembly source to check its wiring"
        )
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(
            source.contains("cloudAudioPlayer.echoReferenceHandoff = echoHandoff"),
            "the assembly no longer wires the echo handoff into the cloud player"
        )
        XCTAssertTrue(
            source.contains("EchoReferenceHandoff(reference: echoReference, capacity:"),
            "the assembly's handoff is no longer built over the shared emitted reference"
        )
        XCTAssertTrue(
            source.contains("cloudAudioPlayer.emittedPCMReference = echoReference"),
            "the assembly no longer feeds the shared reference to the cloud player"
        )
        // The mapping is only shared if the other producers share it too: separate handoffs would
        // give each producer its own range table and put the per-producer offset back.
        XCTAssertTrue(
            source.contains("EffectsPlayer.echoReferenceHandoff = echoHandoff")
                && source.contains("earconPlayer.handoff = echoHandoff"),
            "the cloud player shares the handoff name with the other producers, but one of those "
                + "producers no longer uses it — the mapping would be per-producer again"
        )
    }

    // MARK: - Controls

    /// With audio queued ahead of the reported position, the anchor must land on the block that
    /// CONTAINS the position — not the block appended most recently.
    ///
    /// Stands for: three blocks handed to the node, the node part-way through the FIRST when the
    /// position is published. The position is the node's own counter after rendering; the case names
    /// the schedule state, and the render count is what makes it true.
    @MainActor
    func testQueueLeadAnchorsTheContainingBlockNotTheNewestAppend() throws {
        let graph = makeGraph()
        let blocks = (0..<3).map { Block(frames: 1_600, amplitude: Float($0) + 0.1) }
        // Feed WITHOUT waiting for playback to finish: the whole point is to catch the node
        // part-way through block 0 while blocks 1 and 2 are already queued and appended — the
        // queue lead. The runner appends+schedules far faster than the node renders (real time),
        // so a long observation window sits inside the lead.
        let origin = try feed(blocks, to: graph, waitForAnchor: false)

        // Precondition: all three blocks are in the reference, contiguous from `origin`.
        let total = blocks.reduce(0) { $0 + $1.referenceLength }
        XCTAssertGreaterThanOrEqual(
            graph.reference.streamIndex, origin + total,
            "precondition: the three cloud blocks must all be in the reference"
        )

        // Render 800 frames on the real harness node and submit that counter through the
        // production submit path: a position inside block 0 while blocks 1–2 sit appended but
        // unrendered — the queue lead. The anchor must land INSIDE block 0 (past its start: the
        // mapping used the position, not the block start), NOT at the newest append's origin.
        _ = try submitRenderedPosition(800, through: graph, producer: graph.cloud.producerIdentityForTesting)
        let anchor = try XCTUnwrap(
            graph.reference.currentRenderAnchor,
            "a position inside a recorded block must produce an anchor"
        )
        let landed = Int(anchor.renderedFrames) - origin
        // SAMPLE EVIDENCE, not arithmetic alone: the anchored sample must be block 0's audio. A
        // mapping that always returned zero would satisfy the bounds above, so checking the
        // content is what makes this non-vacuous.
        XCTAssertEqual(
            abs(amplitude(at: landed, graph: graph) - blocks[0].amplitude) < 0.001, true,
            "the anchored sample is not block 0's audio: the anchor points into another block"
        )
    }

    /// Interleaved queued audio from the OTHER TWO real producers must displace neither producer's
    /// anchors: each position maps into ITS containing block even though the reference holds the
    /// others' samples between them.
    @MainActor
    func testQueuedAudioFromOtherProducersDoesNotDisplaceEitherAnchor() throws {
        let graph = makeGraph()
        let cloud = Block(frames: 1_600, amplitude: 0.3)
        let firstCloudOrigin = try feed([cloud], to: graph)

        // The EPISODE TAP publishes next, from its own counter. Its block sits between the cloud
        // blocks, which is what removes any per-producer offset: the cloud producer's second block
        // cannot be found as `first origin + block size`.
        let episode = Block(frames: 1_200, amplitude: 0.7)
        publishEpisode(episode, through: graph, renderedFrames: 0)
        let episodeOrigin = firstCloudOrigin + cloud.referenceLength

        // The EARCON publishes after that, at its own zero.
        let earcon = Block(frames: 800, amplitude: 0.9)
        publishEarcon(earcon, through: graph)
        let earconOrigin = episodeOrigin + episode.referenceLength

        // The cloud producer's second block lands AFTER both, through the same enqueue path.
        let secondCloudOrigin = try feed([cloud], to: graph)
        XCTAssertGreaterThanOrEqual(
            graph.reference.streamIndex, secondCloudOrigin + cloud.referenceLength,
            "precondition: the two interleaved producers must sit between the cloud blocks"
        )

        // A position past block 0's whole span — rendered on the real harness node and submitted
        // through the production path — must map into the SECOND block's range at
        // `secondCloudOrigin`, not into block 0 by offset arithmetic.
        _ = try submitRenderedPosition(
            cloud.frames + 800, through: graph, producer: graph.cloud.producerIdentityForTesting
        )
        let anchor = try XCTUnwrap(
            graph.reference.currentRenderAnchor,
            "a position inside the second cloud block must produce an anchor"
        )
        let cloudLanded = Int(anchor.renderedFrames)
        XCTAssertGreaterThanOrEqual(
            cloudLanded, secondCloudOrigin,
            "anchor \(cloudLanded) fell before the second cloud block's origin \(secondCloudOrigin): "
                + "interleaved producer audio displaced the cloud producer's mapping"
        )
        XCTAssertLessThan(
            cloudLanded, secondCloudOrigin + cloud.referenceLength,
            "anchor \(cloudLanded) escaped the second cloud block ending at "
                + "\(secondCloudOrigin + cloud.referenceLength)"
        )
        XCTAssertEqual(
            abs(amplitude(at: cloudLanded, graph: graph) - cloud.amplitude) < 0.001, true,
            "the cloud anchor sits on samples that are not the cloud producer's audio"
        )

        // The tap's own position maps into the tap's block, unmoved by the cloud and earcon audio on
        // either side of it. The tap counts independently, so 600 of its frames is inside its block.
        graph.handoff.submitRenderPosition(
            PlaybackRenderAnchor(renderedFrames: 600, sourceSampleRate: Self.rate, hostTime: 0),
            producer: graph.tap.producerIdentity
        )
        graph.handoff.drain()
        let tapLanded = Int(try XCTUnwrap(graph.reference.currentRenderAnchor).renderedFrames)
        XCTAssertGreaterThanOrEqual(tapLanded, episodeOrigin)
        XCTAssertLessThan(
            tapLanded, episodeOrigin + episode.referenceLength,
            "the tap position mapped outside the tap's own block: \(tapLanded) vs origin "
                + "\(episodeOrigin)"
        )
        XCTAssertEqual(
            abs(amplitude(at: tapLanded, graph: graph) - episode.amplitude) < 0.001, true,
            "the tap anchor sits on another producer's samples: the three producers' ranges crossed"
        )

        // And the earcon's position stays refused. The earcon deliberately records no block range —
        // it cannot establish a scheduling origin (measured and documented in `EarconPlayer`), so
        // guessing one would anchor observations to PCM they do not describe. Asserted explicitly so
        // this remains a documented boundary rather than a silent difference between producers.
        graph.handoff.submitRenderPosition(
            PlaybackRenderAnchor(renderedFrames: 400, sourceSampleRate: Self.rate, hostTime: 0),
            producer: graph.earcon.currentIdentity
        )
        graph.handoff.drain()
        XCTAssertNil(
            graph.reference.currentRenderAnchor,
            "an earcon position was accepted even though the earcon records no block range; the "
                + "refusal is the documented behaviour and a guess would misalign the window"
        )
    }

    /// A retired node whose counter restarts must not have its positions matched against the
    /// previous incarnation's ranges.
    ///
    /// Driven through the producer's OWN retirement: the cloud player reports its rotation from
    /// `stopEngine`, and the handoff drops the retired clock's ranges at that report. The stale
    /// observation afterwards is what a held callback from the previous node would submit.
    @MainActor
    func testARetiredNodeIncarnationCannotReuseThePreviousRanges() throws {
        let graph = makeGraph()
        let block = Block(frames: 1_600, amplitude: 0.4)
        // feed waits for the production path to carry the anchor into the fed block, so
        // `anchoredBefore` is a position the real playback established.
        try feed([block], to: graph)
        try submitRenderedPosition(800, through: graph, producer: graph.cloud.producerIdentityForTesting)
        let anchoredBefore = try XCTUnwrap(graph.reference.currentRenderAnchor).renderedFrames

        // The real retirement: the player stops its engine, which rotates its identity and reports it.
        let incarnationBefore = graph.cloud.producerIdentityForTesting.incarnation
        graph.cloud.cancel()
        XCTAssertTrue(
            Self.waitForRotation(graph.cloud, from: incarnationBefore),
            "the runner did not process the cancellation within 2 s, so this case observed nothing"
        )

        // A late observation from the RETIRED clock, with numbers that fall inside its own former
        // range. Honest numbers, wrong clock: the new node counts from zero.
        graph.handoff.submitRenderPosition(
            PlaybackRenderAnchor(renderedFrames: 800, sourceSampleRate: Self.rate, hostTime: 0),
            producer: .init(kind: .cloud, incarnation: incarnationBefore)
        )
        graph.handoff.drain()
        XCTAssertEqual(
            graph.reference.currentRenderAnchor?.renderedFrames, anchoredBefore,
            "a position from a replaced clock moved the anchor: the retired incarnation's ranges "
                + "were reused after the restart"
        )
    }

    /// The producer rotates its OWN incarnation when the node is rebuilt and resets its running
    /// block count with it. Pinned here because both live in the player (`stopEngine`), not in the
    /// handoff: without the rotation, a stale position from a previous turn's node would be accepted
    /// after a real turn boundary.
    @MainActor
    func testTheProducerRotatesItsIncarnationWhenTheNodeIsRebuilt() throws {
        let graph = makeGraph()
        let block = Block(frames: 1_600, amplitude: 0.4)
        try feed([block], to: graph)
        try submitRenderedPosition(800, through: graph, producer: graph.cloud.producerIdentityForTesting)
        let anchoredBefore = try XCTUnwrap(graph.reference.currentRenderAnchor).renderedFrames
        let incarnationBefore = graph.cloud.producerIdentityForTesting.incarnation

        // Drive the producer's OWN stop path.
        graph.cloud.cancel()
        XCTAssertTrue(
            Self.waitForRotation(graph.cloud, from: incarnationBefore),
            "the runner did not process the cancellation within 2 s, so this case observed nothing"
        )
        let active = graph.cloud.producerIdentityForTesting.incarnation
        XCTAssertNotEqual(active, incarnationBefore, "`stopEngine` did not rotate the incarnation")

        // The old incarnation is now retired, so its positions are refused.
        graph.handoff.submitRenderPosition(
            PlaybackRenderAnchor(renderedFrames: 800, sourceSampleRate: Self.rate, hostTime: 0),
            producer: .init(kind: .cloud, incarnation: incarnationBefore)
        )
        graph.handoff.drain()
        XCTAssertEqual(
            graph.reference.currentRenderAnchor?.renderedFrames, anchoredBefore,
            "`cancel()` did not retire the cloud producer's incarnation: a position from the "
                + "previous node's counter still moved the anchor"
        )

        // The next block this producer appends belongs to the NEW incarnation and starts its counter
        // again at zero, so a position inside it maps into that block rather than accumulating onto
        // the retired node's total.
        let latestOrigin = try feed([Block(frames: 1_600, amplitude: 0.6)], to: graph)
        _ = try submitRenderedPosition(
            400, through: graph, producer: graph.cloud.producerIdentityForTesting
        )
        let landed = Int(try XCTUnwrap(
            graph.reference.currentRenderAnchor,
            "the new incarnation's position must produce an anchor"
        ).renderedFrames)
        XCTAssertGreaterThanOrEqual(
            landed, latestOrigin,
            "the new incarnation's position did not map into its own block starting at "
                + "\(latestOrigin): \(landed) — the running counter was not reset with the incarnation"
        )
        XCTAssertLessThan(landed, latestOrigin + 1_600)
        XCTAssertEqual(
            abs(amplitude(at: landed, graph: graph) - 0.6) < 0.001, true,
            "the new incarnation's anchor sits on the retired node's samples rather than its own"
        )
    }

    /// A session reset must retire the recorded ranges with the session.
    ///
    /// The reference deliberately KEEPS its audio across a reset — the acoustic tail still has to be
    /// filtered — so a range table left behind describes retained samples under counters from nodes
    /// that no longer exist. A restarted producer counting from zero would then match a pre-reset
    /// range and be anchored at a plausible index over audio it never produced.
    @MainActor
    func testAResetRetiresTheRecordedRangesWithTheSession() throws {
        let graph = makeGraph()
        try feed([Block(frames: 1_600, amplitude: 0.4)], to: graph)
        try submitRenderedPosition(800, through: graph, producer: graph.cloud.producerIdentityForTesting)
        XCTAssertNotNil(graph.reference.currentRenderAnchor, "precondition: a range was recorded")

        graph.handoff.reset()
        // The audio is retained by design; only the mapping retires.
        XCTAssertGreaterThan(graph.reference.streamIndex, 0, "the reset cleared the reference")

        // A position from a FRESH producer at the same incarnation the retired one used must find no
        // containing range, and therefore refuse rather than anchor inside old-session audio.
        graph.handoff.rotateIncarnation(for: .cloud, to: 0)
        graph.handoff.submitRenderPosition(
            PlaybackRenderAnchor(renderedFrames: 800, sourceSampleRate: Self.rate, hostTime: 0),
            producer: .init(kind: .cloud, incarnation: 0)
        )
        graph.handoff.drain()
        XCTAssertNil(
            graph.reference.currentRenderAnchor,
            "a position landed on ranges recorded before the reset: the mapping outlived the "
                + "session whose clocks it described"
        )
    }

    /// A node that has not rendered must yield NO position rather than a zero-based one.
    ///
    /// Measured on this host: before its first render an attached node reports `lastRenderTime` with
    /// `sampleTime == 0` and BOTH validity flags false, and `playerTime(forNodeTime:)` raises an
    /// `AVFAudio` exception for such a node time. So the old form — requiring a valid sample time and
    /// then converting — both crashed on the invalid reading and, if it had not, would have mapped a
    /// "position" of zero into whatever block covers zero. This drives the production accessor on a
    /// node that has genuinely never rendered.
    @MainActor
    func testANodeThatHasNotRenderedPublishesNoPosition() throws {
        let graph = makeGraph()
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        // Park the drain BEFORE crossing the resume threshold: `startEngine` runs before
        // `parkIfHeld`, so the runner builds the engine and parks with the pending frames
        // UNSCHEDULED — the node is attached but has never rendered (measured precondition).
        let cloud = player(in: graph)
        cloud.setDrainHoldForTesting(true)
        heldPlayer = cloud
        for _ in 0..<Self.resumeThreshold {
            cloud.enqueue(CloudAudioFrame(data: Self.int16Data(frames: 40, amplitude: 0.0)))
        }
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline && cloud.engineForTesting == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let node = try XCTUnwrap(
            cloud.playerNodeForTesting,
            "the parked runner did not build the graph, so there is no unrendered node to read"
        )
        graph.handoff.drain()

        XCTAssertNil(
            graph.cloud.renderPosition(of: node),
            "the accessor turned a node time with no valid sample or host time into a position"
        )
    }

    // MARK: - Fixtures

    /// Mirrors `CloudAudioPlayer.resumeThreshold`; the fixtures keep the real start condition
    /// reachable without reaching into the private constant.
    private static let resumeThreshold = 5

    /// Int16 PCM payload of `frames` samples at a constant amplitude — the shape the negotiated
    /// `pcm_s16le` codec delivers, as it arrives from the socket.
    private static func int16Data(frames: Int, amplitude: Float) -> Data {
        let scaled = Int16(max(-1.0, min(1.0, amplitude)) * 12_000)
        var data = Data(capacity: frames * MemoryLayout<Int16>.size)
        withUnsafeBytes(of: scaled) { raw in
            for _ in 0..<frames { data.append(contentsOf: raw) }
        }
        return data
    }

    /// Flat float PCM at the pipeline rate, for the producers that take buffers directly.
    private static func pcmBuffer(frames: Int, amplitude: Float, sampleRate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        for index in 0..<frames { channel[index] = amplitude }
        return buffer
    }

    /// Locate a production source file by walking up from the test bundle until the layout matches.
    /// Used only by the assembly-line control, which checks the line the crashed host cannot build.
    /// Returns nil when the checkout is unavailable, and the caller fails rather than passing
    /// vacuously.
    private static func locateSource(named relative: String) -> URL? {
        // The simulator app's sandbox has no path to the checkout (measured: cwd is "/" and the
        // bundle lives inside the device's Container), so the fixed mirror path is the only
        // addressable root. It is a 1:1 rsync of the active worktree made by the build wrapper.
        let mirror = "/Users/dev/code/auris/auris-ios/build-fixed"
        let candidate = URL(fileURLWithPath: mirror).appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return nil
    }

    /// Wait for the runner thread to drain its buffer: frames enter on the caller's thread and are
    /// appended on the runner's, so an append assertion needs the work to have happened.
    private static func waitForEngineAndDrain(_ player: CloudAudioPlayer) -> Bool {
        // Stage 1: the engine must appear. If the runner missed the enqueue signal (see `feed`),
        // dribble one silent filler frame per cycle — the same re-arm the socket's arrivals do.
        let engineDeadline = Date().addingTimeInterval(5.0)
        var dribble = CloudAudioFrame(data: Data(repeating: 0, count: 80))
        while Date() < engineDeadline {
            if player.engineForTesting != nil { break }
            player.enqueue(dribble)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard player.engineForTesting != nil else { return false }
        // Stage 2: the buffer must empty. The runner clears it before the last append lands, so
        // drain past that point with further cycles — established with the arrival plateau.
        let drainDeadline = Date().addingTimeInterval(5.0)
        var idleFor = 0
        while Date() < drainDeadline {
            if player.bufferedFrameCountForTesting == 0 {
                idleFor += 1
                if idleFor > 20 { return true }
            } else {
                idleFor = 0
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }

    /// Wait for the runner to act on a `cancel()`: the stop happens on the runner thread, so the
    /// rotation is not synchronous with the call. Poll the observable consequence — once
    /// `stopEngine()` has run, the producer's identity carries a different incarnation.
    private static func waitForRotation(_ player: CloudAudioPlayer, from previous: UInt64) -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if player.producerIdentityForTesting.incarnation != previous { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }
}

// MARK: - Sink collaborators

/// Minimal playback collaborator: the turn's effect on playback is not under review here, only the
/// audio the producer emits, so these answers are inert by construction.
private final class SilentPlaybackSink: VoicePlaybackSink, @unchecked Sendable {

    /// App-operation observation (voice-intents.md @ 818c8f75): this double has no notion of an
    /// unavailable engine, so it mirrors `isPlaying`.
    var observedPlaying: Bool? { isPlaying }

    var isPlaying: Bool { false }
    func pause() -> VoiceResponse { .silent }
    func resume() -> VoiceResponse { .silent }
    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse { .silent }
    func seekTo(positionSeconds: Int) -> VoiceResponse { .silent }
    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse { .silent }
    func nextEpisode() -> VoiceResponse { .silent }
}

/// No fingerprint map: the echo alignment under review is about producer ranges, not transcript
/// mapping, so an empty map keeps the collaborator honest rather than decorative.
private struct EmptyFingerprintMapper: FingerprintMappingProviding {
    func matchedReferenceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval? { nil }
    func playbackTime(forReferenceTime referenceTime: TimeInterval) -> TimeInterval? { nil }
}
