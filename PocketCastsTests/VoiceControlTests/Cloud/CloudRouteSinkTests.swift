import PocketCastsUtils
/// The origin these cases dispatch under. The conversation bound refuses a turn whose origin
/// is not live, so a sink built for these cases must be given one — otherwise every turn would
/// be refused before it dials and the case would exercise the bound rather than the sink.
private let cloudTestOrigin = 1

private func testConversationManager() -> CloudConversationManager {
    let manager = CloudConversationManager()
    manager.registerLiveOrigin(cloudTestOrigin)
    return manager
}

import XCTest
import AVFoundation
import PocketCastsUtils
@testable import podcasts

final class CloudRouteSinkTests: SocketCapturingTestCase {
    private var playback: RecordingPlaybackSink!
    private var mapper: RecordingFingerprintMapper!
    private var contextState: CloudPlaybackContextState!
    private var analytics: RecordingAnalytics!
    private var voiceAnalytics: VoiceAnalytics!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        mapper = RecordingFingerprintMapper()
        contextState = CloudPlaybackContextState()
        analytics = RecordingAnalytics()
        voiceAnalytics = VoiceAnalytics(analytics: analytics)
        suiteName = "cloud_route_sink_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testMixedStreamDispatchesSeekSpeaksTokensOnDone() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":1130000}}

            event: token
            data: {"text":"She"}

            event: token
            data: {"text":" is arguing."}

            event: done
            data: {"usage":{"input_tokens":10,"output_tokens":4}}

            """
        mapper.playbackSecondsForReference = [1130.0: 1200.0]
        playback.setPositionMs(500_000)

        let response = await makeSink().routeToCloud(
            request: "What did she mean?",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-1")

        XCTAssertEqual(response.response, .silent, "cloud answers are played as audio, not spoken")
        XCTAssertTrue(playback.calls.contains(.pause))
        XCTAssertTrue(playback.calls.contains(.resume), "done must restore turn-owned auto-pause")
        XCTAssertEqual(playback.calls.filter { $0 == .seekTo(1200) }.count, 1)
        XCTAssertEqual(analytics.events.last?.0, "cloud_assistant_turn")
        XCTAssertEqual(analytics.events.last?.1["outcome"] as? String, "done")
        let snap = contextState.snapshot()
        XCTAssertEqual(snap.recentReferencePositions.last, 1_130_000)
        XCTAssertEqual(snap.previousReferencePositionMs, 500_000)
    }

    /// Every cloud request emits exactly ONE client-side latency line, and a turn that produced no
    /// audio says so rather than reporting zero.
    ///
    /// Asserted on the line the sink writes to the app log — the surface a person reads back on a
    /// device — rather than through an accessor added for the test. A record emitted per frame
    /// would multiply the turn; one emitted only on success would hide exactly the failing turns
    /// the latency work is chasing.
    @MainActor
    func testEveryCloudRequestEmitsOneLatencyRecord() async throws {
        // Unique per RUN: the app's log persists across runs, so a fixed id would count the
        // previous run's lines and measure the harness rather than this turn.
        let run = UUID().uuidString.prefix(8)
        let doneId = "u-\(run)-done"
        let errorId = "u-\(run)-error"
        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":10,"output_tokens":4}}

            """
        let sink = makeSink()
        _ = await sink.routeToCloud(
            request: "hi", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: doneId)

        self.pendingFixture =
            """
            event: error
            data: {"code":"provider_error","message":"upstream failed"}

            """
        _ = await sink.routeToCloud(
            request: "again", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: errorId)

        let log = await FileLog.shared.logFileAsString()
        // The log is shared by every test in the run, so the count is scoped to THIS control's own
        // request ids: counting globally would measure the suite, not the turn.
        let mine = log.split(separator: "\n")
            .filter { $0.contains("cloudTurnLatency") && ($0.contains(doneId) || $0.contains(errorId)) }
            .map(String.init)
        XCTAssertEqual(mine.count, 2,
                       "one latency line per request; a line per frame would multiply the turn, "
                           + "and a missing one would hide a turn that never played: \(mine)")
        let done = try XCTUnwrap(mine.first { $0.contains(doneId) }, log)
        XCTAssertTrue(done.contains("outcome=done"), done)
        // NOT `contains("end_of_speech_to_first_audible=")`: that substring is satisfied by
        // `=none`, so it passed for a turn that measured nothing, which is every turn here.
        // This fixture carries no audio, so the honest expectation is stated as such.
        XCTAssertTrue(
            done.contains("first_audible=absent"),
            "a turn with no audio says so rather than reporting a duration: \(done)")
        XCTAssertTrue(done.contains("end_of_speech_to_first_audible=none"), done)
        let failed = try XCTUnwrap(mine.first { $0.contains(errorId) }, log)
        XCTAssertTrue(failed.contains("outcome=error"), failed)
        XCTAssertTrue(failed.contains("first_audible=absent"), failed)
    }

    /// A turn with an AUDIO FIXTURE reports its own line, consistently, whether or not the
    /// simulator's engine rendered.
    ///
    /// `first_audible=absent` is NOT assertable here. The engine does start on the simulator and the
    /// mark lands moments after `done`, and the record waits for it, so this turn can legitimately
    /// report a duration. Whether the simulator's engine renders is the host's business, so the
    /// assertion is the part that cannot depend on it: the line belongs to THIS request, and it is
    /// internally consistent - absence is stated as absence, and a measured turn has a measured
    /// request leg rather than `none`.
    @MainActor
    func testAnAudioFixtureTurnReportsItsOwnLineWithoutClaimingAudio() async throws {
        // Unique per RUN: the app log persists, so a fixed id would read the previous run's line.
        let utteranceId = "u-\(UUID().uuidString.prefix(12))-audible"
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        defer { CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil }
        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let sink = makeSinkWithConsumer(
            RecordingResultConsumer(),
            audioPayloads: (0..<40).map { Data([UInt8($0)]) }
        )
        let context = TurnLatencyContext()
        context.endOfSpeech = 0
        _ = await sink.routeToCloud(
            request: "x", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: utteranceId,
            latency: LatencyHandle(context))

        let line = try await latencyLine(for: utteranceId)
        XCTAssertEqual(
            Self.requestId(of: line), utteranceId,
            "the line must be THIS turn's, not a stale one from an earlier run: \(line)")
        XCTAssertTrue(line.contains("outcome=done"), line)
        let measured = !line.contains("first_audible=absent")
        if measured {
            XCTAssertFalse(
                line.contains("request_to_first_audible=none"),
                "a turn that reports an audible instant must report the request leg to it: \(line)")
        } else {
            XCTAssertTrue(
                line.contains("end_of_speech_to_first_audible=none"),
                "no audible instant means the leg is unmeasured, not zero: \(line)")
        }
    }

    /// A SHORT reply's stream ends before its first buffer reaches the player.
    ///
    /// The whole answer can arrive, and `done` with it, while the node has rendered nothing: the
    /// first-audible mark is taken only once the node renders, so a record written AT `done` reports
    /// `first_audible=absent` for audio that then plays. The record must be HELD while audio is
    /// outstanding and unmarked, then written once, when the mark lands.
    ///
    /// The engine renders offline, so the node renders only when this test renders it: the record is
    /// absent from the log at `done`, and the mark taken once the test renders must be what it
    /// carries - a measured request leg, never absence.
    @MainActor
    func testAShortReplyHoldsItsLatencyRecordUntilPlaybackSettles() async throws {
        let utteranceId = "u-\(UUID().uuidString.prefix(12))-short"
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        let fmt = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let engineBox = OfflineEngineBox()
        CloudAudioPlayer.configureEngineForTesting = { engine in
            try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4_096)
            engineBox.engine = engine
        }
        defer {
            CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
            CloudAudioPlayer.configureEngineForTesting = nil
        }
        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let sink = makeSinkWithConsumer(
            RecordingResultConsumer(),
            // Whole 16-bit samples, enough frames to start the engine.
            audioPayloads: (0..<8).map { _ in Data(repeating: 0x10, count: 4_800) }
        )
        // Production wires the echo reference and its handoff; the player counts the audio it
        // scheduled (what the drain waits on) only through them.
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)
        defer { withExtendedLifetime(handoff) {} }
        let sinkPlayer = try XCTUnwrap(sink.audioPlayerForTesting)
        sinkPlayer.emittedPCMReference = reference
        sinkPlayer.echoReferenceHandoff = handoff
        let context = TurnLatencyContext()
        context.endOfSpeech = 0
        _ = await sink.routeToCloud(
            request: "x", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: utteranceId,
            latency: LatencyHandle(context))

        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        // The precondition the name claims: audio is still outstanding when the turn returns.
        // If it were not, "held" would be indistinguishable from "emitted at done". The offline
        // engine renders nothing until this test does, so a failure here is a broken premise.
        guard player.hasOutstandingOutput else {
            XCTFail("premise: audio is still outstanding when the turn returns")
            return
        }
        let early = await FileLog.shared.logFileAsString().split(separator: "\n")
            .filter { Self.requestId(of: String($0)) == utteranceId }
        XCTAssertTrue(
            early.isEmpty,
            "the record was written at `done` while audio was still outstanding and unmarked: \(early)")

        // Render the held audio: the drain's wait loop takes the mark, and the record is written with it.
        let engineDeadline = Date().addingTimeInterval(3)
        while engineBox.engine == nil && Date() < engineDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let engine = try XCTUnwrap(engineBox.engine, "premise: the player built its offline engine")
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4_096))
        var found: String?
        let renderDeadline = Date().addingTimeInterval(8)
        while found == nil && Date() < renderDeadline {
            _ = try? engine.renderOffline(1_024, to: output)
            try await Task.sleep(nanoseconds: 20_000_000)
            found = await FileLog.shared.logFileAsString().split(separator: "\n")
                .map(String.init).first { Self.requestId(of: $0) == utteranceId }
        }
        let line = try XCTUnwrap(found, "the held record was never written")
        XCTAssertTrue(line.contains("outcome=done"), line)
        XCTAssertFalse(line.contains("first_audible=absent"),
                       "audio rendered after `done` must be what the record reports, not absence: \(line)")
        XCTAssertFalse(line.contains("end_of_speech_to_first_audible=none"),
                       "a measured turn carries its end-of-speech leg: \(line)")
        let all = await FileLog.shared.logFileAsString().split(separator: "\n")
            .filter { Self.requestId(of: String($0)) == utteranceId }
        XCTAssertEqual(all.count, 1, "exactly one record per turn: \(all)")
    }

    /// A terminal that arrives AFTER audio was heard must still report when it was heard.
    ///
    /// The error path cancels the player before it writes its record, and the cancel clears the
    /// player's first-audible mark, so the sink snapshots the mark while audio is still playing.
    /// The transport parks after the audio, the offline node renders it (the mark lands), and only
    /// then does the `error` arrive: a record that reads `absent` here means the snapshot was
    /// not taken before the cancel.
    @MainActor
    func testAnErrorAfterAudibleAudioStillReportsWhenItWasHeard() async throws {
        let utteranceId = "u-\(UUID().uuidString.prefix(12))-errheard"
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        let fmt = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let engineBox = OfflineEngineBox()
        CloudAudioPlayer.configureEngineForTesting = { engine in
            try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4_096)
            engineBox.engine = engine
        }
        defer {
            CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
            CloudAudioPlayer.configureEngineForTesting = nil
        }
        self.pendingFixture =
            """
            event: error
            data: {"code":"provider_error","message":"upstream failed"}

            """
        let park = HoldLatch()
        defer { park.release() } // a failed premise must not leave the turn parked
        pendingDeclaredPark = park
        pendingDeclaredParkAfterFrames = 8
        let sink = makeSinkWithConsumer(
            RecordingResultConsumer(),
            audioPayloads: (0..<8).map { _ in Data(repeating: 0x10, count: 4_800) }
        )
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)
        defer { withExtendedLifetime(handoff) {} }
        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        player.emittedPCMReference = reference
        player.echoReferenceHandoff = handoff
        let context = TurnLatencyContext()
        context.endOfSpeech = 0
        let turn = Task { @MainActor in
            await sink.routeToCloud(
                request: "x", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: nil, utteranceId: utteranceId,
                latency: LatencyHandle(context))
        }

        let engineDeadline = Date().addingTimeInterval(3)
        while engineBox.engine == nil && Date() < engineDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let engine = try XCTUnwrap(engineBox.engine, "premise: the player built its offline engine")
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4_096))
        let renderDeadline = Date().addingTimeInterval(5)
        while player.firstAudibleHostSeconds == nil && Date() < renderDeadline {
            _ = try? engine.renderOffline(1_024, to: output)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(player.firstAudibleHostSeconds, "premise: the audio was heard before the error")
        // Let the sink observe the audible audio before the terminal arrives.
        try await Task.sleep(nanoseconds: 100_000_000)
        park.release()
        // Bounded: a turn that never returns after the error is a defect (it would wedge the next
        // turn), so it fails here by name instead of hanging the plan.
        // Polled, not awaited: awaiting a stuck turn's value is itself uncancellable.
        let returnedFlag = TurnReturnedFlag()
        Task { _ = await turn.value; returnedFlag.set() }
        let returnDeadline = Date().addingTimeInterval(3)
        while !returnedFlag.isSet && Date() < returnDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let returned = returnedFlag.isSet
        if !returned {
            turn.cancel()
            XCTFail("the turn never returned after the error")
        }

        let line = try await latencyLine(for: utteranceId)
        XCTAssertTrue(line.contains("outcome=error"), line)
        XCTAssertFalse(line.contains("first_audible=absent"),
                       "audio was audible before the error, so the record must carry when: \(line)")
        XCTAssertFalse(line.contains("end_of_speech_to_first_audible=none"),
                       "the audible instant must be measured, not merely not absent: \(line)")
    }

    /// A stop for an EARLIER drain says nothing about this turn's audio.
    ///
    /// A held follow-up is the likely case: the interrupted turn's cancel stop can arrive after the
    /// follow-up's `done`. Written by that stop, the follow-up's record would read `absent` for
    /// audio still on its way to the speaker - the defect the hold exists to remove, reached by
    /// another door. The record waits for the stop of ITS drain (or a later one) or for the mark.
    @MainActor
    func testAnEarlierDrainsStopDoesNotWriteAHeldLatencyRecord() async throws {
        let utteranceId = "u-\(UUID().uuidString.prefix(12))-stale"
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        defer { CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil }
        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let sink = makeSinkWithConsumer(
            RecordingResultConsumer(),
            audioPayloads: (0..<40).map { Data([UInt8($0)]) }
        )
        let context = TurnLatencyContext()
        context.endOfSpeech = 0
        _ = await sink.routeToCloud(
            request: "x", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: utteranceId,
            latency: LatencyHandle(context))

        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        try XCTSkipUnless(
            player.hasOutstandingOutput,
            "the stub drained before the turn returned, so no hold can be observed")
        // No suspension between the check above and this call, so this stop cannot be the real one.
        sink.audioPlayerDidStop(drainEpoch: Int.min)
        let afterStaleStop = await FileLog.shared.logFileAsString().split(separator: "\n")
            .filter { Self.requestId(of: String($0)) == utteranceId }
        XCTAssertTrue(
            afterStaleStop.isEmpty,
            "a stop for an earlier drain wrote the held record: \(afterStaleStop)")

        // Its own drain's stop (or the mark) still settles it, exactly once.
        _ = try await latencyLine(for: utteranceId)
        let all = await FileLog.shared.logFileAsString().split(separator: "\n")
            .filter { Self.requestId(of: String($0)) == utteranceId }
        XCTAssertEqual(all.count, 1, "exactly one record per turn: \(all)")
    }

    /// A turn with NO early-connection tag still reports its end of speech.
    ///
    /// The tag exists only when a pause pre-opened a connection, which most turns never do. While
    /// the end of speech was recorded behind the tag check, every one of those turns measured
    /// `end_of_speech_to_* = none` — the measurement silently absent for the majority case.
    @MainActor
    func test_aTurnWithoutAnEarlyConnectionStillReportsItsEndOfSpeech() async throws {
        let utteranceId = "u-\(UUID().uuidString.prefix(8))-notag"
        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let sink = makeSink()
        // The turn's own object, filled the way admission fills it, with no tag in play at all.
        let latency = TurnLatencyContext()
        latency.endOfSpeech = 5_000.0
        latency.endpointDecisionAt = 5_000.2
        _ = await sink.routeToCloud(
            request: "hi", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: utteranceId, latency: LatencyHandle(latency))

        let line = try await latencyLine(for: utteranceId)
        XCTAssertFalse(line.contains("end_of_speech_to_request=none"),
                       "a turn with no pre-opened connection still knows when speech ended: \(line)")
        XCTAssertTrue(line.contains("endpoint_ms=200ms"), line)
    }

    /// A turn handled on the phone leaves nothing behind, because nothing was ever shared.
    ///
    /// The instants live on the turn's own object, so there is no store to clean up: a local turn's
    /// context is simply released, and a LATER turn reusing the same identity cannot see it. The
    /// assertion is the one that would catch a resurrected side table — the newer turn reports its
    /// own instant, not the dropped one's.
    @MainActor
    func test_aLocallyHandledTurnDoesNotShadowTheNextTurnWithTheSameIdentity() async throws {
        let utteranceId = "u-\(UUID().uuidString.prefix(8))-local"
        let sink = makeSink()
        // The locally handled turn: its context exists, is read by nobody, and is released here.
        autoreleasepool {
            let dropped = TurnLatencyContext()
            dropped.endOfSpeech = 9_000.0
            dropped.endpointDecisionAt = 9_000.1
        }

        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let latency = TurnLatencyContext()
        latency.endOfSpeech = 9_500.0
        latency.endpointDecisionAt = 9_500.1
        _ = await sink.routeToCloud(
            request: "hi", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: utteranceId, latency: LatencyHandle(latency))

        let line = try await latencyLine(for: utteranceId)
        XCTAssertTrue(line.contains("endpoint_ms=100ms"),
                      "the newer turn's own instant is what is read: \(line)")
    }

    /// A ROUTED turn that is then handled on the phone leaves no entry behind.
    ///
    /// Distinct from a turn that never reaches routing: a routed local command — the majority —
    /// ends at the router instead, where its instants have no consumer at all. With the context on
    /// the turn, that terminal needs no cleanup call to be correct.
    @MainActor
    func test_aRoutedLocalTurnDropsItsEndOfSpeech() async throws {
        let utteranceId = "u-\(UUID().uuidString.prefix(8))-routedlocal"
        let sink = makeSink()
        // Routed, then classified as a local command: its context is released unread.
        autoreleasepool {
            let routed = TurnLatencyContext()
            routed.endOfSpeech = 11_000.0
            routed.endpointDecisionAt = 11_000.3
        }

        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let latency = TurnLatencyContext()
        latency.endOfSpeech = 12_000.0
        latency.endpointDecisionAt = 12_000.4
        _ = await sink.routeToCloud(
            request: "hi", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: utteranceId, latency: LatencyHandle(latency))

        let line = try await latencyLine(for: utteranceId)
        XCTAssertTrue(line.contains("endpoint_ms=400ms"),
                      "the newer turn's instant must be the one recorded; a survivor would "
                          + "shadow it with the dropped turn's 300ms: \(line)")
    }

    /// A CLOUD turn keeps its instants through the router's terminal.
    ///
    /// The record is built when the cloud round ends, which can be AFTER the router's terminal
    /// fires. While those instants lived in a store the router had to be told which turns were
    /// cloud-bound; with them on the turn's own object, a cloud turn simply still holds them when
    /// the record is built — no mark, no guard, nothing to get wrong.
    @MainActor
    func test_aCloudBoundTurnKeepsItsEndOfSpeechThroughTheRouterTerminal() async throws {
        let utteranceId = "u-\(UUID().uuidString.prefix(8))-cloudkept"
        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let sink = makeSink()
        _ = sink.beginDispatch(utteranceId: utteranceId, origin: nil)
        let latency = TurnLatencyContext()
        latency.endOfSpeech = 13_000.0
        latency.endpointDecisionAt = 13_000.5

        _ = await sink.routeToCloud(
            request: "hi", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: utteranceId, latency: LatencyHandle(latency))

        let line = try await latencyLine(for: utteranceId)
        XCTAssertTrue(line.contains("endpoint_ms=500ms"),
                      "a cloud-bound turn must reach its record with its instants intact; losing "
                          + "them reports no end of speech for the turn: \(line)")
    }

    /// A REFUSED cloud dispatch builds no record at all, and the instants it carried are not
    /// reachable from any later turn.
    ///
    /// This is the case that kept leaking while the instants lived in a sink-owned store: the
    /// dispatch was marked cloud-bound before the refusal, the record was never built, and every
    /// cleanup path declined because of the mark. With the instants on the turn's own object there
    /// is nothing to clear — a refused dispatch simply never reads them, and the object is released
    /// with the turn.
    ///
    /// A refusal requires a NON-LIVE origin with no admitted work holding it, so the test asserts
    /// the refusal actually happened rather than assuming it: a dispatch that succeeds leaves the
    /// instants in use and proves nothing about leaving them behind.
    @MainActor
    func test_aRefusedCloudDispatchLeavesItsInstantsBehind() async throws {
        let utteranceId = "u-\(UUID().uuidString.prefix(8))-refused"
        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let sink = makeSink()
        let staleOrigin = cloudTestOrigin + 41
        let refused = TurnLatencyContext()
        refused.endOfSpeech = 20_000.0
        refused.endpointDecisionAt = 20_000.7

        let outcome = await sink.routeToCloud(
            request: "refused", tier: .free, context: sampleContext(), origin: staleOrigin,
            selection: nil, utteranceId: utteranceId, latency: LatencyHandle(refused))
        XCTAssertEqual(outcome.outcome, .refused,
                       "the case must actually refuse the dispatch, or it proves nothing")

        // No record for the refused turn, either now or later.
        let afterRefusal = await FileLog.shared.logFileAsString()
            .split(separator: "\n")
            .filter { $0.contains("cloudTurnLatency") && $0.contains(utteranceId) }
        XCTAssertTrue(afterRefusal.isEmpty,
                      "a refused dispatch produces no latency record: \(afterRefusal)")

        // A later admitted turn on the same identity reports its OWN instant. Under the old
        // design this is where the refused turn's value resurfaced.
        let accepted = TurnLatencyContext()
        accepted.endOfSpeech = 30_000.0
        accepted.endpointDecisionAt = 30_000.9
        _ = await sink.routeToCloud(
            request: "hi", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: utteranceId, latency: LatencyHandle(accepted))

        let line = try await latencyLine(for: utteranceId)
        XCTAssertTrue(line.contains("endpoint_ms=900ms"),
                      "the refused turn's instants must not survive into the next turn: \(line)")
    }

    /// A turn WITH a timing context and one WITHOUT are the SAME dispatch, as far as identity goes.
    ///
    /// The wrapper only does its job if the field is NON-optional. With an optional field, Swift
    /// compares the optionals by case before `==` is ever consulted, so `.some(handle)` and `.none`
    /// compare unequal and identical dispatches stop being equal — the leak the wrapper was meant
    /// to close.
    func test_aTurnWithATimingContextEqualsTheSameTurnWithout() {
        let withContext = CloudRouteIntent(
            request: "hi", tier: .free, latency: LatencyHandle(TurnLatencyContext()))
        let withoutContext = CloudRouteIntent(request: "hi", tier: .free, latency: LatencyHandle())
        XCTAssertEqual(
            withContext, withoutContext,
            "the timing context takes no part in identity, so carrying one must not make two "
                + "otherwise identical dispatches unequal")
        XCTAssertEqual(withoutContext, withContext, "equality is symmetric here too")

        // Two DIFFERENT contexts are equally irrelevant.
        let otherContext = CloudRouteIntent(
            request: "hi", tier: .free, latency: LatencyHandle(TurnLatencyContext()))
        XCTAssertEqual(withContext, otherContext)

        // And a real difference is still a difference, so the exemption did not swallow equality.
        let differentRequest = CloudRouteIntent(
            request: "bye", tier: .free, latency: LatencyHandle(TurnLatencyContext()))
        XCTAssertNotEqual(withContext, differentRequest)
    }

    /// The same exemption on the routing envelope, which the executor compares.
    func test_anInputWithATimingContextEqualsTheSameInputWithout() {
        let withContext = IntentRoutingInput.english(
            transcript: "hi", utteranceId: "u-eq",
            latency: LatencyHandle(TurnLatencyContext()))
        let withoutContext = IntentRoutingInput.english(transcript: "hi", utteranceId: "u-eq")
        XCTAssertEqual(withContext, withoutContext)
        XCTAssertNotEqual(
            withContext,
            IntentRoutingInput.english(transcript: "different", utteranceId: "u-eq"))
    }

    /// The `request_id=` field of a log line, or nil when the line is not a latency record.
    ///
    /// Parsed rather than substring-matched: `contains("u-ABC")` also matches `u-ABCD`, so a
    /// prefix would let one request stand in for another.
    private static func requestId(of line: String) -> String? {
        guard line.contains("cloudTurnLatency"),
              let range = line.range(of: "request_id=") else { return nil }
        return line[range.upperBound...].split(separator: " ").first.map(String.init)
    }

    /// The `cloudTurnLatency` line for one request id, waited for because the record is emitted by
    /// a closure that may run after `routeToCloud` returns.
    ///
    /// `requestId` must be unique per RUN. The app log persists across runs, so a fixed id finds
    /// the PREVIOUS run's line and the test passes without ever seeing its own turn - which is
    /// exactly how a positive-case control once "passed" against a log where every line read
    /// `first_audible=absent`.
    @MainActor
    private func latencyLine(for utteranceId: String) async throws -> String {
        XCTAssertTrue(utteranceId.hasPrefix("u-"), "callers must pass a per-run unique id")
        XCTAssertTrue(
            utteranceId.count > 12,
            "a fixed or short id can collide with another run's line in the persistent log")
        for _ in 0..<40 {
            let log = await FileLog.shared.logFileAsString()
            // Matched as a WHOLE field, so `u-ABC` cannot be satisfied by `u-ABCD`.
            if let line = log.split(separator: "\n")
                .first(where: { Self.requestId(of: String($0)) == utteranceId }) {
                return String(line)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let log = await FileLog.shared.logFileAsString()
        throw XCTSkip("no cloudTurnLatency line for \(utteranceId)")
    }

    /// A dispatched spoken turn reports a real end of speech, not `none`: the instant travels from
    /// admission ON the turn itself, so the record built at the terminal must read it from there.
    /// Losing it reports `none` — the measurement absent for exactly the turns it exists for.
    @MainActor
    func testADispatchedUtteranceReportsItsEndOfSpeech() async throws {
        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let eosId = "u-\(UUID().uuidString.prefix(8))-eos"
        let sink = makeSink()
        let latency = TurnLatencyContext()
        latency.endOfSpeech = 1_000.0
        latency.endpointDecisionAt = 1_000.5
        _ = await sink.routeToCloud(
            request: "hi", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: eosId, latency: LatencyHandle(latency))

        let line = try await latencyLine(for: eosId)
        XCTAssertTrue(line.contains("endpoint_ms=500ms"),
                      "the hangover between the acoustic end and the endpoint decision is its own stage: \(line)")
        XCTAssertFalse(line.contains("end_of_speech_to_request=none"),
                       "a spoken turn knows when speech ended; `none` here means the instant was lost: \(line)")
    }

    func testDoneResumesTurnOwnedAutoPause() async {
        self.pendingFixture =
            """
            event: token
            data: {"text":"Answer."}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """

        let response = await makeSink().routeToCloud(
            request: "summarize",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-2")

        XCTAssertEqual(response.response, .silent, "cloud answers are played as audio, not spoken")
        XCTAssertEqual(playback.calls.first, .pause)
        XCTAssertEqual(playback.calls.last, .resume)
        XCTAssertEqual(playback.calls.filter { $0 == .pause }.count, 1)
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1)
    }

    /// A turn must not start audio the user had stopped. With the host already
    /// paused the client takes no hold, so there is nothing for the turn's end
    /// to release.
    func testDoesNotPauseOrResumeWhenHostWasAlreadyPaused() async {
        self.pendingFixture =
            """
            event: token
            data: {"text":"Answer."}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        playback.setPlaying(false)

        let response = await makeSink().routeToCloud(
            request: "what was that about",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-3")

        XCTAssertEqual(response.response, .silent)
        XCTAssertFalse(playback.calls.contains(.pause), "the user's own pause is not ours to retake")
        XCTAssertFalse(playback.calls.contains(.resume), "the user asked for it to stop; the turn must not undo that")
    }

    /// The turn's hold must be released when the turn ends without speaking:
    /// a `done` with no audio restores the playback it stopped, so the user is
    /// left exactly as they were.
    func testTurnWithoutAudioRestoresTheHoldItTook() async {
        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """

        _ = await makeSink().routeToCloud(request: "hi", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-4")

        XCTAssertEqual(playback.calls.filter { $0 == .pause }.count, 1, "the turn takes one hold")
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1, "and releases it on done")
        XCTAssertEqual(playback.calls.last, .resume)
    }

    func testPlayQuoteAndStopQuoteRestorePosition() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"play_quote","params":{"reference_position_ms":500000}}

            event: action
            data: {"tool":"playback","action":"stop_quote","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        mapper.playbackSecondsForReference = [500.0: 510.0]
        playback.setPositionMs(900_000)

        let response = await makeSink().routeToCloud(
            request: "play that",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-5")

        XCTAssertEqual(response.response, .silent)
        XCTAssertTrue(playback.calls.contains(.seekTo(510)))
        XCTAssertTrue(playback.calls.contains(.seekTo(900)))
        XCTAssertTrue(playback.calls.contains(.resume))
        // The quote does not release the hold early: the server ducked playback
        // for the "play that" answer, and the turn's end is the release.
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1)
        XCTAssertEqual(playback.calls.last, .resume)
    }

    func testSeekRelativeExecutesAndCapturesPosition() async {
        self.pendingFixture =
            """
            event: action
            data:{"tool":"playback","action":"seek_relative","params":{"delta_seconds":15}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        playback.setPositionMs(120_000)

        let response = await makeSink().routeToCloud(
            request: "forward 15 seconds",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-6")

        XCTAssertEqual(response.response, .silent)
        XCTAssertTrue(playback.calls.contains(.seekRelative(15, .forward)))
        // Previous position must be captured so "go back to where I was" works.
        XCTAssertEqual(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count, 1)
    }

    func testSeekRelativeDirectionOnlyUsesForwardDefault() async {
        self.pendingFixture =
            """
            event: action
            data:{"tool":"playback","action":"seek_relative","params":{"direction":"backward"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        playback.setPositionMs(120_000)

        _ = await makeSink().routeToCloud(
            request: "go back",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-7")

        // No delta manufactured — direction preserved as nil.
        XCTAssertTrue(playback.calls.contains(.seekRelative(nil, .backward)))
    }

    func testSeekRelativeNeitherDeltaNorDirectionUsesForwardDefault() async {
        self.pendingFixture =
            """
            event: action
            data:{"tool":"playback","action":"seek_relative","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        playback.setPositionMs(120_000)

        _ = await makeSink().routeToCloud(
            request: "skip forward",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-8")

        // Neither stated → (nil, FORWARD) so the sink applies its default interval.
        XCTAssertTrue(playback.calls.contains(.seekRelative(nil, .forward)))
    }

    func testUnknownActionIgnored() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"do_a_barrel_roll","params":{}}

            event: action
            data: {"tool":"bookmarks","action":"add","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """

        _ = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-9")
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 0)
    }

    func testErrorClearsBufferRestoresPauseDoesNotRollbackSeek() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":100000}}

            event: token
            data: {"text":"partial"}

            event: error
            data: {"code":"rate_limited","message":"rate limited"}

            """
        mapper.playbackSecondsForReference = [100.0: 110.0]
        playback.setPositionMs(50_000)

        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-10")

        // This case is about the ERROR PATH's buffer/seek rollback. The remote `message` is never
        // spoken (spec 961fab07) and `rate_limited` has no local template, so the user hears the
        // error earcon; the subject here is the buffer/seek/pause outcome below, not the wording.
        XCTAssertEqual(response.response, .earcon(.error))
        XCTAssertTrue(playback.calls.contains(.seekTo(110)))
        XCTAssertTrue(playback.calls.contains(.resume))
        XCTAssertEqual(analytics.events.last?.1["outcome"] as? String, "error")
    }

    /// The ordinary cloud seek form: position_seconds is SINK time and seeks directly, with
    /// no mapping involved. A mapper with no entries must not block it.
    func testOrdinarySeekToUsesSinkTimeDirectlyWithoutMapping() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"position_seconds":95}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // No mapping at all: the ordinary form must not depend on one.
        let sink = makeSink()
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-11")

        XCTAssertTrue(playback.calls.contains(.seekTo(95)))
        let unavailable = await MainActor.run { sink.unavailableReferenceSeek }
        XCTAssertNil(unavailable, "the ordinary form is not a reference seek")
    }

    /// Both forms at once is malformed: the request does not say which target governs.
    func testSeekToWithBothFormsIsRefused() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"position_seconds":95,"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSink()
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-12")

        XCTAssertFalse(playback.calls.contains { if case .seekTo = $0 { return true }; return false })
        let rejection = await MainActor.run { sink.lastSeekRejection }
        XCTAssertEqual(rejection?.outcome, .refused)
        XCTAssertEqual(rejection?.reason, OperationReason.malformedSeekTarget)
    }

    /// Neither form is equally malformed: there is no default target to fall back to.
    func testSeekToWithNeitherFormIsRefused() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSink()
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-13")

        XCTAssertFalse(playback.calls.contains { if case .seekTo = $0 { return true }; return false })
        let rejection = await MainActor.run { sink.lastSeekRejection }
        XCTAssertEqual(rejection?.reason, OperationReason.malformedSeekTarget)
    }

    /// A fractional position is not an integer position: it parses as neither form and is
    /// refused rather than truncated toward a value nobody asked for.
    func testSeekToWithFractionalPositionIsRefused() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"position_seconds":95.5}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSink()
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-14")

        XCTAssertFalse(playback.calls.contains { if case .seekTo = $0 { return true }; return false })
        let rejection = await MainActor.run { sink.lastSeekRejection }
        XCTAssertEqual(rejection?.reason, OperationReason.malformedSeekTarget)
    }

    /// An unmapped reference target is NOT converted by assumption. Reference time is not
    /// playback time: falling back to the raw value seeks somewhere the server never asked for
    /// on a mapped episode, and nothing downstream can tell that apart from a correct seek. The
    /// operation is refused instead, and no position changes.
    func testUnmappedReferenceSeekIsRefusedAndDoesNotMove() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSink()
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-15")

        XCTAssertFalse(
            playback.calls.contains { if case .seekTo = $0 { return true }; return false },
            "an unmapped reference time must not become a playback position"
        )
        let unavailable = await MainActor.run { sink.unavailableReferenceSeek }
        XCTAssertEqual(unavailable?.outcome, .refused)
        XCTAssertEqual(unavailable?.reason, OperationReason.referenceMappingUnavailable)
    }

    /// The same gap through `play_quote`, which shares the conversion path.
    func testUnmappedReferencePlayQuoteIsRefusedAndDoesNotMove() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"play_quote","params":{"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSink()
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-16")

        XCTAssertFalse(playback.calls.contains { if case .seekTo = $0 { return true }; return false })
        let unavailable = await MainActor.run { sink.unavailableReferenceSeek }
        XCTAssertEqual(unavailable?.reason, OperationReason.referenceMappingUnavailable)
    }

    // MARK: Seek-refusal surfacing (PR #49 review 4305981598)

    /// A recording consumer injected as the sink's result consumer. The wire contract
    /// (`app_operation_result`, rev da327e624) names this the production surface: a refusal the
    /// server can reason about must reach a consumer, not die in a stored field only tests read.
    private final class RecordingResultConsumer: CloudOperationResultConsuming {
        var consumed: [(result: OperationResult, context: String)] = []
        func consume(_ result: OperationResult, context: String) {
            consumed.append((result, context))
        }
    }

    /// Optional cancellation-insensitive park installed on the stub task BEFORE the client is
    /// constructed, so the producer's FIRST receive parks — no race with stream end.
    private var pendingProducerHold: HoldLatch?
    /// How many wires the sink actually dialled — the OWNERSHIP observable for request controls.
    private var clientCreationCount = 0
    /// Optional one-shot PRODUCTION-boundary park: armed onto the stub at construction; the sink
    /// installs it synchronously at the claim→effect seam via `effectEntered` (see
    /// `StubWebSocketTask.armReceiveHoldOnEntered`).
    private var pendingArmedReceiveHold: HoldLatch?
    /// Transport park installed at client creation (survives the whole turn) plus how many
    /// frames must be served before it engages.
    private var pendingDeclaredPark: HoldLatch?
    private var pendingDeclaredParkAfterFrames: Int?

    /// REQUEST OWNERSHIP (owner delta 3484cbc/5eca874, reviewer 724db1e8): while a dispatch for
    /// an utterance is genuinely HELD in flight, a duplicate invocation for the SAME utterance
    /// joins it — no second wire request is sent — and both callers observe the identical
    /// result once the held dispatch settles: the held-dispatch control. An INDEPENDENT
    /// utterance dispatches its own request concurrently.
    @MainActor
    func testDuplicateDispatchWhileOneIsHeldJoinsItAndIndependentUtterancesDispatchSeparately() async throws {
        let hold = HoldLatch()
        pendingProducerHold = hold
        let sink = makeSinkWithConsumer(RecordingResultConsumer())
        let clientBefore = clientCreationCount

        let shared = "utterance-shared"
        let duplicate = Task { await sink.routeToCloud(
            request: "same", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: shared) }
        // Wait until the owner is actually inside the held producer, then invoke the duplicate.
        try await Task.sleep(nanoseconds: 150_000_000)
        let joiner = Task { await sink.routeToCloud(
            request: "same", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: shared) }
        // An independent utterance must NOT be blocked by the held one.
        let independent = Task { await sink.routeToCloud(
            request: "other", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: "utterance-independent") }
        try await Task.sleep(nanoseconds: 150_000_000)

        hold.release()
        let first = await duplicate.value
        let joined = await joiner.value
        _ = await independent.value

        // The held dispatch is the OWNER: exactly one wire request was minted, and the joining
        // duplicate returned THAT dispatch's result rather than starting its own.
        XCTAssertEqual(
            joined, first,
            "a duplicate dispatch held in flight must join the SAME wire request and observe its result"
        )
        // Exactly TWO wires were dialled for the three invocations: one for the shared utterance
        // (joined by its duplicate) and one for the independent utterance.
        XCTAssertEqual(
            clientCreationCount - clientBefore, 2,
            "one wire per OWNED utterance: the shared duplicate joins, the independent dispatches"
        )
    }

    /// RETENTION BOUNDARY (reviewer 39beabc7): the sink's settled results are retained for the
    /// whole WINDOW — no cap. More than 16 settled utterances, then a RETAINED id is delivered
    /// again: it must be served from the retained result with NO new client, NO new admission
    /// and NO predecessor cancellation. An evicting cache would re-enter the owner path here.
    @MainActor
    func testRetainedSettledDispatchIsReplayedWithoutANewClientOrAdmission() async throws {
        let sink = makeSinkWithConsumer(RecordingResultConsumer())
        let clientBefore = clientCreationCount

        // 20 independent utterances settle — deliberately more than any 16-cap.
        for index in 0..<20 {
            _ = await sink.routeToCloud(
                request: "turn \(index)", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: nil, utteranceId: "utterance-\(index)"
            )
        }
        let clientAfterSettled = clientCreationCount
        XCTAssertEqual(clientAfterSettled - clientBefore, 20, "premise: 20 owns dialled 20 wires")

        // Re-deliver the FIRST (oldest) retained id: it must be a settled replay, not a new owner.
        let replayed = await sink.routeToCloud(
            request: "turn 0", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: "utterance-0"
        )
        XCTAssertEqual(
            clientCreationCount, clientAfterSettled,
            "a retained settled id is replayed with NO new client (no eviction-triggered re-dispatch)"
        )
        XCTAssertNotNil(replayed.response, "the retained result is returned")
    }

    /// HELD OWNER + JOINER ACROSS A WINDOW CLOSE (reviewer a2723c92): an owner is held in
    /// flight with a duplicate JOINER parked on it, then the window RETIRES (close) and a new
    /// window opens, all before the owner completes. The retirement must NOT discard the held
    /// joiner: releasing the old owner settles the JOINER with that owner's result, and the late
    /// owner's completion must NOT publish into the new window's map (the next dispatch for the
    /// SAME id in the new window is a fresh OWN, not a replay of the stale result).
    @MainActor
    func testHeldJoinerIsSettledByItsOwnerEvenAfterTheWindowRetires() async throws {
        let hold = HoldLatch()
        pendingProducerHold = hold
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)

        let shared = "utterance-held"
        let owner = Task { await sink.routeToCloud(
            request: "owner", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: shared) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let joiner = Task { await sink.routeToCloud(
            request: "duplicate", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: shared) }
        try await Task.sleep(nanoseconds: 150_000_000)

        // The window closes (old generation), then a NEW one opens — all while the owner is held.
        sink.retireRetainedDispatchesIfWindowChanged(to: nil)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin + 1)

        hold.release()
        let ownerResult = await owner.value
        let joinerResult = await joiner.value
        XCTAssertEqual(
            joinerResult, ownerResult,
            "the held joiner is settled by ITS owner even though the window retired mid-flight"
        )
        // The late owner must NOT have published into the NEW window: the SAME utterance id in
        // the new window is a FRESH dispatch (a new owner), not a replay of the stale result —
        // it must NOT return the stale owner's result. The new window is a live origin again.
        manager.registerLiveOrigin(cloudTestOrigin)
        let clientsBefore = clientCreationCount
        _ = await sink.routeToCloud(
            request: "new window turn", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: shared
        )
        XCTAssertGreaterThan(
            clientCreationCount, clientsBefore,
            "the fresh dispatch DIALED (a new client) rather than replaying the stale result — "
                + "a retained stale result would return before any client is minted"
        )
    }

    /// THE EXACT BOUNDARY (reviewer b2c09394). Owner A obtains its ownership token, then is held
    /// BEFORE its dispatch entry. Duplicate B arrives while A is held, and the WINDOW CHANGES
    /// (a real production transition: the live origin moves and the sink retires) before A is
    /// released. Requirements asserted:
    ///   - exactly ONE owner's immutable request reaches the wire (B never starts A's turn);
    ///   - B is refused/joined, never admitted as a second owner;
    ///   - the stale A does not admit a turn after the window changed; and
    ///   - every waiter is settled (nothing is abandoned).
    @MainActor
    func testOwnerHeldBetweenClaimAndDispatchIsNotPreemptedByADuplicateAcrossAWindowChange() async throws {
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin)

        let shared = "utterance-race"
        // A obtains its token and is held BEFORE dispatch entry.
        let aOwnership = sink.beginDispatch(utteranceId: shared, origin: cloudTestOrigin)
        XCTAssertTrue(aOwnership.ownsDispatch, "A's admission owns the dispatch")

        // B arrives while A holds the token but has not entered dispatch: it must NOT own.
        let bOwnership = sink.beginDispatch(utteranceId: shared, origin: cloudTestOrigin)
        XCTAssertFalse(bOwnership.ownsDispatch, "a duplicate never obtains ownership of A's turn")
        if case .join = bOwnership {} else { XCTFail("B must JOIN the held owner, got \(bOwnership)") }

        // The window CHANGES before A is released: the live origin moves and the sink retires.
        manager.registerLiveOrigin(cloudTestOrigin + 1)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin + 1)

        // A NEW-window caller for the SAME utterance id dispatches fresh and reaches the wire,
        // creating a NEW record under the same id while A's stale token is still outstanding.
        let clientsBefore = clientCreationCount
        _ = await sink.routeToCloud(
            request: "new window", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin + 1, selection: nil, utteranceId: shared
        )
        XCTAssertGreaterThan(clientCreationCount, clientsBefore, "the new window dispatches freshly")
        let freshInstance = sink.recordInstanceForTesting(utteranceId: shared)
        XCTAssertNotNil(freshInstance, "the new window owns its own record")

        // A NOW re-enters with its STALE token, while a DIFFERENT record (the new window's) owns
        // this utterance id. A must NOT run its request: the INSTANCE fence is what separates the
        // two owners. Observable at the sink boundary — the stale owner never mints a wire client.
        let wiresBeforeStale = sink.wireDispatchCountForTesting
        _ = await sink.routeToCloud(
            request: "owner request", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: shared, ownership: aOwnership
        )
        XCTAssertEqual(
            sink.wireDispatchCountForTesting, wiresBeforeStale,
            "the stale owner did not start a wire turn against the new window's record"
        )
        // The NEW window's record is untouched by the stale owner: a duplicate arriving now must
        // observe the NEW window's OWN result, not the stale owner's refusal. (Without the
        // instance fence the stale token would be accepted against THIS record and publish its
        // refusal into it — binding the wrong caller to the wrong owner.)
        XCTAssertEqual(
            sink.recordInstanceForTesting(utteranceId: shared), freshInstance,
            "the stale owner did not take over the new window's record"
        )
        let duplicate = await sink.routeToCloud(
            request: "duplicate in new window", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin + 1, selection: nil, utteranceId: shared
        )
        XCTAssertNotEqual(
            duplicate.outcome, .refused,
            "a duplicate in the new window observes the NEW window's outcome, not the stale owner's refusal"
        )
    }

    /// JOINER BOUND TO ITS OWN ADMISSION ACROSS A REAL CLOSE/REOPEN (reviewer 8501bd91). A joiner
    /// obtains `.join(token)` for owner A, PAUSES before dispatch, the window retires and the
    /// successor reuses the SAME utterance id, then the joiner resumes. It must resolve against
    /// COHERENT ADMISSION with an EXPLICIT INTERLEAVING BARRIER (review 5fa6e007): the admission
    /// is paused INSIDE the coherent block, before its liveness read; AT THAT MOMENT — mid-decision
    /// — the window moves and the origin retires. The resumed decision must observe the retirement
    /// and REFUSE. A pre-block snapshot implementation fails this control: its cached liveness
    /// would still admit. The discriminator is the admission outcome, not a timeout, and the whole
    /// retirement happens synchronously inside the barrier (no cross-queue hop, no deadlock).
    @MainActor
    func testAnAdmissionPausedMidDecisionObservesAMidDecisionRetirementAndRefuses() async throws {
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
        manager.registerLiveOrigin(cloudTestOrigin)

        var retiredMidDecision = false
        sink.admissionInterleavingBarrierForTesting = { [weak manager] in
            guard let manager, !retiredMidDecision else { return }
            retiredMidDecision = true
            // Mid-decision window move: the origin the parked admission is about to test is
            // retired right here, between block entry and the decision's own read.
            manager.registerLiveOrigin(cloudTestOrigin + 1)
            sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin + 1)
        }

        let admission = Task.detached { @MainActor in
            sink.beginDispatch(utteranceId: "utterance-barrier-race", origin: cloudTestOrigin)
        }
        let disposition = await admission.value
        sink.admissionInterleavingBarrierForTesting = nil
        XCTAssertTrue(retiredMidDecision, "the barrier must have executed mid-decision")
        XCTAssertTrue(disposition.isRefused,
                      "an admission whose origin retired mid-decision must refuse — a pre-block snapshot would admit")
    }



    /// COHERENT ADMISSION (review 086c0172): a retirement that lands between a pre-lock snapshot
    /// and publication must not admit the stale origin. `beginDispatch` now decides and publishes
    /// in ONE main-queue block, so a retirement preceding the block is OBSERVED by the decision:
    /// an origin retired before admission runs is refused even though an earlier read of the live
    /// origin (from any thread) might have seen it live.
    @MainActor
    func testAnOriginRetiredBeforeAdmissionRunsIsRefusedByTheCoherentDecision() async throws {
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
        let retiredOrigin = cloudTestOrigin
        manager.registerLiveOrigin(cloudTestOrigin + 1)

        // The window has MOVED: the old origin is no longer live and this turn holds no admitted
        // work under it. beginDispatch must refuse — the coherent main-queue decision sees the
        // retirement because it reads state INSIDE the decision block, never from a stale
        // pre-lock snapshot.
        let disposition = sink.beginDispatch(utteranceId: "utterance-retired-before-admission", origin: retiredOrigin)
        XCTAssertTrue(disposition.isRefused, "an origin retired before the admission block runs is refused, got \(disposition)")
    }

    /// ADMISSION ENTERED FROM A DETACHED TASK (review 086c0172/47328768/7443c3ea). The sink class
    /// is `@MainActor`-annotated, so its `routeToCloud` witness is MAIN-ISOLATED: a detached caller
    /// suspends and the body runs on main. There is no off-main admission branch to exercise, and
    /// this control does not claim one. What it verifies is what a remote caller sees: entering from
    /// a detached task still owns a fresh dispatch that completes against the stub consumer and
    /// publishes a record, and a retired-origin admission made the same way is refused. Review
    /// 7443c3ea: the second step calls `beginDispatch` directly (main-isolated) — this is the
    /// coherent-decision control, labelled as such.
    @MainActor
    func testADetachedCallerOwnsAFreshDispatchAndARetiredOriginAdmissionIsRefused() async throws {
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
        manager.registerLiveOrigin(cloudTestOrigin)

        // 1. A genuinely nonisolated task enters through the NONISOLATED witness (the concrete
        //    type's witness — not the @MainActor-concrete convenience) with a fresh utterance; the
        //    dispatch must complete (the stub consumer settles it) and leave an owned record.
        self.pendingFixture =
            """
            event: done
            data: {}

            """
        let context = sampleContext()
        let completed = await Task.detached { () -> Bool in
            let result = await sink.routeToCloud(
                request: "witness", tier: .free, context: context,
                origin: cloudTestOrigin, selection: nil, utteranceId: "utterance-witness"
            )
            return result.outcome == .completed
        }.value
        XCTAssertTrue(completed, "the witness-owned dispatch completes against the stub consumer")
        let witnessInstance = sink.recordInstanceForTesting(utteranceId: "utterance-witness")
        XCTAssertNotNil(witnessInstance, "the witness admission published its record")

        // 2. The window moves; an admission against the RETIRED origin is refused by the coherent
        //    decision (called on main, where that decision lives).
        manager.registerLiveOrigin(cloudTestOrigin + 1)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin + 1)
        let refused: CloudDispatchOwnership = await Task.detached { @MainActor in
            sink.beginDispatch(utteranceId: "utterance-witness-2", origin: cloudTestOrigin)
        }.value
        XCTAssertTrue(refused.isRefused, "a witness admission against a retired origin is refused, got \(refused)")
    }

    /// ITS OWN admitted record, never the successor's — the token carries the instance precisely
    /// so a reused id cannot be mistaken for the same owner.
    @MainActor
    func testAHeldJoinerResolvedAgainstItsOwnAdmissionNotASuccessorThatReusedTheId() async throws {
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin)

        let shared = "utterance-joiner"
        let aOwnership = sink.beginDispatch(utteranceId: shared, origin: cloudTestOrigin)
        XCTAssertTrue(aOwnership.ownsDispatch, "A owns the first window's dispatch")

        // The joiner admits against A and (in this control) holds its token before dispatch.
        let joinAdmission = sink.beginDispatch(utteranceId: shared, origin: cloudTestOrigin)
        guard case let .join(joinToken) = joinAdmission else {
            XCTFail("the duplicate must JOIN the held owner, got \(joinAdmission)")
            return
        }

        // The window CLOSES and REOPENS; a successor for the SAME id gets its OWN record.
        manager.registerLiveOrigin(cloudTestOrigin + 1)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin + 1)
        _ = await sink.routeToCloud(
            request: "successor", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin + 1, selection: nil, utteranceId: shared
        )
        let successorInstance = sink.recordInstanceForTesting(utteranceId: shared)
        XCTAssertNotEqual(
            successorInstance, joinToken.instance,
            "premise: the successor owns a DIFFERENT record than the joiner was admitted against"
        )

        // A completes its (now stale) turn. Its OWN record settles with a DISTINCT marker, so the
        // joiner's result cannot be mistaken for the successor's (or for a generic refusal).
        let ownerSettlement = await sink.routeToCloud(
            request: "owner request", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: shared, ownership: aOwnership
        )
        // The owner's settlement is recorded ON ITS OWN record instance — not on the successor's.
        XCTAssertEqual(
            sink.tokenRecordInstanceForTesting(token: aOwnershipToken(aOwnership)), joinToken.instance,
            "premise: the owner and the joiner are bound to the SAME record"
        )
        XCTAssertEqual(
            sink.terminalResultForTesting(token: joinToken)?.outcome, ownerSettlement.outcome,
            "the ORIGINAL record carries the owner's settlement, not a successor's result"
        )
        XCTAssertEqual(
            sink.recordInstanceForTesting(utteranceId: shared), successorInstance,
            "the successor's record is untouched by the stale owner's settlement"
        )

        // The joiner resolves through the PRODUCTION route entry with its OLD admission, and must
        // observe its own owner's settlement.
        let joined = await sink.routeToCloud(
            request: "joiner resumes", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: shared, ownership: joinAdmission
        )
        XCTAssertEqual(
            joined.outcome, ownerSettlement.outcome,
            "the held joiner sees ITS OWN owner's settlement, never the successor's result"
        )
    }

    /// NO IMMORTAL SECOND MAP (reviewer be89233d) AND NO PRETENDED REFCOUNT (reviewer f3492082).
    /// (a) A completed utterance is DETACHED from the live map on a window change — not retained
    /// forever. (b) LIFETIME IS ARC: once the retiring detaches the map entry and EVERY reference
    /// to the record is gone, the record is DEALLOCATED — proved with a weak handle, not inferred
    /// from a counter. The `admitAndResolve` helper guarantees its token locals are dead before the
    /// assertion (Swift may keep frame locals alive to scope end, so the tokens live in a callee).
    @MainActor
    func testCompletedRecordIsReleasedOnceItsAdmittedCallersResolve() async throws {
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin)

        let shared = "utterance-release"
        // The helper admits an owner AND a joiner, drives both through the production route entry,
        // takes a weak handle, then RETURNS — so no token local of ours holds the record.
        let weakRecord = try await admitResolveAndAbandon(shared: shared, sink: sink, manager: manager)
        XCTAssertNotNil(weakRecord(), "premise: the record is still reachable from the live map")

        // The window change DETACHES the live map entry (the record is not retained forever), and
        // with no reference left it is DEALLOCATED.
        sink.retireRetainedDispatchesIfWindowChanged(to: nil)
        XCTAssertNil(
            sink.recordInstanceForTesting(utteranceId: shared),
            "a completed utterance is detached on the window change, not retained forever"
        )
        XCTAssertNil(
            weakRecord(),
            "the record is deallocated once the map entry and every caller's reference are gone"
        )
    }

    /// Admits an owner and a joiner for `shared`, resolves BOTH through the production route entry,
    /// and returns a weak handle to the record. Its token locals die when it returns.
    @MainActor
    private func admitResolveAndAbandon(
        shared: String, sink: CloudRouteSink, manager: CloudConversationManager
    ) async throws -> () -> CloudRouteSink.UtteranceRecord? {
        let owner = sink.beginDispatch(utteranceId: shared, origin: cloudTestOrigin)
        guard case let .owner(ownerToken) = owner else {
            XCTFail("admission must OWN the first dispatch; got \(owner)")
            return { nil }
        }
        let join = sink.beginDispatch(utteranceId: shared, origin: cloudTestOrigin)
        guard case let .join(joinToken) = join else {
            XCTFail("the duplicate must JOIN a held owner; got \(join)")
            return { nil }
        }
        let weakRecord = sink.weakRecordForTesting(token: ownerToken)

        _ = await sink.routeToCloud(
            request: "owner", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: shared, ownership: owner
        )
        _ = await sink.routeToCloud(
            request: "joiner", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: shared,
            ownership: .join(joinToken)
        )
        XCTAssertNotNil(weakRecord(), "still held while the admitted tokens are alive")
        return weakRecord
    }

    private func aOwnershipToken(_ ownership: CloudDispatchOwnership) -> CloudDispatchOwnership.DispatchToken {
        if case let .owner(token) = ownership { return token }
        fatalError("expected an owner disposition")
    }

    private func makeSinkWithConsumer(_ consumer: RecordingResultConsumer, conversationManager: CloudConversationManager? = nil, operationJournal: OperationJournal? = nil, audioPayloads: [Data] = [], episodeAvailable: (() -> Bool)? = nil, playbackManager: PlaybackManager? = nil) -> CloudRouteSink {
        let cloudConfig = CloudConfig(defaults: defaults)
        let producerHold = pendingProducerHold
        pendingProducerHold = nil
        let armedHold = pendingArmedReceiveHold
        pendingArmedReceiveHold = nil
        let declaredPark = pendingDeclaredPark
        pendingDeclaredPark = nil
        let parkAfterFrames = pendingDeclaredParkAfterFrames
        pendingDeclaredParkAfterFrames = nil
        return CloudRouteSink(
            clientFactory: {
                let fixture = Self.injectOperationIdentity(self.pendingFixture ?? "")
                self.pendingFixture = nil
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl, fixture: fixture, audioPayloads: audioPayloads,
                    prepareTask: { task in
                        producerHold.map(task.holdUntilReleased)
                        if let armedHold { task.armReceiveHoldOnEntered = armedHold }
                        // Installed at CREATION so the park exists before the first frame is
                        // served, then engages only after the scripted frames ahead of it.
                        task.armedReceivePark = declaredPark
                        task.declaredParkAfterFrames = parkAfterFrames
                    }
                )
                // MEASURED production parking point: the producer parks at the frame seam, not at
                // a later receive (the stub only receives twice for this fixture). After the
                // action frame (frame 2) the producer parks here, so the transport is genuinely
                // held when cancellation lands.
                // Production retirement seam: when the stub socket is cancelled, wake the
                // parked receive from the SAME cancellation — no polling, no race window.
                built.task.retiredParkNotifier = { declaredPark?.notifyRetired() }
                // MEASURED production parking point: the producer parks at the frame seam, not
                // at a later receive (the stub only receives twice for this fixture). After the
                // action frame (frame 2) the producer parks here, so the transport is genuinely
                // held when cancellation lands.
                built.client.onFrameReceived = { [weak task = built.task] in
                    guard let task, task.framesServedForPark >= (parkAfterFrames ?? 0) else { return }
                    task.declaredParkDidPark = true
                    Task { await declaredPark?.wait(untilRetired: { task.isCancelledSocket }) }
                }
                self.capturedTask = built.task
                self.clientCreationCount += 1
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackManager: playbackManager,
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            episodeAvailable: episodeAvailable,
            cloudPlaybackContextState: CloudPlaybackContextState(),
            analytics: VoiceAnalytics(analytics: analytics),
            operationResultConsumer: consumer,
            operationJournal: operationJournal,
            conversationManager: conversationManager ?? testConversationManager()
        )
    }

    /// An unmapped reference seek must reach the injected consumer with the refused outcome and
    /// the mapping-unavailable reason — the production read of the outcome that previously only
    /// landed in a test-only stored field.
    func testUnmappedReferenceSeekReachesTheOperationResultConsumer() async {
        self.pendingFixture = """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let consumer = RecordingResultConsumer()
        let sink = makeSinkWithConsumer(consumer)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-17")

        let refusals = consumer.consumed.filter { $0.result.outcome == .refused }
        XCTAssertEqual(refusals.count, 1, "exactly one refused app_operation_result for one unmapped seek; got \(consumer.consumed)")
        XCTAssertEqual(refusals.first?.result.reason, OperationReason.referenceMappingUnavailable)
    }

    /// A malformed seek (both target forms) reaches the consumer too.
    func testMalformedSeekReachesTheOperationResultConsumer() async {
        self.pendingFixture = """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"position_seconds":95,"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let consumer = RecordingResultConsumer()
        let sink = makeSinkWithConsumer(consumer)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-18")

        let refusals = consumer.consumed.filter { $0.result.outcome == .refused }
        XCTAssertEqual(refusals.first?.result.reason, OperationReason.malformedSeekTarget)
    }

    /// THROUGH-TRANSPORT control: an IDENTIFIED unmapped reference seek must send the
    /// `app_operation_result` frame on the turn's own captured socket, correlated to the
    /// server-issued operation id, with the refused outcome and mapping-unavailable reason.
    func testIdentifiedUnmappedSeekSendsRefusedResultFrameThroughTheSocket() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-seek-1","capability_version":"v1","tool":"playback","action":"seek_to","params":{"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSink()
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-19")

        XCTAssertFalse(
            playback.calls.contains { if case .seekTo = $0 { return true }; return false },
            "an unmapped reference time must not become a playback position"
        )
        let deadline = Date().addingTimeInterval(5)
        var resultFrame: [String: Any]?
        while Date() < deadline && resultFrame == nil {
            resultFrame = await MainActor.run {
                capturedTask?.sentTextFrames.compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }.first { ($0["type"] as? String) == "app_operation_result" }
            }
            if resultFrame == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let frame = try XCTUnwrap(resultFrame, "the refused outcome rode the turn socket")
        XCTAssertEqual(frame["operation_id"] as? String, "op-seek-1")
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.referenceMappingUnavailable)
    }

    /// THROUGH-TRANSPORT control: an identified MALFORMED seek (both target forms) sends the
    /// refused frame with the malformed-target reason.
    func testIdentifiedMalformedSeekSendsRefusedResultFrameThroughTheSocket() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-seek-2","capability_version":"v1","tool":"playback","action":"seek_to","params":{"position_seconds":95,"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let consumer = RecordingResultConsumer()
        let sink = makeSinkWithConsumer(consumer)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-20")
        XCTAssertEqual(consumer.consumed.first?.result.reason, OperationReason.malformedSeekTarget,
                       "diagnostic: the refusal reached the consumer surface")

        let deadline = Date().addingTimeInterval(5)
        var resultFrame: [String: Any]?
        while Date() < deadline && resultFrame == nil {
            resultFrame = await MainActor.run {
                capturedTask?.sentTextFrames.compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }.first { ($0["type"] as? String) == "app_operation_result" }
            }
            if resultFrame == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let frame = try XCTUnwrap(resultFrame, "the refused outcome rode the turn socket")
        XCTAssertEqual(frame["operation_id"] as? String, "op-seek-2")
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.malformedSeekTarget)
    }

    /// LEGACY refusal case (explicit, per the runtime gate): an identity-less cloud mutation
    /// does NOT execute and sends NO result frame (there is no server identity to tie it to);
    /// the refusal is recorded for the executor surface.
    func testLegacyIdentitylessMutationRefusesWithoutExecutingAndWithoutAResultFrame() async throws {
        // LEGACY_ACTION marker: the fixture-boundary injector skips it, so this fixture stays a
        // genuine identity-less cloud mutation — exactly what the strict runtime gate must refuse.
        self.pendingFixture = """
            LEGACY_ACTION

            event: action
            data: {"tool":"playback","action":"seek_to","params":{"position_seconds":95}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let consumer = RecordingResultConsumer()
        let sink = makeSinkWithConsumer(consumer)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-21")

        XCTAssertFalse(
            playback.calls.contains { if case .seekTo = $0 { return true }; return false },
            "an identity-less cloud mutation must not execute (no legacy fallback)"
        )
        let refused = consumer.consumed.filter { $0.result.outcome == .refused }
        XCTAssertEqual(refused.first?.result.reason, OperationReason.unsupportedOperation)
        try await Task.sleep(nanoseconds: 100_000_000)
        let sentFrames = await MainActor.run { capturedTask?.sentTextFrames ?? [] }
        XCTAssertFalse(
            sentFrames.contains { $0.contains("app_operation_result") },
            "no result frame is sent for an operation the server never identified"
        )
    }

    // MARK: - Typed journal persistence/replay + action-outcome propagation

    /// Waits (bounded) for the app_operation_result frame named by `operationId` on the current
    /// captured transport.
    private func awaitResultFrame(operationId: String, timeout: TimeInterval = 5) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frame: [String: Any]? = await MainActor.run {
                capturedTask?.sentTextFrames.compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }.first { ($0["type"] as? String) == "app_operation_result" && ($0["operation_id"] as? String) == operationId }
            }
            if let frame { return frame }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw XCTSkip("no result frame arrived") // replaced by a hard failure below
    }

    /// FULL TYPED REPLAY control: the same server-issued operation_id delivered across two turns
    /// is answered from the durable journal on the second delivery — the recorded outcome rides
    /// the real socket, and the effect does NOT run twice. Success replays with the ACTUAL
    /// resulting state (wire contract §3): a replayed success is not a bare outcome.
    func testRedeliveredIdentifiedOperationReplaysTheRecordedOutcomeWithoutReExecution() async throws {
        // seek_to, not pause: the turn's own auto-duck also pauses, which would
        // contaminate a pause-call count. A seek has no such second writer.
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-redeliver-1","capability_version":"v1","tool":"playback","action":"seek_to","params":{"position_seconds":42}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        // A's SETTLED state S: position 77 at the moment A finishes.
        playback.setPositionMs(77_000)

        // Turn 1: executes and settles succeeded with the typed state.
        let sink1 = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: journal)
        _ = await sink1.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-22")
        let firstFrame = try await awaitResultFrame(operationId: "op-redeliver-1")
        XCTAssertEqual(firstFrame["outcome"] as? String, "succeeded")
        let firstState = try XCTUnwrap(firstFrame["state"] as? [String: Any], "a success frame carries the resulting state")
        XCTAssertEqual(firstState["position_seconds"] as? Int, 77, "S: A settled at position 77")
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 1)

        // Turn 2: an UNRELATED operation B settles and moves the LIVE state (playing=false).
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-unrelated-b","capability_version":"v1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sinkB = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: journal)
        _ = await sinkB.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-23")
        _ = try await awaitResultFrame(operationId: "op-unrelated-b")
        // T: unrelated live drift AFTER A settled.
        playback.setPositionMs(9999_000)

        // Turn 3: the SAME operation_id A redelivered through a FRESH sink AND a FRESH journal
        // instance over the SAME durable file. The replay must answer A's SETTLED state S —
        // not the live state T that B created.
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-redeliver-1","capability_version":"v1","tool":"playback","action":"seek_to","params":{"position_seconds":42}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let reloadedJournal = OperationJournal(store: FileOperationRecordStore(url: url))
        let sink2 = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: reloadedJournal)
        _ = await sink2.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-24")
        let replayFrame = try await awaitResultFrame(operationId: "op-redeliver-1")
        XCTAssertEqual(replayFrame["outcome"] as? String, "succeeded", "the recorded outcome replays")
        let replayState = try XCTUnwrap(replayFrame["state"] as? [String: Any], "a replayed success carries A's SETTLED state")
        XCTAssertEqual(replayState["position_seconds"] as? Int, 77, "A's SETTLED position S, not the live drift T")
        // SAME CAPTURED ENVELOPE: the first send, the settled record, and the fresh-store replay
        // all carry ONE captured state — no second live snapshot at send or replay time.
        XCTAssertEqual(firstState["position_seconds"] as? Int, replayState["position_seconds"] as? Int,
                       "the first send is the settled envelope, not a second snapshot")
        XCTAssertEqual(firstState["playing"] as? Bool, replayState["playing"] as? Bool,
                       "playing agrees between settlement and replay")
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 1, "the effect never runs twice")
    }

    /// ACTION-OUTCOME PROPAGATION: an unknown action under the runtime gate is a REFUSAL
    /// (unsupported_operation) with nothing executed and no fabricated success — the server
    /// reads an honest outcome for an operation it identified.
    func testUnknownIdentifiedActionIsRefusedUnsupportedOperationNotFabricatedSuccess() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-unknown-1","capability_version":"v1","tool":"playback","action":"teleport","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let consumer = RecordingResultConsumer()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unknown-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let sink = makeSinkWithConsumer(consumer, operationJournal: journal)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-25")

        // The turn's own auto-duck may pause/resume; the unknown action itself must effect nothing.
        let effectCalls = playback.calls.filter { switch $0 { case .pause, .resume: return false; default: return true } }
        XCTAssertTrue(effectCalls.isEmpty, "an unknown action executes nothing: \(playback.calls)")
        let frame = try await awaitResultFrame(operationId: "op-unknown-1")
        XCTAssertEqual(frame["outcome"] as? String, "refused", "the server is not told an unknown action succeeded")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.unsupportedOperation)
        XCTAssertNil(frame["state"], "a refusal carries no state")
        // The refusal is also the journal's record: a redelivery replays the refusal.
        if case .alreadyRun(let recorded) = journal.claim("op-unknown-1") {
            XCTAssertEqual(recorded.outcome, .refused)
        } else {
            XCTFail("the refusal was not durably recorded")
        }
    }

    // MARK: - Typed journal persistence/replay + action-outcome propagation

    /// Waits (bounded) for the app_operation_result frame named by `operationId` on the current
    /// captured transport.
        /// REAL PRECONDITION (review 5295572f): with NO current episode (zero duration), the
    /// system seek wrapper early-returns and its silent response is NOT a success — the honest
    /// durable outcome is a refusal, and no seek is attempted.
    func testSeekToWithNoCurrentEpisodeIsRefusedStalePrecondition() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-seek-noep","capability_version":"v1","tool":"playback","action":"seek_to","params":{"position_seconds":42}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seek-noep-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let sink = makeSinkWithConsumer(
            RecordingResultConsumer(),
            operationJournal: journal,
            episodeAvailable: { false }
        )
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-26")
        let frame = try await awaitResultFrame(operationId: "op-seek-noep")
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.stalePrecondition)
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 0,
                       "no seek is attempted without an episode")
        if case .alreadyRun(let recorded) = journal.claim("op-seek-noep") {
            XCTAssertEqual(recorded.outcome, .refused)
        } else {
            XCTFail("the refusal was not durably settled")
        }
    }

    /// REAL PRECONDITION, reference form: seek_to reference_target ALSO refuses when no episode
    /// is available (it was bypassed before review fa03b7f9) — no mapping attempt, no seek.
    func testSeekToReferenceFormWithNoEpisodeIsRefusedBeforeMapping() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-seek-ref-noep","capability_version":"v1","tool":"playback","action":"seek_to","params":{"reference_position_ms":1000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let consumer = RecordingResultConsumer()
        let sink = makeSinkWithConsumer(consumer, episodeAvailable: { false })
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-27")
        let refusals = consumer.consumed.filter { $0.result.outcome == .refused }
        XCTAssertEqual(refusals.count, 1, "exactly one refusal for the reference-form seek")
        XCTAssertEqual(refusals.first?.result.reason, OperationReason.stalePrecondition)
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 0)
    }

    /// REAL PRECONDITION: resume with NO current episode refuses — PlaybackManager.play
    /// early-returns on no episode, so the silent wrapper would be a no-op dressed as success.
    func testResumeWithNoEpisodeIsRefusedStalePrecondition() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-resume-noep","capability_version":"v1","tool":"playback","action":"resume","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let consumer = RecordingResultConsumer()
        let sink = makeSinkWithConsumer(consumer, episodeAvailable: { false })
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-28")
        // The ACTION refused durably (the turn's own host-playback restore is separate
        // machinery and not observable here — the action-level outcome is what matters).
        let refusals = consumer.consumed.filter { $0.result.outcome == .refused }
        XCTAssertEqual(refusals.count, 1, "exactly one refusal for the unavailable resume")
        XCTAssertEqual(refusals.first?.result.reason, OperationReason.stalePrecondition)
    }

    /// PRODUCTION DEFAULT availability (review 0846e993): with NO injected availability closure
    /// and the REAL manager reporting no current episode, the reference-form seek refuses on the
    /// production path (existing-episode-with-unknown-duration would be AVAILABLE — duration is
    /// not availability — but the test host has no episode, which is the absent branch).
    func testProductionDefaultNoEpisodeRefusesReferenceSeek() async throws {
        let consumer = RecordingResultConsumer()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-prod-noep","capability_version":"v1","tool":"playback","action":"seek_to","params":{"reference_position_ms":1000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(consumer, playbackManager: PlaybackManager.shared)
        // ESTABLISH the premise against the REAL production state: the shared queue must have
        // no current episode. The test host's shared container can legitimately carry one from
        // launch, so the premise is established through the production queue API — never assumed.
        PlaybackManager.shared.queue.removeAllEpisodes()
        XCTAssertNil(PlaybackManager.shared.currentEpisode, "premise: no current episode after the reset")
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-29")
        let refusals = consumer.consumed.filter { $0.result.outcome == .refused }
        XCTAssertEqual(refusals.count, 1, "the production manager's absent episode refuses")
        XCTAssertEqual(refusals.first?.result.reason, OperationReason.stalePrecondition)
    }

    /// STOP-COMPLETION ORDER (review 24f236de): an error terminal WITH pending owned audio
    /// releases the host playback only after the ACTUAL stop the cancel requested — the resume
    /// never overlaps the un-stopped cloud output.
    func testErrorTerminalReleasesHostPlaybackOnlyAfterTheConfirmedStop() async throws {
        let fixture = """
            event: error
            data: {"message":"boom"}

            """
        self.pendingFixture = fixture
        let sink = makeSinkWithConsumer(
            RecordingResultConsumer(),
            audioPayloads: (0..<40).map { Data([UInt8($0)]) }
        )
        // Withhold the ACTUAL stop: the error terminal's release must wait for it, not for the
        // cancel request. Delivery (and therefore the stop confirmation) happens only below.
        // The capture runs on the MAIN queue, so it must never block: it stores the delivery
        // continuation and the test drives it from its own thread.
        final class DeliveryBox: @unchecked Sendable {
            private let lock = NSLock()
            private var deliver: (() -> Void)?
            func store(_ d: @escaping () -> Void) {
                lock.lock(); deliver = d; lock.unlock()
            }
            func deliverIfStored() {
                lock.lock(); let d = deliver; deliver = nil; lock.unlock()
                d?()
            }
        }
        let delivery = DeliveryBox()
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                delivery.store(deliver)
            }
        }
        let turn = Task { await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-30") }
        // The turn cannot finish while the stop is unconfirmed: no resume, no confirmed epoch.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 0,
                       "an unconfirmed stop does not release the host playback")
        let confirmedBefore = await MainActor.run { sink.audioPlayerForTesting?.confirmedStopEpoch() ?? 0 }
        XCTAssertEqual(confirmedBefore, 0, "the stop is not confirmed before it completes")
        // Deliver the actual stop: NOW the release lands, exactly once.
        var delivered = false
        for _ in 0..<100 {
            await MainActor.run { delivery.deliverIfStored() }
            if await MainActor.run(body: { sink.audioPlayerForTesting?.confirmedStopEpoch() ?? 0 }) > 0 {
                delivered = true; break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(delivered, "the withheld stop was delivered")
        let result = await turn.value
        _ = result
        XCTAssertTrue(playback.awaitResume(timeout: 5), "the release lands at the confirmed stop")
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1, "exactly one release")
        let confirmed = await MainActor.run { sink.audioPlayerForTesting?.confirmedStopEpoch() ?? 0 }
        XCTAssertGreaterThan(confirmed, 0, "the stop was confirmed")
        let pending = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? true }
        XCTAssertFalse(pending, "no owned audio survives the confirmed stop")
        await MainActor.run { sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil) }
    }

    /// PER-ACTION TRUE RESULT: play_quote WITHOUT its reference target refuses
    /// (malformed target) and settles durably — it is never reported as a success.
    func testPlayQuoteWithoutReferenceIsRefusedAndDurablySettled() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-pq-noref","capability_version":"v1","tool":"playback","action":"play_quote","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pq-noref-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: journal)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-31")
        let frame = try await awaitResultFrame(operationId: "op-pq-noref")
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.malformedSeekTarget)
        XCTAssertNil(frame["state"])
        if case .alreadyRun(let recorded) = journal.claim("op-pq-noref") {
            XCTAssertEqual(recorded.outcome, .refused)
        } else {
            XCTFail("the refusal was not durably settled")
        }
    }

    /// PER-ACTION TRUE RESULT: stop_quote with NO saved position (no prior play_quote) refuses
    /// (stale precondition) — there is nothing to restore, and silence is not a success.
    func testStopQuoteWithoutASavedPositionIsRefusedStalePrecondition() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-sq-nosave","capability_version":"v1","tool":"playback","action":"stop_quote","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-nosave-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: journal)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-32")
        let frame = try await awaitResultFrame(operationId: "op-sq-nosave")
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.stalePrecondition)
        if case .alreadyRun(let recorded) = journal.claim("op-sq-nosave") {
            XCTAssertEqual(recorded.outcome, .refused)
        } else {
            XCTFail("the refusal was not durably settled")
        }
    }

    /// A known, NONZERO offset: the mapped position is used and it is not the raw reference
    /// value. A mapping that returned its input would satisfy an equality check by accident, so
    /// the offset is deliberate.
    func testMappedReferenceSeekUsesTheMappedPositionNotTheRawReferenceValue() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        mapper.playbackSecondsForReference = [200.0: 215.0]
        let sink = makeSink()
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-33")

        XCTAssertTrue(playback.calls.contains(.seekTo(215)))
        XCTAssertFalse(playback.calls.contains(.seekTo(200)), "the raw reference value is not the target")
        let unavailable = await MainActor.run { sink.unavailableReferenceSeek }
        XCTAssertNil(unavailable, "a successful mapping is not an unavailability")
    }

    /// And through `play_quote`, so both actions are shown to use the mapping rather than only
    /// the one that happens to be convenient.
    func testMappedReferencePlayQuoteUsesTheMappedPosition() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"play_quote","params":{"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        mapper.playbackSecondsForReference = [200.0: 215.0]
        let sink = makeSink()
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-34")

        XCTAssertTrue(playback.calls.contains(.seekTo(215)))
        XCTAssertFalse(playback.calls.contains(.seekTo(200)))
    }

    /// Per-turn state: a `stop_quote` in a turn that issued no `play_quote`
    /// must NOT seek to a previous turn's captured pre-quote position.
    func testStopQuoteWithoutPlayQuoteInLaterTurnDoesNotUseStalePosition() async {
        // RecordingFingerprintMapper is a struct — configure it before the sink copies it.
        mapper.playbackSecondsForReference = [500.0: 510.0]
        playback.setPositionMs(900_000)
        let sink = makeSink()

        // Turn 1 captures a pre-quote position via play_quote.
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"play_quote","params":{"reference_position_ms":500000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        _ = await sink.routeToCloud(request: "play that", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-35")
        XCTAssertTrue(playback.calls.contains(.seekTo(510)))

        // Turn 2 (same sink): stop_quote without play_quote must be a no-op seek-wise.
        playback.clearCalls()
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"stop_quote","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        _ = await sink.routeToCloud(request: "stop", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-36")
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 0)
    }

    /// Slice 1: the sink sends one turn envelope — request_id on the wire and
    /// capabilities only once a structured-results renderer exists.
    func testSinkSendsTurnEnvelopeWithRequestIdAndGatedCapabilities() async throws {
        self.pendingFixture =
            """
            event: token
            data: {"text":"ok"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """

        _ = await makeSink().routeToCloud(request: "what did they say?", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88")

        let body = try XCTUnwrap(capturedTask?.sentAuthFrame)
        let requestId = try XCTUnwrap(body["request_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: requestId), "request_id must be a client-assigned UUID")
        XCTAssertNil(body["capabilities"], "no renderer yet: capabilities must be omitted so the server uses token+done")
        XCTAssertNil(body["route_hint"], "free-text turns carry no hint")
    }

    /// MISSING-ID BOUNDARY (reviewer c580c42b item 4): a dispatch with NO admitted utterance
    /// identity is refused with NO wire frame, NO consumed result, and NO successor-state
    /// contamination — the next admitted id dispatches as a clean first turn.
    func testSinkRefusesAnUnidentifiedDispatchWithNoWireFrameAndCleanSuccessorState() async throws {
        let consumer = RecordingResultConsumer()
        self.pendingFixture = """
            event: token
            data: {"text":""}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let sink = makeSinkWithConsumer(consumer)

        let refused = await sink.routeToCloud(
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: nil
        )
        XCTAssertEqual(refused.outcome, .refused, "a missing identity is refused, never dispatched")
        XCTAssertNil(capturedTask?.sentAuthFrame, "no identity, no client, no wire frame")
        XCTAssertTrue(consumer.consumed.isEmpty, "nothing reaches the successor consumer")

        // The refusal left NO half-built state: an admitted turn right after dispatches normally.
        let admitted = "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88"
        let result = await sink.routeToCloud(
            request: "play the news", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: admitted
        )
        XCTAssertEqual(result.outcome, .completed, "the admitted turn after the refusal is a clean first dispatch")
        let frame = try XCTUnwrap(capturedTask?.sentAuthFrame)
        XCTAssertEqual(frame["request_id"] as? String, admitted, "the wire id is the admitted id, not something minted by the refused attempt")
    }

    func testSinkAdvertisesSearchResultsV1OnlyWhenRendererAvailable() async throws {
        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """

        _ = await makeSink(rendersStructuredResults: true, routeHint: CloudRouteHint(
            operation: "search_spoken_content",
            arguments: ["query": .string("climate")]
        )).routeToCloud(request: "find the climate bit", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-38")

        let body = try XCTUnwrap(capturedTask?.sentAuthFrame)
        XCTAssertEqual(body["capabilities"] as? [String], ["search_results_v1"])
        let hint = try XCTUnwrap(body["route_hint"] as? [String: Any])
        XCTAssertEqual(hint["operation"] as? String, "search_spoken_content")
    }

    // MARK: - Helpers

    /// Under the strict runtime gate (wire contract rev da327e624), valid cloud app operations
    /// carry the server-issued `operation_id` and `capability_version`. Fixtures are upgraded AT
    /// THE SOCKET BOUNDARY so every valid-operation case exercises the identified envelope; the
    /// explicit legacy/malformed refusal cases opt out with the `LEGACY_ACTION` marker.
    static func injectOperationIdentity(_ fixture: String) -> String {
        guard fixture.contains("event: action"), !fixture.contains("LEGACY_ACTION") else { return fixture }
        var counter = 0
        var lines: [String] = []
        for raw in fixture.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("data:"),
               line.contains("\"tool\""), line.contains("playback"),
               !line.contains("operation_id"),
               let toolRange = line.range(of: "\"tool\"") {
                counter += 1
                line.replaceSubrange(
                    toolRange,
                    with: "\"operation_id\":\"op-fixture-\(counter)\",\"capability_version\":\"v1\",\"tool\""
                )
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// A REAL BARGE-IN MUST NOT DELIVER THE INTERRUPTED TURN'S LATE AUDIO.
    ///
    /// This is the rule the `.audioFrame` gate enforces, and the reason it uses `continue` rather
    /// than `break`: a late frame is the NORMAL case, because after an interrupt the server is
    /// still flushing audio it had already produced. The frame is dropped and the turn keeps
    /// draining to its terminal — ending the turn there would leave the successor's held
    /// follow-up without the acknowledgement it is parked on.
    ///
    /// Guarded by `testATurnCarryingBinaryAudioActuallyReachesThePlayer` below: the same fixture
    /// with no barge-in enqueues, so "nothing enqueued" here means the frame was refused rather
    /// than never sent.
    func testARealBargeInDoesNotDeliverTheInterruptedTurnsLateAudio() async {
        self.pendingFixture = """
        event: done
        data: {"usage":{"input_tokens":1,"output_tokens":1}}

        """
        // The turn must still be LIVE when the barge-in arrives, so its first receive is parked
        // and released only after the interrupt is sent — otherwise it completes first and there
        // is no predecessor to claim (which is how this control first passed vacuously).
        let latch = HoldLatch()
        pendingProducerHold = latch
        let sink = makeSinkWithConsumer(
            RecordingResultConsumer(),
            audioPayloads: (0..<4).map { _ in Data(repeating: 0x11, count: 4_800 * 2) })

        let prior = Task {
            await sink.routeToCloud(
                request: "prior question", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-turn-a")
        }
        var owned = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            // Registration, not merely the sink's published binding: the binding appears on the
            // main actor before the detached producer registers anything, so a non-nil socket
            // alone does not mean an interrupt can be delivered.
            let live = await MainActor.run(body: { () -> Bool in
                // `boundIdentity` is stamped BY registration, so requiring it observes the
                // transport rather than the sink's earlier binding publication.
                return sink.activeResultSocketForTesting?.boundIdentity != nil
            })
            if live {
                owned = true; break
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(owned, "premise: the prior turn's transport must be REGISTERED before it is interrupted")
        let priorRequestId = await MainActor.run { sink.activeResultSocketForTesting?.requestId }
        guard let priorRequestId else { XCTFail("premise: a live socket"); return }

        let emitted = await sink.emitBargeIn(
            request: "play the next one", utteranceId: "u-barge",
            origin: cloudTestOrigin, selection: CloudConversationSelection.followUp)
        XCTAssertEqual(emitted, priorRequestId, "the barge-in must claim the live predecessor")

        latch.release()
        // A LATE AUDIO FRAME MUST NOT END THE TURN. With `break` the loop stopped there and the
        // turn could never read the terminal that follows, so it classified as `earlyClose` — a
        // connection failure the user never experienced. `continue` drops the frame and keeps
        // draining, so the turn reaches its terminal.
        let result = await prior.value
        let enqueued = await MainActor.run { sink.audioPlayerForTesting?.framesEnqueuedForTesting ?? 0 }
        XCTAssertEqual(enqueued, 0,
                       "an interrupted turn must not deliver audio the user already took back; "
                       + "the player received \(enqueued) frame(s)")
        XCTAssertEqual(result.outcome, .completed,
                       "a late audio frame must be DROPPED, not end the turn: breaking there stops "
                       + "the interrupted turn reading its own terminal, so it reports a connection "
                       + "failure (earlyClose) that never happened")
    }

    /// POSITIVE CONTROL: the SAME fixture and the same parking, with NO barge-in, must reach the
    /// player. Without it, "no seek after a barge-in" cannot be told apart from "the action never
    /// parsed" — and the first three versions of the control below were vacuous for exactly that.
    func testLateActionReachesThePlayerWithoutABargeIn() async {
        mapper.playbackSecondsForReference = [1130.0: 1200.0]
        playback.setPositionMs(500_000)
        self.pendingFixture = """
        event: action
        data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":1130000}}

        event: done
        data: {"usage":{"input_tokens":1,"output_tokens":1}}

        """
        playback.clearCalls()

        // Plain `makeSink()`, no park, direct await — the exact shape that is known to reach the
        // executor. Anything else here made the control vacuous.
        await makeSink().routeToCloud(
            request: "prior question", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-turn-a")

        let seeks = playback.calls.filter { if case .seekTo = $0 { return true }; return false }
        XCTAssertFalse(seeks.isEmpty, "premise: this fixture must execute an action")
    }

    /// A REAL BARGE-IN MUST NOT EXECUTE THE INTERRUPTED TURN'S LATE ACTION.
    ///
    /// Driven through the path SHIPPING USES: `emitBargeIn` (service ->
    /// `emitEagerBargeInIfNeeded` -> here), not `routeToCloud`'s interrupt branch. On that path
    /// the prior turn is NOT cancelled — it stays live and draining — so `turnToken.effectsClosed`
    /// is the only gate open when the late action arrives, and it is what must refuse it.
    ///
    /// Asserted on the EXECUTOR STUB, not a log line: a refusal that logged and still executed
    /// would satisfy a log assertion and fail this one.
    func testARealBargeInDoesNotExecuteTheInterruptedTurnsLateAction() async {
        mapper.playbackSecondsForReference = [1130.0: 1200.0]
        playback.setPositionMs(500_000)
        self.pendingFixture = """
        event: action
        data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":1130000}}

        event: done
        data: {"usage":{"input_tokens":1,"output_tokens":1}}

        """
        // PARKED PRODUCER, so the prior turn is still live when the barge-in arrives. Without the
        // park it can finish first, leaving no predecessor to claim — the control then fails on
        // its own premise rather than on the behaviour, and did so only when run with the whole
        // class (a standalone run happened to be slow enough).
        let latch = HoldLatch()
        pendingProducerHold = latch
        let sink = makeSinkWithConsumer(RecordingResultConsumer())
        playback.clearCalls()

        // The prior turn runs in a Task because a barge-in has to land WHILE it is still in
        // flight. The action reaches the executor in this shape (see the positive control).
        let prior = Task {
            await sink.routeToCloud(
                request: "prior question", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-turn-a")
        }
        var owned = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            // Registration, not merely the sink's published binding: the binding appears on the
            // main actor before the detached producer registers anything, so a non-nil socket
            // alone does not mean an interrupt can be delivered.
            let live = await MainActor.run(body: { () -> Bool in
                // `boundIdentity` is stamped BY registration, so requiring it observes the
                // transport rather than the sink's earlier binding publication.
                return sink.activeResultSocketForTesting?.boundIdentity != nil
            })
            if live {
                owned = true; break
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(owned, "premise: the prior turn's transport must be REGISTERED before it is interrupted")
        let priorRequestId = await MainActor.run { sink.activeResultSocketForTesting?.requestId }
        guard let priorRequestId else { XCTFail("premise: a live socket"); return }

        let emitted = await sink.emitBargeIn(
            request: "play the next one", utteranceId: "u-barge",
            origin: cloudTestOrigin, selection: CloudConversationSelection.followUp)
        XCTAssertEqual(emitted, priorRequestId, "the barge-in must claim the live predecessor")

        latch.release()
        _ = await prior.value
        let seeks = playback.calls.filter { if case .seekTo = $0 { return true }; return false }
        XCTAssertTrue(seeks.isEmpty,
                      "an interrupted turn must not execute a late action: the executor saw "
                      + "\(seeks). Effects must close where every interrupt goes through")
    }


    private func makeSink(
        rendersStructuredResults: Bool = false,
        routeHint: CloudRouteHint? = nil
    ) -> CloudRouteSink {
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl,
                    fixture: Self.injectOperationIdentity(self.nextFixture())
                )
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            rendersStructuredResults: rendersStructuredResults,
            routeHintProvider: { routeHint },
            conversationManager: testConversationManager()
        )
    }



    private func sampleContext() -> PlaybackContext {
        PlaybackContext(
            episodeId: "ep",
            podcastId: "pod",
            referencePositionMs: 1_000,
            clientPositionMs: 1_100,
            recentReferencePositions: [],
            previousReferencePositionMs: nil
        )
    }
    // MARK: - Terminal outcome
    //
    // The turn's OUTCOME must be reported separately from how it is rendered. A spoken
    // error and a silent success are both "no earcon", so any caller deciding what
    // happened from the response shape gets these exactly backwards — which is how a
    // failed turn was recorded as a completed cloud route and reopened the grace window.

    func testDoneReportsCompleted() async {
        self.pendingFixture = """
        event: done
        data: {"usage":{"input_tokens":1,"output_tokens":1}}

        """
        let result = await makeSink().routeToCloud(
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-39")
        XCTAssertEqual(result.outcome, .completed)
    }

    func testSpokenServerErrorReportsFailureNotCompletion() async {
        // An error frame is a FAILED turn — never the completion shape the executor once read.
        // The code has no local template, so it renders as the error earcon; the subject here is
        // the OUTCOME, not the wording.
        self.pendingFixture = """
        event: error
        data: {"code":"rate_limited","message":"slow down"}

        """
        defaults.set("de", forKey: "AppleLanguages")
        let result = await makeSink().routeToCloud(
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-40")
        XCTAssertNotEqual(
            result.outcome, .completed,
            "a spoken server error was reported as a completed turn"
        )
        XCTAssertEqual(result.outcome, .failed(code: "rate_limited"))
    }

    func testStreamEndWithoutDoneReportsEarlyCloseNotCompletion() async {
        // A stream that closes after tokens but never sends `done` is a truncated turn.
        self.pendingFixture = """
        event: token
        data: {"text":"partial"}

        """
        let result = await makeSink().routeToCloud(
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-41")
        // The client surfaces a truncated stream as an explicit transport failure, so the
        // outcome may be `failed(connection_lost)` rather than a bare early close. What
        // must hold either way is that it is NOT a completion: an ended stream that never
        // sent `done` must not restore the allowance as though the model answered.
        XCTAssertNotEqual(
            result.outcome, .completed,
            "a stream that ended without done was reported as a completed turn"
        )
        if case .earlyClose = result.outcome {
            // reached only when the client reports the close without a code
        } else {
            XCTAssertEqual(
                result.outcome, .failed(code: "connection_lost"),
                "an unterminated stream was classified as neither an early close nor a "
                    + "transport failure: \(result.outcome)"
            )
        }
    }

    func testUnconfiguredReportsRefusedNotCompletion() async {
        // Premise must be genuinely unconfigured at BOTH layers. Removing only the UserDefaults
        // override left the build-time default (Info.plist AurisCloudBaseURL, non-empty in the
        // StagingDebug test host) active — the sink was actually CONFIGURED and correctly routed
        // to the stub transport, whose empty-fixture connection failure was the RIGHT answer for
        // the route it actually took. The old assertion measured a wrong premise, not wrong
        // production. Neutralise the build default via CloudConfig's injected buildDefaultGatewayURL.
        defaults.removeObject(forKey: CloudConfig.baseURLKey)
        let unconfiguredConfig = CloudConfig(defaults: defaults, buildDefaultGatewayURL: "")
        let sink = CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(baseURL: unconfiguredConfig.baseUrl, fixture: "")
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !unconfiguredConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            rendersStructuredResults: false,
            routeHintProvider: { nil },
            conversationManager: testConversationManager()
        )
        let result = await sink.routeToCloud(
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-42")
        XCTAssertEqual(
            result.outcome, .refused,
            "the coming-soon refusal was reported as a completed cloud turn"
        )
    }


    /// ACTUAL held-work owning-Task cancellation boundary with production prompt cleanup:
    /// cancellation is delivered ONLY by cancelling the real owning Task; the sink's own
    /// `withTaskCancellationHandler` retires the ORIGINAL registration synchronously while the
    /// consumer is suspended. Asserted: live original registration BEFORE cancel, actual socket
    /// cancellation BEFORE hold release, zero effects after release, and mandatory THIRD-store
    /// persisted settled unknown with no in-progress id.
    func testHeldWorkOwnerCancellationMidOperationNeverExecutesAfterRelease() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-held-mid","capability_version":"v1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        // TRANSPORT PARK, INSTALLED AT CREATION. It engages after the two scripted frames (auth
        // send + the action frame carrying the claim), so the turn reaches the claim/effect
        // boundary first and the park then holds the transport while the consumer is suspended
        // in the effect hold. Measured earlier design defect: arming this from `effectEntered`
        // meant the transport had already served its frames, so the park never engaged and the
        // "retirement woke the park" assertion could not be true. The park must therefore exist
        // BEFORE the frames, and `declaredParkDidPark` below proves it actually engaged.
        let receivePark = HoldLatch()
        pendingDeclaredPark = receivePark
        pendingDeclaredParkAfterFrames = 2
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: journal)
        // CANCELLATION-INSENSITIVE effect hold: no cancellation handler of any kind. ONLY
        // `release.release()` frees it, so owner cancellation cannot open it.
        let release = HoldLatch()
        // Bounded entry signal: set the moment the OWNER is actually inside the awaited hold, so
        // the external cancel below lands mid-suspension rather than racing the turn's start.
        let entered = HoldLatch()
        // External cancellation of the REAL owning task — the only mechanism, no side channel.
        let ownerRef = ControlCanceller()
        var gateEntryCount = 0
        // The owner's completion is observed by a NON-BLOCKING bounded race that never awaits the
        // owner itself as a child. A structured wait on `owner.value` would have to await the very
        // suspension the assertion is about, and its wait-for-all-children would never return.
        /// True once the owner has finished. NON-BLOCKING: the check is a bounded alarm raced
        /// against a completion PROMISE, so no branch ever leaves a child blocked on the owner's
        /// unbounded suspension (a task-group over `owner.value` would block the drain forever,
        /// which is exactly how this hung when first written).
        func ownerHasCompleted() async -> Bool {
            let completionPromise = Promise<Bool>()
            let watcher = Task {
                _ = await owner.value
                completionPromise.resolve(true)
            }
            defer { watcher.cancel() }
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                completionPromise.resolve(false)
            }
            defer { timeout.cancel() }
            return await completionPromise.value()
        }
        await MainActor.run {
            sink.effectGate = { _ in
                gateEntryCount += 1
                entered.release()
                await release.waitUntilReleased()
            }
        }

        let owner = Task {
            await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-43")
        }
        ownerRef.bind(owner)
        // Wait until the OWNER is provably inside the awaited hold: the suspension is the owner's.
        await entered.waitUntilReleased()
        XCTAssertEqual(gateEntryCount, 1, "the owner itself must enter the awaited gate exactly once")
        XCTAssertEqual(journal.interruptedOperationIDs(), ["op-held-mid"], "operation durably claimed while held")
        XCTAssertTrue(capturedTask?.declaredParkDidPark ?? false,
                      "the declared transport park must actually engage, or the wake assertion is vacuous")
        XCTAssertEqual(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count, 0,
                       "no effect may run while held")
        // Ordered, non-blocking suspension checks: this helper never blocks on the owner.
        let heldInsideGate = await ownerHasCompleted()
        XCTAssertFalse(heldInsideGate, "the owner must still be held inside the awaited gate")
        // Cancel the REAL owning task — the only cancellation mechanism here.
        ownerRef.cancel()
        // ACTUAL RETIREMENT BEFORE RELEASE: the production onCancel path retires the ORIGINAL
        // registration synchronously while the owner remains suspended in the held work.
        let retiredBeforeRelease = await capturedTask?.awaitCancellation(timeout: 1.0) ?? false
        XCTAssertTrue(retiredBeforeRelease,
                      "cancellation itself must retire the original registration while suspended, before release")
        XCTAssertTrue(receivePark.releasedByRetirement,
                      "the parked receive may wake ONLY on socket retirement, never task cancellation")
        let completedBeforeRelease = await ownerHasCompleted()
        XCTAssertFalse(completedBeforeRelease, "completion must stay false until the explicit release")
        XCTAssertFalse(release.released, "effect hold must remain parked until explicit test release")
        release.release()
        let outcome = await owner.value
        // MANDATORY EXACT OUTCOME: the owner cancelled mid-operation must surface exactly
        // `earlyClose` — not a bare failure, not a completion. The width of this assertion is the
        // point: any other outcome means the cancelled turn was misclassified on its way out.
        guard case .earlyClose = outcome.outcome else {
            XCTFail("cancelled mid-operation must report exactly earlyClose; got \(outcome.outcome)")
            return
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let effectsTotal = playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count
        XCTAssertEqual(effectsTotal, 0, "cancelled-before-start must NEVER execute after release")
        // Mandatory recovery through RECREATED stores: second reconstructs persisted unknown,
        // THIRD reload proves the settlement itself is durable with no in-progress id.
        let recreated = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(recreated.interruptedOperationIDs(), ["op-held-mid"], "claimed interrupted case stays in progress")
        XCTAssertEqual(recreated.reconstructInterrupted("op-held-mid")?.outcome, .unknown)
        let third = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertTrue(third.interruptedOperationIDs().isEmpty, "settled unknown must be durable, no in-progress id")
        XCTAssertEqual(third.claim("op-held-mid"),
                       OperationClaim.alreadyRun(.nonSuccess(.unknown, reason: OperationReason.interruptedInFlight)))
    }


    /// Distinct behavior #2: a CONFIGURED route whose connection fails must report the
    /// transport failure — not be relabeled as a pre-transport refusal. This is what the old
    /// broken-premise test accidentally measured; it belongs here explicitly.
    func testConfiguredTransportFailureReportsConnectionLossNotRefusal() async {
        self.pendingFixture = ""   // configured stub whose socket closes before any event
        let result = await makeSink().routeToCloud(
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-44")
        XCTAssertEqual(result.outcome, .failed(code: "connection_lost"),
                       "a configured route with a dead connection reports transport failure")
    }

    /// Owning-Task cancellation regression, attribution-corrected: an identified pause turn has
    /// EXPECTED lifecycle auto-pause (CloudRouteSink.swift:315, when playing before hold) plus the
    /// action effect (line 551). Cancellation must not add a second effect execution: total pauses
    /// ≤ 1 lifecycle + 1 effect, and a claimed-but-interrupted operation stays reconstructable
    /// unknown, never re-executed, never `cancelled`.
    func testOwnerTaskCancellationDoesNotDoubleExecuteTheIdentifiedMutation() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-owner-cancel","capability_version":"v1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let journal = OperationJournal(store: InMemoryOperationRecordStore())
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: journal)
        let owner = Task {
            await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-45")
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        owner.cancel()
        _ = await owner.value
        try await Task.sleep(nanoseconds: 150_000_000)
        // Distinguish lifecycle from effect by ORDER: the lifecycle auto-pause always precedes
        // action handling, so pauses[0] is the lifecycle call and the rest are effect executions.
        let pauses = playback.calls.filter { if case .pause = $0 { return true }; return false }
        let effectPauses = pauses.dropFirst()
        XCTAssertLessThanOrEqual(effectPauses.count, 1, "the identified effect executes at most once")
        if case .alreadyRun = journal.claim("op-owner-cancel") {
            // The turn completed before cancellation: the effect MUST have executed exactly once.
            XCTAssertEqual(effectPauses.count, 1, "a completed operation's effect ran exactly once")
        }
        if journal.claim("op-owner-cancel") == OperationClaim.inProgress {
            XCTAssertEqual(journal.reconstructInterrupted("op-owner-cancel")?.outcome, .unknown)
            if case .alreadyRun = journal.claim("op-owner-cancel") {} else {
                XCTFail("reconstructed record must settle")
            }
        }
    }

func testOwnerTaskCancelDuringIdentifiedOperationEffectOnceAndRecoveryByRecordState() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-held-cancel","capability_version":"v1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: journal)
        let owner = Task {
            await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-46")
        }
        // Deterministic premise WITHOUT a verification-side claim: wait until the durable store
        // itself shows the operation's record (in progress or already finished), so the cancel
        // always lands at a known-observed point. The recreated record's state decides the
        // expectation below; a mid-effect retirement claim is NOT made here (held-work control
        // is separately assigned).
        let durable = FileOperationRecordStore(url: url)
        let observed = await Task.detached {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if !durable.load().isEmpty { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return false
        }.value
        XCTAssertTrue(observed, "operation record never became durable within 5s")
        owner.cancel()
        _ = await owner.value
        try await Task.sleep(nanoseconds: 150_000_000)
        let effectCount = playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count
        XCTAssertLessThanOrEqual(effectCount, 1, "the identified effect must not duplicate")
        // Recreate store + journal (restart simulation). The record's state decides the
        // expectation: completed-before-cancel must be settled (alreadyRun, nil reconstruction —
        // bytes persisted proves the durable round trip); a still-in-progress record must
        // reconstruct as persisted unknown.
        let restarted = OperationJournal(store: FileOperationRecordStore(url: url))
        let effectPausesOrRelatives = effectCount
        switch restarted.claim("op-held-cancel") {
        case .alreadyRun:
            XCTAssertLessThanOrEqual(effectPausesOrRelatives, 1)
        case .inProgress:
            XCTAssertEqual(restarted.reconstructInterrupted("op-held-cancel")?.outcome, .unknown)
            if case .alreadyRun = restarted.claim("op-held-cancel") {} else {
                XCTFail("reconstructed record must settle")
            }
        default:
            XCTFail("durable record lost across recreation")
        }
    }

    /// Recreated-store recovery, deterministic (no sink race): a process that claimed and died
    /// leaves `.inProgress` on disk; a RECREATED store+journal reconstructs persisted unknown,
    /// settles it, and never replays it as executable.
    func testRecreatedDurableStoreReconstructsUnknownWithoutReplay() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).json")
        let first = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(first.claim("op-died"), OperationClaim.claimed)
        // Process death: no complete() ever runs. A NEW store+journal over the same URL:
        let restarted = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(restarted.interruptedOperationIDs(), ["op-died"])
        XCTAssertEqual(restarted.reconstructInterrupted("op-died")?.outcome, .unknown)
        if case .alreadyRun = restarted.claim("op-died") {} else {
            XCTFail("reconstructed record must settle")
        }
        // THIRD store+journal: the settlement itself must be durable, not just in the second
        // journal's memory.
        let third = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertTrue(third.interruptedOperationIDs().isEmpty, "no in-progress id may survive settlement")
        XCTAssertEqual(
            third.claim("op-died"),
            OperationClaim.alreadyRun(.nonSuccess(.unknown, reason: OperationReason.interruptedInFlight))
        )
    }

    /// A store whose writes fail: claim persistence failure must prevent the effect fail-closed.
    func testFailingClaimPersistenceRefusesEffectWithoutExecution() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-no-persist","capability_version":"v1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let journal = OperationJournal(store: AlwaysFailingOperationRecordStore())
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: journal)
        await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-47")
        let effectCount = playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count
        XCTAssertEqual(effectCount, 0, "a failed claim write must prevent the effect entirely")
    }

    /// A settlement write that fails after the effect ran, observed through the store's ACTUAL
    /// write path: complete returns false, live memory stays unsettled (never replayable as
    /// succeeded), and a recreated store still holds the in-progress id.
    func testFailingSettlementWriteNeverReplaysTheOperation() async {
        let store = SettlementFailingOperationRecordStore()
        let journal = OperationJournal(store: store)
        XCTAssertEqual(journal.claim("op-settle-fail"), OperationClaim.claimed)
        XCTAssertFalse(journal.complete("op-settle-fail", result: .succeeded(state: ["position_seconds": .int(0)])), "failed settlement must be reported")
        // Live-memory observation: the record did NOT publish as finished-succeeded.
        XCTAssertNil(journal.result(for: "op-settle-fail"), "failed settlement must not publish success")
        XCTAssertEqual(journal.claim("op-settle-fail"), OperationClaim.inProgress, "unsettled operation stays in progress, never replayable")
        // Recreated-store observation through the same write path:
        let recreated = OperationJournal(store: SettlementFailingOperationRecordStore(backing: store))
        XCTAssertEqual(recreated.interruptedOperationIDs(), ["op-settle-fail"], "durable record must still be in progress")
        XCTAssertNil(recreated.reconstructInterrupted("op-settle-fail"), "failed recovery settlement must not report settled unknown")
        XCTAssertEqual(recreated.claim("op-settle-fail"), OperationClaim.inProgress)
    }

    /// Semantically corrupt durable history (bogus outcome, unknown state) must fail closed:
    /// no id in it may silently re-claim and execute.
    func testSemanticallyCorruptHistoryIsUnreadableNeverExecutable() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).json")
        try? Data("{\"op-x\":{\"state\":\"weird\"},\"op-y\":{\"state\":\"finished\",\"outcome\":\"bogus\"}}".utf8)
            .write(to: url)
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(journal.claim("op-x"), .persistenceUnavailable, "unknown-state history must refuse, not re-claim")
        XCTAssertEqual(journal.claim("op-y"), .persistenceUnavailable, "bogus-outcome history must refuse, not re-claim")
    }

    /// RESTART RECOVERY, production shape: an operation a previous process left in progress is
    /// reconstructed as persisted `unknown` (the assembly does this at launch), and the sink then
    /// replays that recorded unknown through the bound transport WITHOUT re-executing the effect.
    func testRestartReconstructedUnknownReplaysThroughTransportWithoutReExecution() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"op-restart","capability_version":"v1","tool":"playback","action":"seek_to","params":{"position_seconds":30}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // A previous process died after claiming and before completing.
        let store = InMemoryOperationRecordStore()
        let journal = OperationJournal(store: store)
        XCTAssertEqual(journal.claim("op-restart"), OperationClaim.claimed)
        // The restart recovery path the assembly runs at launch:
        let reconstructed = journal.reconstructInterrupted("op-restart")
        XCTAssertEqual(reconstructed?.outcome, .unknown)

        let consumer = RecordingResultConsumer()
        let sink = makeSinkWithConsumer(consumer, operationJournal: journal)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-48")

        // The effect must NOT have run: no seek reached playback.
        XCTAssertFalse(
            playback.calls.contains { if case .seekTo = $0 { return true }; return false },
            "a reconstructed-unknown operation must never re-execute its effect"
        )
        // The recorded unknown replays through the bound transport.
        let deadline = Date().addingTimeInterval(5)
        var resultFrame: [String: Any]?
        while Date() < deadline && resultFrame == nil {
            resultFrame = await MainActor.run {
                capturedTask?.sentTextFrames.compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }.first { ($0["type"] as? String) == "app_operation_result" }
            }
            if resultFrame == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let frame = try XCTUnwrap(resultFrame, "the reconstructed unknown must ride the turn socket")
        XCTAssertEqual(frame["operation_id"] as? String, "op-restart")
        XCTAssertEqual(frame["outcome"] as? String, "unknown")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.interruptedInFlight)
        // And the record stays settled: a further claim replays, not re-claims.
        if case .alreadyRun = journal.claim("op-restart") {} else {
            XCTFail("the reconstructed record must be settled")
        }
    }

    /// AN ORDINARY TURN THAT SETTLES WITH BUFFERED AUDIO BINDS OWNERSHIP, AND A SUCCESSOR'S STOP
    /// CREATES ITS REPORT — executed through the real turn lifecycle, not by poking state.
    ///
    /// The state-only controls this replaces asserted the read-and-clear helpers directly, so the
    /// production sequence (done -> audio still playing -> successor stops it -> report) was never
    /// executed. Here turn A runs to `done` with audio payloads still outstanding, and the binding
    /// is asserted as a consequence of that turn.
    func testAnOrdinaryTurnWithBufferedAudioBindsPlaybackOwnershipAtDone() async throws {
        try await checkBufferedPlaybackNextAuth(drainBeforeFollowUp: false)
    }

    func testDrainedBufferedPlaybackSendsNoInterruptionReportOnNextAuth() async throws {
        try await checkBufferedPlaybackNextAuth(drainBeforeFollowUp: true)
    }

    /// THE WIRE DECIDES WHAT IS RESUMABLE. A turn that receives `connected` makes its conversation
    /// the one later turns resume; the same turn WITHOUT the frame leaves nothing to resume, and
    /// the next follow-up opens a fresh conversation. Both halves run through the real sink over a
    /// scripted transport, so the assertion is on the wire mode a follow-up actually sends rather
    /// than on manager state the test wrote itself.
    ///
    /// This is the client half of the conversation-lifecycle rule: `connected` is sent only after
    /// the server admits a turn, so it — not the sending of a request — is the evidence that a
    /// conversation exists.
    func testOnlyAnAcknowledgedConversationIsResumedByTheNextFollowUp() async throws {
        for acknowledge in [true, false] {
            let manager = CloudConversationManager()
            manager.registerLiveOrigin(cloudTestOrigin)

            self.pendingFixture = acknowledge
                ? """
                event: connected
                data: {"codec":"pcm_s16le@24k"}

                event: done
                data: {"usage":{"input_tokens":1,"output_tokens":1}}

                """
                : """
                event: done
                data: {"usage":{"input_tokens":1,"output_tokens":1}}

                """
            let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
            let opening = await sink.routeToCloud(
                request: "find episodes", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .wakeWord, utteranceId: "u-ack-\(acknowledge)"
            )
            XCTAssertEqual(opening.outcome, .completed, "premise: the opening turn ran")

            self.pendingFixture = """
                event: done
                data: {"usage":{"input_tokens":1,"output_tokens":1}}

                """
            _ = await sink.routeToCloud(
                request: "play the second one", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-next-\(acknowledge)"
            )
            let auths = capturedTask?.sentTextFrames.compactMap { text -> [String: Any]? in
                guard let data = text.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }.filter { $0["type"] as? String == "authenticate" } ?? []
            let followUp = try XCTUnwrap(auths.last)
            XCTAssertEqual(followUp["request_id"] as? String, "u-next-\(acknowledge)")
            XCTAssertEqual(
                followUp["conversation_mode"] as? String,
                acknowledge ? "resume" : "create",
                acknowledge
                    ? "an acknowledged conversation was not resumed, so the thread restarts"
                    : "a follow-up resumed a conversation the server never acknowledged"
            )
        }
    }

    /// THE REPORT IS CHECKED AGAINST THE CONVERSATION THE TURN ACTUALLY SENDS.
    ///
    /// A report corrects one conversation's settled history. When the send-time decision opens a
    /// fresh conversation, the prepared id and the dialled id differ — comparing against the
    /// prepared one would attach the correction to a turn that is no longer in that conversation,
    /// asking the server to amend history it never settled.
    ///
    /// The control half matters as much: when the ids DO match, the report must survive. Without
    /// it, "always discard" would pass the first assertion.
    @MainActor
    func testThePendingReportIsCheckedAgainstTheConversationActuallySent() async throws {
        for acknowledged in [false, true] {
            let manager = CloudConversationManager()
            manager.registerLiveOrigin(cloudTestOrigin)
            self.pendingFixture = acknowledged
                ? """
                event: connected
                data: {"codec":"pcm_s16le@24k"}

                event: done
                data: {"usage":{"input_tokens":1,"output_tokens":1}}

                """
                : """
                event: done
                data: {"usage":{"input_tokens":1,"output_tokens":1}}

                """
            let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
            let opening = await sink.routeToCloud(
                request: "find episodes", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .wakeWord, utteranceId: "u-rep-open-\(acknowledged)"
            )
            XCTAssertEqual(opening.outcome, .completed, "premise: the opening turn ran")
            let openedId = try XCTUnwrap(
                manager.preparedConversationForTesting(utteranceId: "u-rep-open-\(acknowledged)")
            ).conversationId

            // A refusal of an interrupted turn leaves a report naming THAT turn's conversation.
            let state = sink.interruptionStateForTesting
            XCTAssertTrue(state.claimInterruptEmission(forRequestId: "u-rep-open-\(acknowledged)"))
            XCTAssertTrue(state.recordRefusal(
                forRequestId: "u-rep-open-\(acknowledged)",
                retainingReport: .init(requestId: "u-rep-open-\(acknowledged)", playbackPositionMs: 1_000, conversationId: openedId)
            ))
            XCTAssertEqual(state.pendingReportConversationId, openedId, "premise: a report is pending")

            self.pendingFixture = """
                event: done
                data: {"usage":{"input_tokens":1,"output_tokens":1}}

                """
            _ = await sink.routeToCloud(
                request: "play the second one", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-rep-next-\(acknowledged)"
            )
            let auths = capturedTask?.sentTextFrames.compactMap { text -> [String: Any]? in
                guard let data = text.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }.filter { $0["type"] as? String == "authenticate" } ?? []
            let followUp = try XCTUnwrap(auths.last)
            let sentId = try XCTUnwrap(followUp["conversation_id"] as? String)

            if acknowledged {
                XCTAssertEqual(sentId, openedId, "control premise: the follow-up stayed in the conversation")
                XCTAssertNotNil(
                    followUp["interrupts"],
                    "a report for the conversation this turn is still in was discarded"
                )
            } else {
                XCTAssertNotEqual(sentId, openedId, "premise: the send opened a different conversation")
                XCTAssertNil(
                    followUp["interrupts"],
                    "a report was attached to a turn that left its conversation"
                )
            }
        }
    }

    private func checkBufferedPlaybackNextAuth(drainBeforeFollowUp: Bool) async throws {
        // A REAL OUTPUT IS REQUIRED for the binding to exist at all: with no available output the
        // player consumes frames silently, `hasPendingAudio` is false, and `done` correctly binds
        // nothing (measured — the first version of this control failed for exactly that reason and
        // was reporting on the silent-consume case, not the buffered-playback one).
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        defer { CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil }
        // `connected` is what makes the conversation real — it is sent after admission — so the
        // scripted turn carries it, as the protocol does. Without it the follow-up below would be
        // naming a conversation the server never acknowledged, which is the case the change is for.
        self.pendingFixture = """
            event: connected
            data: {"codec":"pcm_s16le@24k"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let sink = makeSinkWithConsumer(
            RecordingResultConsumer(),
            audioPayloads: (0..<40).map { Data([UInt8($0)]) }
        )
        // Turn A is a WAKE that opens the conversation. Stated as one because it is: a turn that
        // does not say it is a follow-up is not continuing anything, and after this change it no
        // longer quietly resumes a conversation the server never acknowledged.
        let turn = Task {
            await sink.routeToCloud(
                request: "x", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .wakeWord, utteranceId: "u-settled"
            )
        }
        _ = await turn.value

        // THE PRODUCTION CONSEQUENCE: `done` with audio still outstanding binds the owner. An
        // ordinary turn has NO interruption id, which is why gating the binding on one left this
        // case with no producer at all.
        let bound = await MainActor.run {
            sink.interruptionStateForTesting.bufferedPlaybackOwnerRequestIdForTesting
        }
        XCTAssertEqual(
            bound, "u-settled",
            "a turn that settles with buffered audio must BIND ownership at done, so a later stop "
            + "has a producer for its report"
        )
        let owesReport = await MainActor.run {
            sink.interruptionStateForTesting.hasPendingReport
        }
        XCTAssertFalse(owesReport, "nothing is owed yet: the user has not stopped hearing it")
        if drainBeforeFollowUp {
            let player = await MainActor.run { sink.audioPlayerForTesting }
            let actualPlayer = try XCTUnwrap(player)
            let epoch = actualPlayer.finish()
            let drained = await actualPlayer.awaitActualStop(after: epoch, timeout: 5)
            XCTAssertTrue(drained, "natural finish must confirm its physical drain")
            let binding = await MainActor.run {
                sink.interruptionStateForTesting.bufferedPlaybackOwnerRequestIdForTesting
            }
            XCTAssertNil(binding, "the production drain callback must clear buffered ownership")
        }

        // `connected` is what makes the conversation real. Turn A's fixture does not script one,
        // so the acknowledgement is delivered the way production delivers it — the frame reaches
        // the turn and the turn records it — through the sink's own `connected` handling rather
        // than by writing the manager's state from the test.
        pendingFixture = """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        _ = await sink.routeToCloud(
            request: "follow up", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-next"
        )
        let frames = capturedTask?.sentTextFrames.compactMap { text -> [String: Any]? in
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } ?? []
        let auth = try XCTUnwrap(frames.first { $0["type"] as? String == "authenticate" })
        XCTAssertEqual(auth["request_id"] as? String, "u-next")
        if drainBeforeFollowUp {
            XCTAssertNil(auth["interrupts"], "fully heard playback owes no interruption report")
        } else {
            let report = try XCTUnwrap(auth["interrupts"] as? [String: Any])
            XCTAssertEqual(report["request_id"] as? String, "u-settled")
        }
        let stillPending = await MainActor.run { sink.interruptionStateForTesting.hasPendingReport }
        XCTAssertFalse(stillPending)
    }
}


/// A playback double whose reads and writes are SYNCHRONIZED.
///
/// The sink calls it from its own serial task while a test reads it from the test task, so the
/// unlocked `var calls` / `var isPlaying` this replaces were a data race: a resume could land
/// after a read and the same assertion then saw 1 or 0 across identical runs. Everything below is
/// behind one lock, and `awaitResume()` waits on the lock rather than polling a copied array, so a
/// test observes the state the double actually holds.
private final class RecordingPlaybackSink: VoicePlaybackSink, @unchecked Sendable {
    /// Host playing at the moment the turn reads it. `pause()` and `resume()`
    /// keep it true to playback: a constant `true` hides a lost hold, because a
    /// turn that inherits an outstanding pause would still read "playing".
    private let lock = NSLock()
    private var storedIsPlaying = true
    private var storedCalls: [Call] = []
    private var storedPositionMs: Int64 = 0
    /// Signalled each time `resume()` records a call, so a test can AWAIT restoration rather than
    /// poll a snapshot that may predate it.
    private let resumeLatch = NSCondition()

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedIsPlaying
    }

    enum Call: Equatable {
        case pause, resume, seekRelative(Int?, SeekDirection), seekTo(Int), nextEpisode
    }

    /// Models the state before a turn: a user who paused before speaking, or a
    /// player that is running. `pause()`/`resume()` maintain it thereafter.
    func setPlaying(_ playing: Bool) {
        lock.lock(); storedIsPlaying = playing; lock.unlock()
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return storedCalls
    }

    var positionMs: Int64 {
        lock.lock(); defer { lock.unlock() }
        return storedPositionMs
    }

    func setPositionMs(_ value: Int64) {
        lock.lock(); storedPositionMs = value; lock.unlock()
    }

    func clearCalls() {
        lock.lock(); storedCalls = []; lock.unlock()
    }

    /// Waits until a resume has been RECORDED, or the deadline passes. This is the observable
    /// settled signal: it reads the double's own synchronised state instead of polling a copy.
    @discardableResult
    func awaitResume(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            lock.lock()
            let seen = storedCalls.contains(.resume)
            lock.unlock()
            if seen { return true }
            usleep(2_000)
        }
        return false
    }

    func pause() -> VoiceResponse {
        lock.lock()
        storedCalls.append(.pause)
        storedIsPlaying = false
        lock.unlock()
        return .earcon(.success)
    }

    func resume() -> VoiceResponse {
        lock.lock()
        storedCalls.append(.resume)
        storedIsPlaying = true
        lock.unlock()
        resumeLatch.broadcast()
        return .silent
    }

    private func record(_ call: Call) {
        lock.lock(); storedCalls.append(call); lock.unlock()
    }

    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse {
        record(.seekRelative(deltaSeconds, direction))
        return .silent
    }

    func seekTo(positionSeconds: Int) -> VoiceResponse {
        record(.seekTo(positionSeconds))
        return .silent
    }

    /// A negative position resolves back from the episode end, as the real sink
    /// does; the double records the resolved absolute position.
    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse {
        let resolved = positionSeconds < 0
            ? max(episodeDurationSeconds + positionSeconds, 0)
            : positionSeconds
        record(.seekTo(resolved))
        return .silent
    }

    func nextEpisode() -> VoiceResponse {
        record(.nextEpisode)
        return .silent
    }
}

private struct RecordingFingerprintMapper: FingerprintMappingProviding {
    var playbackSecondsForReference: [TimeInterval: TimeInterval] = [:]

    func matchedReferenceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval? { nil }

    func playbackTime(forReferenceTime referenceTime: TimeInterval) -> TimeInterval? {
        playbackSecondsForReference[referenceTime]
    }
}

private final class RecordingAnalytics: AnalyticsService {
    var events: [(String, [String: Any])] = []
    func track(_ event: String, properties: [String: Any]) {
        events.append((event, properties))
    }
}

// MARK: - Slice 4: superseded turns

/// A second turn (double wake / barge-in) supersedes the first: the older turn
/// must stop consuming its stream and must not touch playback state, analytics,
/// or late actions after the new turn takes over.
/// Independent completion flag for bounded completion probes (review 9fc2603e).
private final class ProbeCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() { lock.lock(); done = true; lock.unlock() }
    var isSet: Bool { lock.lock(); let d = done; lock.unlock(); return d }
}

final class CloudRouteSupersedeTests: SocketCapturingTestCase {
    private var playback: RecordingPlaybackSink!
    private var mapper: RecordingFingerprintMapper!
    private var analytics: RecordingAnalytics!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        mapper = RecordingFingerprintMapper()
        analytics = RecordingAnalytics()
        suiteName = "cloud_route_supersede_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        // Per-test hold bookkeeping: a ledger or counter left from an earlier test would let this
        // one's assertions read another turn's holds.
        holdCounters = nil
        holdLedger = nil
        refuseHoldBeginsAfterFirst = false
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        StubWebSocketTask.resetProductionParks()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    /// REGRESSION CONTROL for a park that leaked between tests (spec 16fdf2a0, reviewer b48a85f8).
    ///
    /// `releaseProductionParks` used to record released parks by `ObjectIdentifier`. An identifier
    /// outlives the object it names and a deallocated semaphore's address is immediately reused,
    /// so once ANY test had released a park, a LATER test's brand-new semaphore could land on a
    /// recycled address and be treated as already-open: `registerProductionPark` returned false
    /// and that park silently did not block. The turn then ran on instead of parking, which is
    /// what made `testSupersededTurnDoesNotRestoreButRecordsInterrupted` fail only in suite order.
    ///
    /// This pins the property directly and deterministically, so the failure does not depend on
    /// flake luck: after a release, a FRESH park must still block.
    func testAFreshProductionParkStillBlocksAfterAnEarlierRelease() async throws {
        // An earlier test's park, released and then genuinely DROPPED — the release must not keep
        // it alive, or its address could never be recycled and the bug this pins stays hidden.
        func registerAndReleaseAPark() {
            let earlier = DispatchSemaphore(value: 0)
            XCTAssertTrue(StubWebSocketTask.registerProductionPark(earlier))
            StubWebSocketTask.releaseProductionParks()
        }
        registerAndReleaseAPark()
        // Address reuse is what made the identity comparison unsound: allocate and drop many
        // semaphores so a recycled address is near-certain, exactly as across a suite run.
        for _ in 0..<2000 { _ = DispatchSemaphore(value: 0) }

        let fresh = DispatchSemaphore(value: 0)
        XCTAssertTrue(
            StubWebSocketTask.registerProductionPark(fresh),
            "a fresh park must not be mistaken for an already-released one"
        )
        // It must actually BLOCK: a stale identity would have let this through instantly.
        let blocked = fresh.wait(timeout: .now() + 0.05) == .timedOut
        XCTAssertTrue(blocked, "a freshly registered park must still hold its producer")
        StubWebSocketTask.releaseProductionParks()
        XCTAssertEqual(fresh.wait(timeout: .now() + 0.5), .success, "release opens the fresh park")
    }

    func testDoneKeepsTheHoldWhileOnlyScheduledAudioRemains() async throws {
        try await exerciseScheduledOnlyDone(coalesceBeforeDone: false)
    }

    @MainActor
    func testCoalescedDoneReleasesTheHoldOnItsBoundPhysicalStop() async throws {
        try await exerciseScheduledOnlyDone(coalesceBeforeDone: true)
    }

    @MainActor
    private func exerciseScheduledOnlyDone(coalesceBeforeDone: Bool) async throws {
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        CloudAudioPlayer.configureEngineForTesting = { engine in
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        }
        addTeardownBlock {
            CloudAudioPlayer.configureEngineForTesting = nil
            CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        }
        let producerRelease = DispatchSemaphore(value: 0)
        blockProducerAfterFrames = (8, producerRelease) // Seven binary PCM messages, then park before done.
        nextTurnFixture = Self.doneOnlyFixture
        nextTurnAudioPayloads = (0..<7).map { _ in Data(repeating: 0x11, count: 4_800 * 2) }
        holdCounters = (AtomicInteger(), AtomicInteger())
        playback.setPlaying(true)
        let sink = makeSink(withHoldCounters: true)
        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)
        player.emittedPCMReference = reference
        player.echoReferenceHandoff = handoff
        addTeardownBlock { @MainActor in
            producerRelease.signal()
            player.openPhysicalStopGateForTesting()
            let stop = player.cancel()
            let settled = await player.awaitActualStop(after: stop)
            XCTAssertTrue(settled, "cleanup must settle before resetting the shared offline hook")
            withExtendedLifetime(handoff) {}
            withExtendedLifetime(sink) {}
        }
        let turn = Task {
            await sink.routeToCloud(request: "scheduled audio", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: .wakeWord, utteranceId: "scheduled-only")
        }
        try await waitUntil("audio reached the real player before done", timeout: 3) {
            reference.streamIndex == 22_400 && player.bufferedFrameCountForTesting == 0
        }
        let engine = try XCTUnwrap(player.engineForTesting)
        let node = try XCTUnwrap(player.playerNodeForTesting)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        XCTAssertEqual(try engine.renderOffline(128, to: output), .success)
        XCTAssertLessThan(try XCTUnwrap(player.renderPosition(of: node)).renderedFrames, 33_600)
        XCTAssertFalse(player.hasPendingAudio, "premise: no Swift buffer remains; the pending audio is already scheduled")
        XCTAssertTrue(player.hasOutstandingOutput)
        XCTAssertEqual(holdCounters?.begin.value, 1)
        let releasesBeforeDone = try XCTUnwrap(holdCounters?.end.value) // Admission also reports an absent predecessor.
        let priorDrain = coalesceBeforeDone ? player.finishWithStopBinding() : nil
        producerRelease.signal()
        let result = await turn.value
        XCTAssertEqual(result.outcome, .completed)
        if let priorDrain {
            XCTAssertEqual(player.currentDrainEpoch, priorDrain.requestEpoch + 1,
                           "premise: done allocated a distinct request coalesced on the pending drain")
        }
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 0,
                       "done must not resume host playback over the queued response tail")
        XCTAssertEqual(holdCounters?.end.value, releasesBeforeDone, "done must retain its existing grace playback hold")
        let deadline = Date().addingTimeInterval(2)
        while (player.renderPosition(of: node)?.renderedFrames ?? 0) < 33_600 && Date() < deadline {
            XCTAssertEqual(try engine.renderOffline(1_024, to: output), .success)
        }
        do {
            try await waitUntil("the actual owned stop releases the hold") {
                playback.calls.filter { $0 == .resume }.count == 1 && holdCounters?.end.value == releasesBeforeDone + 1
            }
        } catch {
            XCTFail("the notifiable physical stop did not release the retained hold: \(error)")
        }
        if let priorDrain {
            XCTAssertEqual(player.confirmedStopEpochForTesting, priorDrain.stopEpoch,
                           "the superseded done request must not be relabelled as a physical stop")
        }
    }

    /// THIRD UTTERANCE OVER A FINISHED TURN'S AUDIO TAIL.
    ///
    /// Turn N completes with answer audio still scheduled, so its socket is finished. Utterance 2
    /// is admitted as N+1 (N left no `activeTurn`, so it is not a barge-in) and parks in the
    /// quiescence wait on N's tail. Utterance 3 then arrives the way the service delivers it:
    /// `emitBargeIn` first, and its own `routeToCloud` when nothing was interrupted.
    ///
    /// Everything is measured at the wire and the executor, never through `activeResultSocket`.
    private struct ThirdUtteranceOutcome {
        var emitted: String?
        var thirdOutcome: CloudRouteOutcome?
        var nPlusOneOutcome: CloudRouteOutcome?
        var nPlusOneFrames: [String] = []
        var allFrames: [String] = []
        var thirdAuthFrames: [String] = []
        var seeks = 0
        var log = ""
        var stopConfirmedAfterTail = false
    }

    @MainActor
    private func exerciseThirdUtteranceOverAFinishedTurnsTail(thirdUtterance: Bool) async throws -> ThirdUtteranceOutcome {
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        CloudAudioPlayer.configureEngineForTesting = { engine in
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        }
        addTeardownBlock {
            CloudAudioPlayer.configureEngineForTesting = nil
            CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        }
        let producerRelease = DispatchSemaphore(value: 0)
        // NINE received frames now: seven binary PCM messages, then `connected`, then `done`.
        // The park counts RECEIVED frames, so adding the admission frame moves the boundary:
        // leaving it at eight parked the producer on `connected` itself, before the terminal
        // the turn must read, and the case hung rather than failing.
        blockProducerAfterFrames = (9, producerRelease)
        nextTurnFixture = Self.doneOnlyFixture
        nextTurnAudioPayloads = (0..<7).map { _ in Data(repeating: 0x11, count: 4_800 * 2) }
        playback.setPlaying(true)
        mapper.playbackSecondsForReference = [1130.0: 1200.0, 1500.0: 1600.0]
        let sink = makeSink()
        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)
        player.emittedPCMReference = reference
        player.echoReferenceHandoff = handoff
        addTeardownBlock { @MainActor in
            producerRelease.signal()
            player.openPhysicalStopGateForTesting()
            let stop = player.cancel()
            _ = await player.awaitActualStop(after: stop)
            withExtendedLifetime(handoff) {}
            withExtendedLifetime(sink) {}
        }

        // Turn N: admitted (`connected`), then done, with its answer audio still scheduled. The
        // acknowledgement is what makes N's conversation resumable, so the report it leaves behind
        // describes history the server actually settled — without it utterance 3 opens a fresh
        // conversation and correctly drops the report.
        nextTurnFixture = "event: connected\ndata: {\"codec\":\"pcm_s16le@24k\"}\n\n" + Self.doneOnlyFixture
        let turnN = Task {
            await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: .wakeWord, utteranceId: "u-n")
        }
        try await waitUntil("N's audio reached the real player", timeout: 3) {
            reference.streamIndex == 22_400 && player.bufferedFrameCountForTesting == 0
        }
        XCTAssertTrue(player.hasOutstandingOutput, "premise: N's audio is still outstanding")
        let nTask = try XCTUnwrap(capturedTask, "premise: N's socket")
        producerRelease.signal()
        let nResult = await turnN.value
        XCTAssertEqual(nResult.outcome, .completed, "premise: N completed")

        // Utterance 2: admitted as N+1, parked on a held stop of N's tail. It carries an action.
        let seekFixture = { (positionMs: Int) in
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":\(positionMs)}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        }
        nextTurnFixture = seekFixture(1_130_000)
        player.armPhysicalStopGateForTesting(allow: 0)
        let successor = Task {
            await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-n1")
        }
        try await waitUntil("N+1 is admitted and waiting on a held stop", timeout: 3) {
            sink.activeTurnIsCancelledForTesting == false && player.physicalStopGateArrivalsForTesting >= 1
        }
        // N+1's client exists (it is built at admission) but must have sent nothing yet.
        let nPlusOneTask = try XCTUnwrap(capturedTask, "premise: N+1's socket")
        XCTAssertFalse(nPlusOneTask === nTask, "premise: N+1 has its own socket")
        XCTAssertTrue(nPlusOneTask.sentTextFrames.isEmpty, "premise: N+1 has not reached the wire")

        let stopBefore = player.confirmedStopEpoch()
        let before = await FileLog.shared.logFileAsString()
        var outcome = ThirdUtteranceOutcome()
        var third: Task<CloudRouteResult, Never>?
        if thirdUtterance {
            outcome.emitted = await sink.emitBargeIn(
                request: "third", utteranceId: "u-n2", origin: cloudTestOrigin,
                selection: CloudConversationSelection.followUp
            )
            if outcome.emitted == nil {
                // Nothing was interrupted, so the service routes the utterance itself.
                nextTurnFixture = seekFixture(1_500_000)
                third = Task {
                    await sink.routeToCloud(request: "third", tier: .free, context: sampleContext(),
                                            origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-n2")
                }
            }
        }
        player.openPhysicalStopGateForTesting()
        let nPlusOne = await successor.value
        outcome.nPlusOneOutcome = nPlusOne.outcome
        if let third { outcome.thirdOutcome = await third.value.outcome }
        outcome.nPlusOneFrames = nPlusOneTask.sentTextFrames
        var thirdFrames: [String] = []
        if let latest = capturedTask, latest !== nPlusOneTask, latest !== nTask { thirdFrames = latest.sentTextFrames }
        outcome.allFrames = nTask.sentTextFrames + nPlusOneTask.sentTextFrames + thirdFrames
        outcome.thirdAuthFrames = thirdFrames.filter { $0.contains("\"authenticate\"") }
        outcome.seeks = playback.calls.filter { if case .seekTo = $0 { return true } else { return false } }.count
        outcome.log = String((await FileLog.shared.logFileAsString()).dropFirst(before.count))
        outcome.stopConfirmedAfterTail = player.confirmedStopEpoch() > stopBefore
        return outcome
    }

    /// A turn that received audio and then ended in an error sheds its buffer: its record must say
    /// frames arrived AND a clear happened, so an absent first-audible is attributable. The normal
    /// turn's counts are asserted in `testASuccessorOverAFinishedTurnsTailPlaysItsOwnAudio`.
    @MainActor
    func testLatencyRecordCountsFramesAndTheClearForATurnThatEndsInAnError() async throws {
        let id = "u-cleared-\(UUID().uuidString)"
        nextTurnAudioPayloads = (0..<3).map { _ in Data(repeating: 0x33, count: 4_800 * 2) }
        nextTurnFixture =
            """
            event: error
            data: {"code":"provider_error","message":"upstream failed"}

            """
        let sink = makeSink()
        _ = await sink.routeToCloud(request: "hi", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: id)
        var line = ""
        for _ in 0..<40 {
            line = (await FileLog.shared.logFileAsString()).split(separator: "\n")
                .first { $0.contains("cloudTurnLatency") && $0.contains("request_id=\(id) ") }
                .map(String.init) ?? ""
            if !line.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(line.contains("outcome=error"), line)
        XCTAssertTrue(line.contains("audio_frames=3"), "the three frames arrived: \(line)")
        XCTAssertTrue(line.contains("buffer_cleared=1"), "the error shed the buffer once: \(line)")
    }

    /// A clear issued by someone else between this turn's last frame and its terminal belongs to
    /// the turn's window: it is exactly the late clear of an answer's frames that the record
    /// exists to expose. Asserted for both terminals the stream can end on.
    @MainActor
    private func exerciseAClearBetweenTheLastFrameAndTheTerminal(terminal: String) async throws -> String {
        let id = "u-between-\(UUID().uuidString)"
        let release = DispatchSemaphore(value: 0)
        nextTurnAudioPayloads = (0..<3).map { _ in Data(repeating: 0x33, count: 4_800 * 2) }
        blockProducerAfterFrames = (4, release) // three binary frames, then park before the terminal
        nextTurnFixture = terminal
        let sink = makeSink()
        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        addTeardownBlock { release.signal() }
        let turn = Task {
            await sink.routeToCloud(request: "hi", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: id)
        }
        try await waitUntil("the three frames reached the player", timeout: 3) {
            player.framesEnqueuedForTesting >= 3
        }
        // Another actor clears the player after this turn's last frame and before its terminal.
        _ = player.cancel()
        release.signal()
        _ = await turn.value
        var line = ""
        for _ in 0..<40 {
            line = (await FileLog.shared.logFileAsString()).split(separator: "\n")
                .first { $0.contains("cloudTurnLatency") && $0.contains("request_id=\(id) ") }
                .map(String.init) ?? ""
            if !line.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return line
    }

    @MainActor
    func testAClearBetweenTheLastFrameAndDoneIsInTheTurnsCount() async throws {
        let line = try await exerciseAClearBetweenTheLastFrameAndTheTerminal(terminal: Self.doneOnlyFixture)
        XCTAssertTrue(line.contains("outcome=done"), line)
        XCTAssertTrue(line.contains("audio_frames=3 buffer_cleared=1"), line)
    }

    @MainActor
    func testAClearBetweenTheLastFrameAndAnErrorIsInTheTurnsCount() async throws {
        let line = try await exerciseAClearBetweenTheLastFrameAndTheTerminal(
            terminal: """
            event: error
            data: {"code":"provider_error","message":"upstream failed"}

            """
        )
        XCTAssertTrue(line.contains("outcome=error"), line)
        // The error's own cancel adds one more clear (it sheds whatever the turn still holds).
        XCTAssertTrue(line.contains("audio_frames=3 buffer_cleared=2"), line)
    }

    /// The counts stop at the turn's own last touch of the player. The error terminal waits
    /// (bounded) for the stop it requested, and a successor can enqueue on the same player during
    /// that wait: its frames must not be counted as this turn's.
    @MainActor
    func testLatencyRecordDoesNotCountASuccessorsFramesEnqueuedDuringTheTerminalsStopWait() async throws {
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        CloudAudioPlayer.configureEngineForTesting = { engine in
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        }
        addTeardownBlock {
            CloudAudioPlayer.configureEngineForTesting = nil
            CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        }
        let id = "u-wait-\(UUID().uuidString)"
        nextTurnAudioPayloads = (0..<3).map { _ in Data(repeating: 0x33, count: 4_800 * 2) }
        nextTurnFixture =
            """
            event: error
            data: {"code":"provider_error","message":"upstream failed"}

            """
        let sink = makeSink()
        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        player.armPhysicalStopGateForTesting(allow: 0)
        addTeardownBlock { @MainActor in player.openPhysicalStopGateForTesting() }
        let turn = Task {
            await sink.routeToCloud(request: "hi", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: id)
        }
        try await waitUntil("the error terminal is waiting on its stop", timeout: 3) {
            player.physicalStopGateArrivalsForTesting >= 1
        }
        // A successor's audio lands on the same player while this turn still waits.
        for _ in 0..<4 { player.enqueue(CloudAudioFrame(data: Data(repeating: 0x44, count: 4_800 * 2))) }
        player.openPhysicalStopGateForTesting()
        _ = await turn.value
        var line = ""
        for _ in 0..<40 {
            line = (await FileLog.shared.logFileAsString()).split(separator: "\n")
                .first { $0.contains("cloudTurnLatency") && $0.contains("request_id=\(id) ") }
                .map(String.init) ?? ""
            if !line.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(line.contains("audio_frames=3 "), "the successor's four frames are not this turn's: \(line)")
        XCTAssertTrue(line.contains("buffer_cleared=1"), line)
    }

    /// A SUCCESSOR ADMITTED OVER A FINISHED TURN'S AUDIO TAIL MUST PLAY ITS OWN ANSWER.
    ///
    /// Observed on a device: turn N ended `done` with its answer still playing, the next utterance
    /// was admitted as N+1 (retiring N's tail, then waiting for its stop), and the worker sent
    /// N+1 about 2.5 s of audio and a normal `done`, yet the player never scheduled a buffer for
    /// it. Asserted at the player: every frame N+1 receives must be enqueued, and the first one
    /// must start a new scheduling boundary.
    @MainActor
    func testASuccessorOverAFinishedTurnsTailPlaysItsOwnAudio() async throws {
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        CloudAudioPlayer.configureEngineForTesting = { engine in
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        }
        addTeardownBlock {
            CloudAudioPlayer.configureEngineForTesting = nil
            CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        }
        let producerRelease = DispatchSemaphore(value: 0)
        blockProducerAfterFrames = (8, producerRelease)
        nextTurnFixture = Self.doneOnlyFixture
        nextTurnAudioPayloads = (0..<7).map { _ in Data(repeating: 0x11, count: 4_800 * 2) }
        playback.setPlaying(true)
        let sink = makeSink()
        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)
        player.emittedPCMReference = reference
        player.echoReferenceHandoff = handoff
        addTeardownBlock { @MainActor in
            producerRelease.signal()
            player.openPhysicalStopGateForTesting()
            let stop = player.cancel()
            _ = await player.awaitActualStop(after: stop)
            withExtendedLifetime(handoff) {}
            withExtendedLifetime(sink) {}
        }

        let turnN = Task {
            await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: .wakeWord, utteranceId: "u-n")
        }
        try await waitUntil("N's audio reached the real player", timeout: 3) {
            reference.streamIndex == 22_400 && player.bufferedFrameCountForTesting == 0
        }
        XCTAssertTrue(player.hasOutstandingOutput, "premise: N's audio is still outstanding")
        producerRelease.signal()
        let nResult = await turnN.value
        XCTAssertEqual(nResult.outcome, .completed, "premise: N completed")
        XCTAssertTrue(player.hasOutstandingOutput, "premise: N's tail is still outstanding when N+1 arrives")

        // N+1: its own answer, delivered whole, with no parked producer.
        blockProducerAfterFrames = nil
        nextTurnFixture = Self.doneOnlyFixture
        nextTurnAudioPayloads = (0..<7).map { _ in Data(repeating: 0x22, count: 4_800 * 2) }
        let enqueuedBefore = player.framesEnqueuedForTesting
        let boundariesBefore = player.schedulingBoundaryCount
        let successorId = "u-successor-\(UUID().uuidString)"
        let successor = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(),
                                                origin: cloudTestOrigin, selection: .followUp, utteranceId: successorId)
        XCTAssertEqual(successor.outcome, .completed, "N+1 completes")
        XCTAssertEqual(player.framesEnqueuedForTesting - enqueuedBefore, 7,
                       "every audio frame N+1 receives must reach the player")
        // Offline manual rendering can stall well past a few seconds under load on a shared
        // Mac; the budget is deliberately generous and the condition is the event itself,
        // never an elapsed wait.
        try await waitUntil("N+1's audio is scheduled", timeout: 20) {
            player.schedulingBoundaryCount > boundariesBefore
        }
        // The record says the same thing the player does: a normal turn reports its frames and no clear.
        // BARRIER on the line itself, not a fixed poll that falls through to a count assertion:
        // under load on a shared Mac the record can take longer than any chosen interval to be
        // written, and an empty line must fail as "never written", not as wrong counts.
        var line = ""
        let logStart = Date()
        for _ in 0..<400 {
            line = (await FileLog.shared.logFileAsString()).split(separator: "\n")
                .first { $0.contains("cloudTurnLatency") && $0.contains("request_id=\(successorId) ") }
                .map(String.init) ?? ""
            if !line.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(line.isEmpty,
                       "log line never written after \(String(format: "%.1f", Date().timeIntervalSince(logStart))) s: cloudTurnLatency request_id=\(successorId)")
        XCTAssertTrue(line.contains("audio_frames=7 buffer_cleared=0"), "normal turn counts: \(line)")
    }

    /// A PREDECESSOR'S STOP THAT IS STILL UNCONFIRMED CANNOT DELETE THE SUCCESSOR'S AUDIO.
    ///
    /// N ended `done` with its audio outstanding, so N+1 is admitted through the retire-then-wait
    /// path: N+1 receives its frames only AFTER that wait confirms N's stop, which is why N's stop
    /// can no longer be outstanding when they arrive — the retire wait is the admission barrier.
    /// The break this catches: any path that lets N+1's frames reach the player while N's stop is
    /// still unconfirmed (or drops them outright) fails the premise or frame-count assertions
    /// below.
    ///
    /// The release is gated on PROOF the retire was reached, never on the client's existence: the
    /// client is built at admission, ~180 lines BEFORE the retire cancel, so a new captured task
    /// alone says nothing about the wait. Two measured facts gate it instead — the retire cancel
    /// was requested (`cancelRequestCountForTesting` grew), and the runner's physical stop for it
    /// has run and its notification is HELD in the box. Only then is the capture uninstalled and
    /// the held confirmation delivered.
    ///
    /// Falsified two ways: delivering the held confirmation early (while the stop is still parked
    /// at the armed gate) advances the epoch and enqueues all 7 successor frames while the wait
    /// should still be holding them; and an admission that skips the retire wait leaves the cancel
    /// count unchanged, so the gate barrier itself fails.
    @MainActor
    func testASuccessorsAudioIsNeverLostToAPredecessorsStop() async throws {
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        addTeardownBlock {
            CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        }
        let producerRelease = DispatchSemaphore(value: 0)
        blockProducerAfterFrames = (8, producerRelease)
        nextTurnFixture = Self.doneOnlyFixture
        nextTurnAudioPayloads = (0..<7).map { _ in Data(repeating: 0x11, count: 4_800 * 2) }
        playback.setPlaying(true)
        let sink = makeSink()
        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        addTeardownBlock { @MainActor in
            producerRelease.signal()
            player.openPhysicalStopGateForTesting()
            player.setCapturedStopNotificationForTesting(nil)
            let stop = player.cancel()
            _ = await player.awaitActualStop(after: stop)
            withExtendedLifetime(sink) {}
        }
        let turnN = Task {
            await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: .wakeWord, utteranceId: "u-n")
        }
        try await waitUntil("N's audio reached the player", timeout: 3) {
            player.framesEnqueuedForTesting == 7
        }
        producerRelease.signal()
        let nResult = await turnN.value
        XCTAssertEqual(nResult.outcome, .completed, "premise: N completed")
        XCTAssertTrue(player.hasOutstandingOutput, "premise: N's tail is still outstanding when N+1 arrives")

        blockProducerAfterFrames = nil
        nextTurnFixture = Self.doneOnlyFixture
        nextTurnAudioPayloads = (0..<7).map { _ in Data(repeating: 0x22, count: 4_800 * 2) }
        // Hold N's drain at the claim seam so its terminal stop cannot run before N+1's retire
        // cancel lands: the cancel then OWNS the single physical stop (coalesced accounting), and
        // that stop is parked at the armed gate. The confirmation that admits N+1 is withheld in
        // the box; N's engine stop is real, only its delivery is held.
        final class StopDeliveryBox: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [(epoch: Int, deliver: () -> Void)] = []
            func store(_ epoch: Int, _ d: @escaping () -> Void) { lock.lock(); deliveries.append((epoch, d)); lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return deliveries.count }
            func deliverAll() { lock.lock(); let all = deliveries; deliveries = []; lock.unlock(); all.forEach { $0.deliver() } }
        }
        let stopBox = StopDeliveryBox()
        let claimRelease = DispatchSemaphore(value: 0)
        player.claimRelease = claimRelease
        player.setCapturedStopNotificationForTesting { epoch, deliver in stopBox.store(epoch, deliver) }
        let confirmedBefore = player.confirmedStopEpoch()
        let enqueuedBefore = player.framesEnqueuedForTesting
        let cancelsBefore = player.cancelRequestCountForTesting
        let boundariesBefore = player.schedulingBoundaryCount
        let nTask = capturedTask
        let successor = Task {
            await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: .followUp,
                                    utteranceId: "u-successor-\(UUID().uuidString)")
        }
        // PROOF 1: the retire cancel was requested. An admission that skips the retire wait never
        // requests it, so this barrier fails rather than the test passing without the barrier.
        try await waitUntil("N+1's retire cancel was requested", timeout: 3) {
            player.cancelRequestCountForTesting > cancelsBefore
        }
        XCTAssertEqual(player.confirmedStopEpoch(), confirmedBefore,
                       "premise: N's stop is still unconfirmed when the retire cancel lands")
        // Let the claimed drain proceed: its physical stop IS the retire cancel's stop, and it
        // parks at the armed gate (allow 0) instead of confirming.
        player.armPhysicalStopGateForTesting(allow: 0)
        claimRelease.signal()
        // PROOF 2: the physical stop reached the armed gate and parked.
        try await waitUntil("the retire's physical stop parked at the gate", timeout: 3) {
            player.physicalStopGateArrivalsForTesting >= 1
        }
        // Release the park: the engine stop runs and its notification is captured, not delivered.
        player.openPhysicalStopGateForTesting()
        // PROOF 3: the stop's confirmation is genuinely HELD — the box owns a delivery for an
        // epoch at or after the retire's, and nothing has confirmed it yet.
        try await waitUntil("the retire stop's confirmation is held in the box", timeout: 3) {
            stopBox.count >= 1
        }
        XCTAssertEqual(player.confirmedStopEpoch(), confirmedBefore,
                       "premise: N's stop is still unconfirmed while N+1 waits")
        XCTAssertEqual(player.framesEnqueuedForTesting, enqueuedBefore,
                       "no successor audio may be enqueued before the retire wait confirms N's stop")
        XCTAssertNotNil(capturedTask)
        XCTAssertFalse(capturedTask === nTask, "premise: N+1 has its own socket")
        XCTAssertTrue(capturedTask?.sentTextFrames.isEmpty == true,
                      "premise: N+1 has not reached the wire while N's confirmation is withheld")
        // Uninstall the capture first so N+1's OWN drain stop delivers normally, then deliver
        // N's withheld confirmation: the retire wait resolves and N+1 admits its own audio.
        player.setCapturedStopNotificationForTesting(nil)
        stopBox.deliverAll()
        let successorResult = await successor.value
        XCTAssertEqual(successorResult.outcome, .completed, "N+1 completes")
        XCTAssertGreaterThan(player.confirmedStopEpoch(), confirmedBefore,
                             "N's stop was confirmed")
        XCTAssertEqual(player.framesEnqueuedForTesting - enqueuedBefore, 7,
                       "every audio frame N+1 receives must reach the player")
        // Offline manual rendering can stall well past a few seconds under load on a shared
        // Mac; the budget is deliberately generous and the condition is the event itself,
        // never an elapsed wait.
        try await waitUntil("N+1's audio is scheduled", timeout: 20) {
            player.schedulingBoundaryCount > boundariesBefore
        }
        player.claimRelease = nil
    }

    /// POSITIVE CONTROL: with no third utterance, N+1 reaches the wire, its action executes once
    /// and nothing is refused. Without this the assertions below could be measuring a fixture
    /// that never executes or always refuses.
    @MainActor
    func testControlNPlusOneRunsWithoutAThirdUtterance() async throws {
        let measured = try await exerciseThirdUtteranceOverAFinishedTurnsTail(thirdUtterance: false)
        XCTAssertEqual(measured.nPlusOneOutcome, .completed)
        XCTAssertEqual(measured.seeks, 1, "control: N+1's action reaches the executor exactly once")
        XCTAssertFalse(measured.log.contains("rejected: the interrupt was already sent"), "control: nothing interrupted N+1")
    }

    /// NEWEST WINS: utterance 3 submits, N+1 is superseded before it reaches the wire, nothing is
    /// interrupted, and N's tail stops.
    @MainActor
    func testAThirdUtteranceOverAFinishedTurnsTailSupersedesTheWaitingSuccessor() async throws {
        let m = try await exerciseThirdUtteranceOverAFinishedTurnsTail(thirdUtterance: true)
        // 1. Utterance 3 reaches the wire: one auth frame on a new socket, not refused.
        XCTAssertNil(m.emitted, "a finished turn is not an interrupt target, so utterance 3 is not claimed")
        XCTAssertEqual(m.thirdAuthFrames.count, 1, "utterance 3 sends exactly one authenticate frame; frames=\(m.allFrames)")
        XCTAssertTrue(m.thirdAuthFrames.first?.contains("u-n2") ?? false, "that frame carries utterance 3's request id")
        XCTAssertEqual(m.thirdOutcome, .completed, "utterance 3 is not refused")
        // 2. N+1 never reaches the wire, ends superseded (not refused), and its action never executes.
        XCTAssertTrue(m.nPlusOneFrames.isEmpty, "N+1 never sends a frame")
        XCTAssertFalse(m.allFrames.contains { $0.contains("u-n1") }, "no frame carries N+1's request id")
        XCTAssertNotEqual(m.nPlusOneOutcome, .refused)
        XCTAssertNotEqual(m.nPlusOneOutcome, .completed, "N+1 is superseded, not completed")
        // 3. No interrupt is sent or attempted: N is finished.
        XCTAssertFalse(m.allFrames.contains { $0.contains("\"interrupt\"") }, "no interrupt frame on any socket")
        XCTAssertFalse(m.log.contains("interrupt undelivered"), "no interrupt is attempted")
        // 4. N's audio stops.
        XCTAssertTrue(m.stopConfirmedAfterTail, "N's tail is physically stopped")
        // 5. N's buffered-playback report rides utterance 3's authentication frame exactly once.
        let reports = m.allFrames.filter { $0.contains("\"interrupts\"") }
        XCTAssertEqual(reports.count, 1, "the report is sent exactly once")
        XCTAssertEqual(reports.first, m.thirdAuthFrames.first, "and on utterance 3's authenticate frame")
        XCTAssertTrue(reports.first?.contains("\"request_id\":\"u-n\"") ?? false, "naming N")
        // 6. Utterance 3's own action executes once, with effects open.
        XCTAssertEqual(m.seeks, 1, "utterance 3's action reaches the executor once and N+1's never")
        XCTAssertFalse(m.log.contains("rejected: the interrupt was already sent"), "no effects were closed")
    }

    /// OWNER-CANCEL STOP ORDERING (review dee03708/fa03b7f9, reworked for 14f66b72): a
    /// superseded turn with NO pending playback owes no await — it returns earlyClose, never
    /// restores (the successor owns the window), and the successor's single resume is intact.
    ///
    /// NO PREDECESSOR PLAYBACK TO RETIRE (task #7): A is parked at ADMISSION through the hold gate,
    /// so it never produced a frame and owns no output to retire. The property this case names —
    /// that the superseded turn owes no stop AWAIT — is asserted by A returning promptly once
    /// released, not by counting cancels: A's own truncation path may legitimately request its own
    /// stop. (A live predecessor would be a barge-in and would park B on its acknowledgement; the
    /// barge-in shape is covered by `testBargeInWaitsForPredecessorTerminalThenSubmits`.)
    func testSupersededTurnAwaitsItsOwnedStopAndLeavesTheReleaseToTheSuccessor() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"slow"}

            """
        let gate = holdNextTurn()
        let sink = makeSink()
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-49") }
        try await Task.sleep(nanoseconds: 200_000_000)
        // B supersedes A FIRST: A's cleanup must observe the transfer (still no stop is
        // requested — A owned no pending playback at supersession).
        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-50")
        // A is parked until here, so "A returns promptly once released" is what proves it owes no
        // await: nothing is outstanding for it to wait on.
        gate.release()
        let aReturned = try await timeoutProbe(slow, nanoseconds: 2_000_000_000)
        XCTAssertTrue(aReturned, "the superseded turn returns promptly: it owes no stop await")
        let aResult = await slow.value
        // A's socket was retired while it was parked mid-turn, so its own transport surfaces
        // `connection_lost` — the ONE outcome this shape produces, asserted rather than loosened.
        // Either way it is not a completion, which is what "superseded" means here.
        XCTAssertEqual(aResult.outcome, .failed(code: "connection_lost"),
                       "the superseded turn ends on its retired socket, never as a completion")
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1,
                       "only the winning turn restores playback")
        // The property this case names is that the superseded turn owes NO AWAIT — verified above
        // by its prompt return, not by an instant counter read. A's own truncation path may still
        // request ITS stop (A produced no audio here, and the successor's retire covers only what
        // the predecessor owned); what must never happen is A blocking on one.
    }

    /// ADMISSION AWAITS PREDECESSOR QUIESCENCE (review 14f66b72): B's retire only QUEUES a
    /// runner stop, so B must not admit (or even build) its stream until A's stop is CONFIRMED.
    /// A's producer is parked after its audio frames (all enqueued, A still running); B
    /// supersedes; with the retire stop's confirmation withheld, B has neither built its client
    /// nor completed; delivery releases B, which then completes normally.
    func testSuccessorAdmissionAwaitsPredecessorQuiescence() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"slow"}

            """
        // A IS SUPERSEDED WHILE STILL ACTIVE, so its script has NO `done` (spec 43ab05d3): this
        // case is about a turn that never finished, and a script that served `done` would describe
        // the different case where A had already concluded. A's producer is parked and only B
        // ever ends it.
        // A's frames are held IN THE BUFFER (drain-hold parks dequeue without consuming), so
        // "A owns playback output" is deterministic, not a race against the engine.
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        let aGate = DispatchSemaphore(value: 0)
        self.blockProducerAfterFrames = (40, aGate)
        let sink = makeSink()
        hookedSink = sink
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            func deliverAll() { lock.lock(); let all = deliveries; deliveries = []; lock.unlock(); all.forEach { $0() } }
        }
        let box = Box()
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(true) }
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-51") }
        var aEnqueued = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aEnqueued = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aEnqueued, "A's audio is enqueued while its producer is parked")
        let aTask = capturedTask
        // Withhold stop-notification delivery: B's admission await suspends on the retire stop.
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"fast"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        // A is a LIVE predecessor, so B is a barge-in and parks on A's acknowledgement. A's
        // producer is parked after its frames and cannot produce the terminal itself, so the stub
        // answers the interrupt the way the server does (see `interruptTerminalFrame`). Configured
        // BEFORE B dispatches: the interrupt can be sent the instant B runs, and an answer installed
        // afterwards would miss it. A then reaches its terminal while B keeps waiting on the RETIRE
        // STOP, which is the suspension this case is about.
        // A has no terminal of its own to send, so the stub answers B's interrupt the way the
        // server does: with the frame that ends the interrupted turn. That is also what a parked
        // predecessor needs in order to be released — and it is configured BEFORE B dispatches so
        // the answer cannot be missed.
        aTask?.interruptTerminalFrame = Self.interruptedDoneTextFrame
        let fast = Task { await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-52") }
        // EXPLICIT BARRIER on the retire itself, not an instant read after dispatching B: B runs
        // on another task, so reading the buffer immediately afterwards says nothing about whether
        // the retire has happened yet. The clear counter is bumped INSIDE `cancel()`, so waiting
        // for it proves the retire landed — and only then is "nothing buffered" about the property
        // this case names.
        var retired = false
        for _ in 0..<600 {
            let clears: Int = await MainActor.run { sink.audioPlayerForTesting?.bufferClearCount ?? 0 }
            if clears >= 1 { retired = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(retired, "premise: B's retire cancel actually ran")
        // A's frames were retired synchronously; nothing new is admitted while B waits.
        let pendingNow: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? true }
        XCTAssertFalse(pendingNow, "no successor audio is buffered while A's stop is unconfirmed")
        // Release the drain hold FIRST: the runner is parked inside the hold and must process
        // the queued retire stop (and issue its notification) before anything can confirm.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        try await Task.sleep(nanoseconds: 150_000_000)
        // Deliver the retire stop: B proceeds, admits ITS OWN audio, and completes. The capture
        // hook is uninstalled first so B's OWN drain stop delivers normally.
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            box.deliverAll()
        }
        let bResult = await fast.value
        XCTAssertEqual(bResult.outcome, .completed, "B completes once the predecessor is quiescent")
        // A's producer was released above, so it has reached its terminal; its cleanup awaits the
        // CAPTURED retire identity (already confirmed) and returns without touching B's window.
        let aResult = await slow.value
        XCTAssertEqual(aResult.outcome, .earlyClose, "the superseded turn is an incomplete turn")
        // B's deferring drain restores asynchronously — bounded poll, never an instant assert.
        var resumes = 0
        for _ in 0..<60 {
            resumes = playback.calls.filter { $0 == .resume }.count
            if resumes == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(resumes, 1, "only B restores the window")
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            sink.audioPlayerForTesting?.setDrainHoldForTesting(false)
        }
    }

    /// SUCCESS-PATH OWNERSHIP (review 4fc59e2c / spec dbf71ccf): the scoped rollback defer must
    /// fire ONLY on early return. On a successful A-retire, B keeps its active ownership,
    /// playback ownership, and admitted hold through its live stream and drain — snapshot at
    /// B's first frame (exactly one hold end: A's transfer) and after B completes (two).
    func testSuccessfulRetireKeepsBOwnershipAndHoldThroughStreamAndDrain() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"A"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        holdCounters = (AtomicInteger(), AtomicInteger())
        let sink = makeSink(withHoldCounters: true)
        hookedSink = sink
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return deliveries.count }
            func deliverAll() { lock.lock(); let all = deliveries; deliveries = []; lock.unlock(); all.forEach { $0() } }
        }
        let box = Box()
        await MainActor.run {
            sink.audioPlayerForTesting?.setDrainHoldForTesting(true)
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-53") }
        var aBuffered = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aBuffered = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aBuffered, "A's audio is buffered under the drain hold")
        // B supersedes successfully: retire A, confirm, then stream.
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"B"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        firstFrameActionForNextBuild = { [holdCounters] in
            // Snapshot BEFORE B's done: exactly one end (A's at the transfer) must have
            // fired — an early-return-style rollback here would be a second.
            Self.successSnapshot.bump(holdCounters?.end.value ?? -1)
        }
        let b = Task { await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-54") }
        // Confirm A's stop so B is admitted for real: the runner must leave its park to
        // process the retire stop, then the withheld notification is delivered.
        try await Task.sleep(nanoseconds: 120_000_000)
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        // BARRIER on the retire stop's notification being captured — not a fixed sleep. Under
        // load on a shared Mac the runner can take longer than any chosen interval to reach the
        // stop, and a premature deliverAll() would leave the retire stop undelivered: B then
        // waits out its quiescence bounds and rolls back instead of completing.
        var retireCaptured = false
        for _ in 0..<600 {
            if box.count > 0 { retireCaptured = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(retireCaptured, "the retire stop's notification was captured before delivery")
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            box.deliverAll()
        }
        let bResult = await b.value
        XCTAssertEqual(bResult.outcome, .completed, "B completes after a successful retire")
        _ = await a.value
        // A's own end may legitimately fire once its drain stop confirms — the invariant is
        // that B's OWN hold ends exactly once AFTER its first frame: n2 == n1 + 1. Under the
        // rollback bug the scoped defer ends B's hold at admission and the real end no-ops
        // (heldPlaybackToken already cleared), so n2 == n1 there.
        let endsAtFirstFrame = Self.successSnapshot.value
        XCTAssertGreaterThanOrEqual(endsAtFirstFrame, 1, "A's transfer end fired")
        var ends = 0
        for _ in 0..<60 {
            ends = holdCounters?.end.value ?? -1
            if ends == endsAtFirstFrame + 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(ends, endsAtFirstFrame + 1,
                       "B's own hold ends at its real drain/stop, exactly once after its first frame")
    }
    /// Hold-end count captured at B's first frame (success-path ownership control).
    static let successSnapshot = SnapshotInt()

    final class SnapshotInt: @unchecked Sendable {
        private let lock = NSLock(); private var v = 0
        func bump(_ n: Int) { lock.lock(); v = n; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return v }
    }

    /// ROLLBACK HOLD RESPONSIBILITY (review 8eb9fb44): when a TIMED-OUT admission rolls back,
    /// it is still the active owner and its hold is the LAST live one over the predecessor's
    /// still-unconfirmed output — ending it at rollback would re-arm the allowance mid-flight.
    /// The hold must stay live until the retire stop CONFIRMS, and end exactly then.
    /// (A superseded-while-waiting rollback needs no such handling: the successor's atomic
    /// transfer already moved the hold before the rollback runs.)
    func testRolledBackAdmissionKeepsItsHoldLiveUntilTheRetireStopConfirms() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"A"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        holdCounters = (AtomicInteger(), AtomicInteger())
        let sink = makeSink(withHoldCounters: true)
        hookedSink = sink
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            func deliverAll() { lock.lock(); let all = deliveries; deliveries = []; lock.unlock(); all.forEach { $0() } }
        }
        let box = Box()
        await MainActor.run {
            sink.audioPlayerForTesting?.setDrainHoldForTesting(true)
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-55") }
        var aBuffered = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aBuffered = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aBuffered, "A's audio is buffered under the drain hold")
        // B supersedes A; the retire stop stays unconfirmed (runner parked, notification
        // withheld) until B's admission bounds expire and B rolls back.
        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let b = Task { await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-56") }
        let bResult = await b.value
        XCTAssertEqual(bResult.outcome, .earlyClose, "B's admission times out and rolls back")
        // THE PIN: exactly two ends have fired — the nil-predecessor transfer at A's admission
        // and A's transfer at B's admission. B's OWN hold (the last live one) is NOT ended
        // while its retire stop is unconfirmed (the bug ended it at rollback: 3).
        XCTAssertEqual(holdCounters?.end.value ?? -1, 2,
                       "the rolled-back admission's hold is NOT ended while its retire stop is unconfirmed")
        // Precondition: the host was auto-paused for the cloud audio and B inherited that
        // responsibility at the transfer.
        let pauses = playback.calls.filter { $0 == .pause }.count
        XCTAssertGreaterThanOrEqual(pauses, 1, "the host was auto-paused for A's cloud audio")
        // Confirm E1: B's release responsibility fires exactly here.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        try await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            box.deliverAll()
        }
        var ends = 0
        var resumesAfterConfirm = 0
        for _ in 0..<100 {
            ends = holdCounters?.end.value ?? -1
            resumesAfterConfirm = playback.calls.filter { $0 == .resume }.count
            if ends == 3 && resumesAfterConfirm == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(ends, 3, "B's hold ends exactly when the retire stop confirms")
        XCTAssertEqual(resumesAfterConfirm, 1,
                       "exactly ONE host resume: the confirmation restores the inherited pause")
    }

    /// CLAIMED-DRAIN CANCEL (review 0585959a): a cancel landing while A's drain is claimed
    /// must be CONSUMED by the drain's own physical stop — no second physical stop may follow
    /// it. Premise: A's drain is claimed and parked; the gate parks the SUBSEQUENT stop. After
    /// the first confirmation delivers and B admits with its audio buffered, no queued stop
    /// may exist (the bug left the cancel's flag set: a second stop pending over live B
    /// output). Releasing the gate then lets B's own drain finish normally.
    func testCancelDuringClaimedDrainIsConsumedByTheDrainsPhysicalStop() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"A"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        let sink = makeSink()
        hookedSink = sink
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var epochs: [Int] = []
            func record(_ epoch: Int) { lock.lock(); epochs.append(epoch); lock.unlock() }
            var snapshot: [Int] { lock.lock(); defer { lock.unlock() }; return epochs }
        }
        let box = Box()
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { epoch, deliver in
                box.record(epoch)
                deliver() // auto-confirm: the first stop's confirmation reaches B immediately
            }
        }
        // Premise: the runner is parked INSIDE the claimed drain (claim seam) when B's cancel
        // lands. The seam is installed BEFORE A runs so the drain claim cannot be missed.
        let claimReached = DispatchSemaphore(value: 0)
        let claimRelease = DispatchSemaphore(value: 0)
        await MainActor.run {
            sink.audioPlayerForTesting?.claimReached = claimReached
            sink.audioPlayerForTesting?.claimRelease = claimRelease
        }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-57") }
        let aResult = await a.value
        XCTAssertEqual(aResult.outcome, .completed, "A completed; its drain is claimed")
        // The runner is parked inside the CLAIMED drain.
        XCTAssertEqual(claimReached.wait(timeout: .now() + 2), .success,
                       "the runner reached the claimed drain")
        // B supersedes: the retire cancel lands while A's drain is claimed/parked.
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"B"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        let b = Task { await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-58") }
        try await Task.sleep(nanoseconds: 120_000_000)
        // Park the SUBSEQUENT stop: the first physical stop (the drain end, which IS the
        // cancel's stop) passes; any later stop parks.
        await MainActor.run { sink.audioPlayerForTesting?.armPhysicalStopGateForTesting(allow: 1) }
        claimRelease.signal()
        // THE PIN: exactly TWO physical stops carry confirmations — the drain end (which IS
        // the cancel's stop) and B's own done-drain. The defect ran a THIRD stop (the
        // unconsumed cancel flag) between them.
        await MainActor.run { sink.audioPlayerForTesting?.openPhysicalStopGateForTesting() }
        let bResult = await b.value
        XCTAssertEqual(bResult.outcome, .completed, "B completes once its own drain stop passes the gate")
        _ = await a.value
        // Epochs must be STRICTLY INCREASING: the defect re-processed the unconsumed cancel
        // flag as a second stop with the SAME identity (a duplicate), shedding whatever a
        // successor had admitted on the first confirmation.
        // The gate may still be parking the defect's second stop (or B's own drain): open it
        // and let every pending physical stop settle before reading the log.
        try await Task.sleep(nanoseconds: 300_000_000)
        let recorded = box.snapshot
        let strictlyIncreasing = zip(recorded, recorded.dropFirst()).allSatisfy { $0 < $1 }
        XCTAssertTrue(strictlyIncreasing && recorded.count >= 1,
                      "no stop identity is confirmed twice (got \(recorded))")
        // (No resume pin here: with no engine ever started, transient restore is a no-op by
        // design — the discriminator is the stop-identity log above.)
    }

    /// PHYSICAL STOP OPERATION HELD (spec ea755ba1; reviewer 6453dfaa/3d4f5619/76215282):
    /// the stop NOTIFICATION is not the physical contract — the actual `stopEngine()` operation
    /// is, so this control parks the REAL stop and asserts the ordering that falls out of it.
    ///
    /// WHAT THIS CONTROL MEASURES (scoped honestly, per reviewer 76215282/2542e2/wording and
    /// spec 43f8f003):
    ///   * the stop operation reaches the armed gate and genuinely PARKS (`allow == 0`, arrival
    ///     recorded) while B's supersede is in flight;
    ///   * while parked: no stop is CONFIRMED, B does not COMPLETE, and the host is not resumed;
    ///   * on release the park ends by RELEASE, not bound expiry (`outcome == .released`);
    ///   * the parked stop confirms the retire identity (2), and exactly one host resume follows.
    ///
    /// ORDERING (precise): B is launched while the drain is HELD, so B's retire cancel lands
    /// first; the hold is then released and the real stop parks. B is therefore already in flight
    /// when the stop parks — this control does not claim "park first, then B", only that the
    /// parked stop's settlement is not preceded by confirmation/completion/resume.
    ///
    /// WHAT IT DOES NOT MEASURE, and does not claim: that B SCHEDULED or RENDERED audio. In this
    /// test host with the drain hold set before the turn, the runner parks inside the claimed
    /// drain and frames stay BUFFERED and UNSCHEDULED (`buffered=40 scheduled=0` measured). A
    /// live-engine/B-output proof is a device integration check (`physical-output-device-check.md`);
    /// the confirmation identity here is evidence of the STOP, not of audio.
    func testSuccessorAdmissionWaitsForThePhysicalEngineStopItself() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"A"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        let sink = makeSink()
        hookedSink = sink
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.lock(); value = true; lock.unlock() }
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let bDone = Flag()
        playback.setPlaying(true)
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        // Arm the gate FIRST: the very next physical stop parks.
        await MainActor.run { sink.audioPlayerForTesting?.armPhysicalStopGateForTesting(allow: 0) }
        // A's drain hold keeps the runner away from A's stop until the cancel has landed.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(true) }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-59") }
        var aBuffered = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aBuffered = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aBuffered, "premise: A's audio is buffered")
        let aResult = await a.value
        XCTAssertEqual(aResult.outcome, .completed, "A completed; its drain stop is queued")
        // B supersedes while the drain is still HELD: the retire cancel lands first.
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"B"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        let b = Task {
            let result = await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-60")
            bDone.set()
            return result
        }
        var cancelled = false
        for _ in 0..<600 {
            let count: Int = await MainActor.run { sink.audioPlayerForTesting?.cancelRequestCountForTesting ?? 0 }
            if count >= 1 { cancelled = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(cancelled, "B's retire cancel landed while the drain is still held")
        // Release the hold: the runner reaches the claimed drain and its REAL stop parks.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        var parked = false
        var bDoneEarly = false
        for _ in 0..<600 {
            let arrivals: Int = await MainActor.run { sink.audioPlayerForTesting?.physicalStopGateArrivalsForTesting ?? 0 }
            if arrivals >= 1 { parked = true; break }
            if bDone.isSet { bDoneEarly = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let arrivalsAtPark: Int = await MainActor.run { sink.audioPlayerForTesting?.physicalStopGateArrivalsForTesting ?? -1 }
        let outcomeAtPark: String = await MainActor.run {
            switch sink.audioPlayerForTesting?.physicalStopGateOutcomeForTesting {
            case .released: return "released"
            case .timedOut: return "timedOut"
            case .admitted: return "admitted"
            default: return "unarmed"
            }
        }
        XCTAssertTrue(parked, "premise: the REAL stop operation reached the armed gate and parked (no B completion first: \(bDoneEarly)) [arrivals=\(arrivalsAtPark) outcome=\(outcomeAtPark)]")
        let outcomeParked: String = await MainActor.run {
            switch sink.audioPlayerForTesting?.physicalStopGateOutcomeForTesting {
            case .released: return "released"
            case .timedOut: return "timedOut"
            case .admitted: return "admitted"
            default: return "unarmed"
            }
        }
        // Bounded: the runner clears the gate flag AFTER the stop body completes (it needs the
        // lock back), so the outcome may still read `.unarmed` at the instant of arrival.
        // The parked premise IS the arrival: the gate is still armed and parking (allow == 0).
        // The outcome only becomes `released` once the wait ENDS, so it is asserted AFTER the
        // release below — asserting it here would read a value that cannot exist yet.
        let allowWhileParked: Int = await MainActor.run { sink.audioPlayerForTesting?.physicalStopGateAllowProbeForTesting ?? -99 }
        XCTAssertEqual(allowWhileParked, 0, "the gate is still armed and parking (allow=\(allowWhileParked))")
        // While parked, NOTHING is admitted or confirmed. (No scheduled-frame reading here: the
        // runner-owned scheduling counter has no synchronized publish path, so a cross-thread
        // read would be unsynchronized evidence — see reviewer 76215282.)
        let confirmedParked: Int = await MainActor.run { sink.audioPlayerForTesting?.confirmedStopEpoch() ?? -1 }
        let resumesParked: Int = await MainActor.run { playback.calls.filter { $0 == .resume }.count }
        XCTAssertLessThan(confirmedParked, 2, "no stop is confirmed before the physical stop ran")
        XCTAssertFalse(bDone.isSet, "B has not completed while the stop is parked")
        XCTAssertEqual(resumesParked, 0, "no host resume precedes the physical stop")
        // Release: the physical stop RUNS and confirms the retire cancel's identity.
        await MainActor.run { sink.audioPlayerForTesting?.openPhysicalStopGateForTesting() }
        let bResult = await b.value
        XCTAssertEqual(bResult.outcome, .completed, "B completes once its own drain settles")
        let confirmedFinal: Int = await MainActor.run { sink.audioPlayerForTesting?.confirmedStopEpoch() ?? -1 }
        XCTAssertEqual(confirmedFinal, 2, "the physical stop confirmed the retire cancel's identity (2); got \(confirmedFinal)")
        // Gate-exit cause (reviewer 6453dfaa): the park ended because the gate was RELEASED,
        // not because its bound expired and the runner proceeded anyway.
        let outcomeFinal: String = await MainActor.run {
            switch sink.audioPlayerForTesting?.physicalStopGateOutcomeForTesting {
            case .released: return "released"
            case .timedOut: return "timedOut"
            case .admitted: return "admitted"
            default: return "unarmed"
            }
        }
        XCTAssertEqual(outcomeFinal, "released", "the parked stop ended by release, not a bound expiry (outcome=\(outcomeFinal))")
        // EXACTLY ONE host resume, after the physical stop ran.
        var resumes = 0
        for _ in 0..<100 {
            resumes = await MainActor.run { playback.calls.filter { $0 == .resume }.count }
            if resumes >= 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(resumes, 1, "the host resumed exactly once, after the physical stop ran")
    }

    /// COALESCED STOP ACCOUNTING (review 4fc59e2c): cancel coalesces through the runner's
    /// flags — B and C's stops behind a parked runner share ONE processed stop/notification.
    /// Request-per-increment accounting would strand the counter positive and refuse every
    /// later admission; transition-only accounting settles to zero and D runs normally.
    func testCoalescedStopsSettleAndLaterAdmissionIsNotRefused() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"A"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        let sink = makeSink()
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            func deliverAll() { lock.lock(); let all = deliveries; deliveries = []; lock.unlock(); all.forEach { $0() } }
        }
        let box = Box()
        await MainActor.run {
            sink.audioPlayerForTesting?.setDrainHoldForTesting(true)
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-61") }
        var aBuffered = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aBuffered = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aBuffered, "A's audio is buffered under the drain hold")
        let plainDone =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnFixture = plainDone
        let b = Task { await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-62") }
        try await Task.sleep(nanoseconds: 80_000_000)
        self.nextTurnFixture = plainDone
        let c = Task { await sink.routeToCloud(request: "C", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-63") }
        try await Task.sleep(nanoseconds: 150_000_000)
        // Process the coalesced stop: ONE notification for B's and C's queued requests.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        try await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            box.deliverAll()
        }
        let cResult = await c.value
        let bResult = await b.value
        _ = await a.value
        XCTAssertEqual(bResult.outcome, .earlyClose, "B was superseded while waiting on the coalesced stop")
        XCTAssertEqual(cResult.outcome, .completed, "C completes once the coalesced stop confirms")
        // THE PIN: with per-request accounting the counter would still be positive here and
        // D would be refused; with transition-only accounting it settles and D runs.
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"D"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (80..<90).map { Data([UInt8($0)]) }
        // Accounting settles eventually: wait (bounded) for the counter to drain before D.
        var settled = false
        for _ in 0..<200 {
            let q: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasQueuedStop ?? true }
            if !q { settled = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(settled, "stop accounting settles after the coalesced pair")
        let cancelsBeforeD: Int = await MainActor.run { sink.audioPlayerForTesting?.cancelRequestCountForTesting ?? -1 }
        let d = Task { await sink.routeToCloud(request: "D", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-64") }
        let dResult = await d.value
        XCTAssertEqual(dResult.outcome, .completed, "a later admission is not refused by stranded stop accounting")
        // Settled accounting: D's admission sees nothing outstanding and issues NO stop request.
        // Per-request increment accounting strands the counter positive, so D would spuriously
        // retire (an extra stop identity shift) even with nothing to stop.
        let cancelsAfterD: Int = await MainActor.run { sink.audioPlayerForTesting?.cancelRequestCountForTesting ?? -1 }
        XCTAssertEqual(cancelsAfterD, cancelsBeforeD, "D's admission issues no stop request when nothing is outstanding")
    }

    /// QUEUED-STOP VISIBILITY (review 05d27ddb): a stop that is queued but not yet processed is
    /// invisible to buffer/isPlaying — a THIRD turn (C) superseding B must still wait, because
    /// the queued stop would shed anything C admits. With A buffered and the runner parked, B
    /// and C both queue stops; neither may complete before the runner processes them.
    func testThirdTurnAdmissionWaitsForTheQueuedStopsItCannotSee() async throws {
        await MainActor.run { } // keep symmetry with sibling controls
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"slow"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = [Data([0])] // one frame: below the play threshold — the
        // engine never starts (isPlaying false), which is exactly the cleared-buffer window.
        let sink = makeSink()
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            func deliverAll() { lock.lock(); let all = deliveries; deliveries = []; lock.unlock(); all.forEach { $0() } }
        }
        let box = Box()
        await MainActor.run {
            sink.audioPlayerForTesting?.setDrainHoldForTesting(true)
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-65") }
        var aBuffered = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aBuffered = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aBuffered, "A's audio is buffered under the drain hold")
        let aPlaying: Bool = await MainActor.run { sink.audioPlayerForTesting?.isPlaying ?? true }
        XCTAssertFalse(aPlaying, "A's engine never started: the window is buffer-only")
        // B supersedes A (retire E1 queued behind the parked runner), then C supersedes B
        // (retire E2): with the queued stop invisible to buffer/isPlaying, only the explicit
        // queued-stop signal can hold C.
        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let b = Task { await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-66") }
        try await Task.sleep(nanoseconds: 60_000_000)
        // B is suspended on E1's confirmation BEFORE C even starts.
        let bFinishedEarly = try await timeoutProbe(b, nanoseconds: 200_000_000)
        XCTAssertFalse(bFinishedEarly, "B is suspended on E1's confirmation")
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"C"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        let c = Task { await sink.routeToCloud(request: "C", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-67") }
        // C may not complete while the queued stops are unprocessed — and in particular not
        // while the runner is still parked (a C that "completed" here admitted over the stop
        // the runner has not yet processed).
        let cFinishedParked = try await timeoutProbe(c, nanoseconds: 800_000_000)
        XCTAssertFalse(cFinishedParked,
                       "C is suspended: the queued stop it cannot see holds its admission while the runner is parked")
        // And C RETIRED before admitting: E1's clear (A's leftovers) plus C's own retire clear.
        // A C that skipped its wait (queued stop invisible) never performs the second clear.
        let clears: Int = await MainActor.run { sink.audioPlayerForTesting?.bufferClearCount ?? 0 }
        XCTAssertEqual(clears, 2, "C retired B's queued-stop-window output before admitting")
        // Process the queue: the runner handles E1 then E2; confirmations withheld until now.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        try await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            box.deliverAll()
        }
        let cResult = await c.value
        XCTAssertEqual(cResult.outcome, .completed, "C completes once the queued stops are processed")
        let bResult = await b.value
        XCTAssertEqual(bResult.outcome, .earlyClose, "B was superseded while waiting and is an incomplete turn")
        var resumes = 0
        for _ in 0..<60 {
            resumes = playback.calls.filter { $0 == .resume }.count
            if resumes == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(resumes, 1, "only C restores the window")
    }

    /// NETWORK-COMPLETED PREDECESSOR (review ea755ba1/05d27ddb): A finished its NETWORK work
    /// (done returned, deferral recorded) with playback still pending under the drain hold. B's
    /// admission must still await A's quiescence — playback ownership outlives the Task.
    func testAdmissionAwaitsQuiescenceOfANetworkCompletedPredecessor() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"A"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        let sink = makeSink()
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            func deliverAll() { lock.lock(); let all = deliveries; deliveries = []; lock.unlock(); all.forEach { $0() } }
            func pendingCount() -> Int { lock.lock(); defer { lock.unlock() }; return deliveries.count }
        }
        let box = Box()
        await MainActor.run {
            sink.audioPlayerForTesting?.setDrainHoldForTesting(true)
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-68") }
        let aResult = await a.value
        XCTAssertEqual(aResult.outcome, .completed, "A completed its network work")
        let aPending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
        XCTAssertTrue(aPending, "A's playback is still pending (network-complete ≠ quiescent)")
        // B supersedes the network-COMPLETED A: its admission must await A's quiescence.
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"B"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        let b = Task { await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-69") }
        let bFinishedEarly = try await timeoutProbe(b, nanoseconds: 200_000_000)
        XCTAssertFalse(bFinishedEarly, "B is suspended: A's pending playback must quiesce first")
        // MIXED FLAGS (spec d2561f9b): A's finish (drain) was queued FIRST and B's retire-
        // cancel SECOND — the one processed stop must be the CANONICAL end: no second drain
        // stop may follow B's admission. From here every stop is recorded and delivered
        // immediately, so the total count over the rest of the test is exact.
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
                deliver()
            }
            sink.audioPlayerForTesting?.setDrainHoldForTesting(false)
        }
        let bResult = await b.value
        XCTAssertEqual(bResult.outcome, .completed, "B completes once A is quiescent")
        _ = await a.value
        // THE PIN: the coalesced stop (A's finish + B's retire share ONE processing) plus at
        // most B's own done-drain — two recorded stops. Under the bug a SECOND drain stop ran
        // right after the cancel's stop: three. (B's done-drain exists only if frames were
        // still pending at its done; either way the bug's extra stop is not among them.)
        let recordedStops = box.pendingCount()
        XCTAssertTrue(recordedStops == 1 || recordedStops == 2,
                      "the cancel's stop canonically supersedes the queued drain: no extra physical stop (got \(recordedStops))")
        var resumes = 0
        for _ in 0..<60 {
            resumes = playback.calls.filter { $0 == .resume }.count
            if resumes == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(resumes, 1, "only B restores the window")
        let pending = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? true }
        XCTAssertFalse(pending, "no audio survives")
    }

    /// CAPTURED RETIRE IDENTITY (review 14f66b72): the superseded turn's cleanup awaits the
    /// identity captured for ITS token at the transfer — never the shared latest counter. A
    /// test-injected stop (E2) moves the counter AFTER B's admission; A must still resolve on
    /// E1's confirmation and return while E2's confirmation is still withheld.
    func testSupersededCleanupAwaitsItsCapturedRetireIdentity() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"slow"}

            """
        // A IS SUPERSEDED WHILE STILL ACTIVE, so its script has NO `done` (spec 43ab05d3): this
        // case is about a turn that never finished, and a script that served `done` would describe
        // the different case where A had already concluded. A's producer is parked and only B
        // ever ends it.
        // A's frames are held IN THE BUFFER (drain-hold parks dequeue without consuming), so
        // "A owns playback output" is deterministic, not a race against the engine.
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        let aGate = DispatchSemaphore(value: 0)
        self.blockProducerAfterFrames = (40, aGate)
        let sink = makeSink()
        hookedSink = sink
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            func deliverOldest() { lock.lock(); let d = deliveries.isEmpty ? nil : deliveries.removeFirst(); lock.unlock(); d?() }
            func pendingCount() -> Int { lock.lock(); let c = deliveries.count; lock.unlock(); return c }
        }
        let box = Box()
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(true) }
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-70") }
        var aEnqueued = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aEnqueued = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aEnqueued, "A's audio is enqueued while its producer is parked")
        let aTaskForInterrupt = capturedTask
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"fast"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        // B's FIRST-frame hook injects a test stop (E2) — only once B is actually admitted,
        // i.e. strictly after E1's confirmation.
        self.cancelPlayerOnFirstFrameForNextBuild = true
        // A is live, so B is a barge-in and parks on A's acknowledgement. A's producer is parked
        // after its frames and cannot produce that terminal itself, so the stub answers B's
        // interrupt the way the server does (see `interruptTerminalFrame`). A's terminal is what
        // releases B's wait; the retire stop this case is about is still the next thing B owes.
        aTaskForInterrupt?.interruptTerminalFrame = Self.interruptedDoneTextFrame
        let fast = Task { await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-71") }
        // A's PRODUCER is parked after its frames (a hard stop inside its receive loop), so it can
        // never consume a terminal while parked — and B, as a barge-in, parks on exactly that
        // terminal. Release it now so A reaches its own `done`; B is then suspended on the RETIRE
        // STOP this case is about rather than on an acknowledgement it can never receive.
        aGate.signal()
        try await Task.sleep(nanoseconds: 200_000_000)
        // Release the drain hold so the runner processes the retire stop, then deliver E1:
        // B is admitted and its FIRST-frame hook injects E2.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        try await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run { box.deliverOldest() }
        let bResult = await fast.value
        XCTAssertEqual(bResult.outcome, .completed, "B completes after E1 quiescence")
        // Withheld confirmations exist (E2 among them — B's own drain may also be captured);
        // E2 is definitely not confirmed yet. Bounded wait: notification capture hops to main,
        // so under load it may land a beat after B's frames flow.
        var withheldAny = false
        for _ in 0..<200 {
            if box.pendingCount() >= 1 { withheldAny = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(withheldAny, "the injected stop's confirmation is withheld")
        // A's producer was released above; its cleanup reads the CAPTURED identity (E1, already
        // confirmed) and returns WITHOUT waiting on E2.
        let aFinished = try await timeoutProbe(slow, nanoseconds: 2_000_000_000)
        XCTAssertTrue(aFinished, "A resolved on its CAPTURED identity, not the moved counter")
        let aResult = await slow.value
        XCTAssertEqual(aResult.outcome, .earlyClose, "the superseded turn is an incomplete turn")
        XCTAssertGreaterThanOrEqual(box.pendingCount(), 1,
                                    "A resolved without needing the later stop's confirmation")
        // Cleanup: deliver E2 and release the drain hold so nothing stays stranded.
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            sink.audioPlayerForTesting?.setDrainHoldForTesting(false)
            box.deliverOldest()
        }
    }

    func testSupersededTurnDoesNotRestoreButRecordsInterrupted() async throws {
        // Turn A: held open, so it is still running when B starts. Its fixture is
        // bound to A's client explicitly, because B's turn is built in between.
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"slow"}

            """
        // A is given AUDIO, not just text: this case is about who RESTORES the host window, and a
        // turn with no output never acquires playback ownership in the first place — the assertion
        // would then pass because nothing could have restored anything.
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        let gate = DispatchSemaphore(value: 0)
        self.blockProducerAfterFrames = (40, gate)
        let sink = makeSink()
        // Hold the DEQUEUE, not just the producer: with a live engine these tiny frames are
        // consumed as fast as they arrive, so A would own nothing by the time B starts and the
        // restore assertion would be about a turn that never had output.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(true) }
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-72") }
        // Parked mid-stream with its audio enqueued, so A owns the window when B arrives.
        var ownsWindow = false
        for _ in 0..<600 {
            ownsWindow = await MainActor.run {
                guard let player = sink.audioPlayerForTesting else { return false }
                // The park fires BEFORE the last frame is delivered, so the enqueued count is one
                // short of the payload count; what matters is that output is outstanding.
                return player.framesEnqueuedForTesting > 0 && player.hasOutstandingOutput
            }
            if ownsWindow { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(ownsWindow, "premise: A owns the window with its answer still buffered")
        XCTAssertTrue(playback.calls.contains(.pause), "the first turn paused playback")
        // This case NEEDS A still running when B starts (it is about what a SUPERSEDED turn
        // restores and records), so it keeps the barge-in shape deliberately — unlike its
        // siblings, which finish the predecessor first. B interrupts A, and the stub answers that
        // interrupt the way the server does: with the terminal of an INTERRUPTED turn. A therefore
        // discards its answer without draining and must NOT restore the window; only B may.
        let aTask = try XCTUnwrap(capturedTask, "A's socket was captured")
        aTask.interruptTerminalFrame = Self.interruptedDoneTextFrame
        self.nextTurnFixture =
            """
            event: done
            data: {"outcome":"completed","usage":{"input_tokens":1,"output_tokens":1}}

            """
        let b = Task { await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-73") }
        // Open A's producer so its parked receive can reach the interrupt terminal, and let the
        // runner move again so each turn's stop can confirm.
        gate.signal()
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        _ = await b.value
        _ = await slow.value

        // Exactly one resume: the superseding turn's. A must not restore after B.
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1, "only the winning turn restores playback")
        // Both turns report — an interrupted turn is not silent in analytics — but they must say
        // DIFFERENT things: the loser `interrupted`, the winner `done`. A count alone would pass
        // with two completions recorded, which is exactly the conflation this case exists to catch.
        let outcomes = analytics.events.filter { $0.0 == "cloud_assistant_turn" }
            .compactMap { $0.1["outcome"] as? String }
        XCTAssertEqual(outcomes.sorted(), ["done", "interrupted"],
                       "the superseded turn reports interrupted and the winner reports done")
        // The losing turn's socket is closed rather than left running: the client
        // closes the socket on every exit path, and a superseded turn that kept it
        // open would bill for a stream nobody reads and hold the connection until
        // the server's own idle timeout.
        // A's OWN frame is its prepared/auth frame, addressed to A's request id. A second frame
        // on this socket is the SUCCESSOR's interrupt for A, which is correct barge-in traffic and
        // not A submitting anything new — so the assertion is about WHO the frames belong to, not
        // about a bare count that predates the interruption lifecycle.
        let authFrame = try XCTUnwrap(
            aTask.sentAuthFrame, "the superseded turn sent its auth frame"
        )
        XCTAssertEqual(
            authFrame["request_id"] as? String, "u-72",
            "the held turn's own frame is the turn these assertions are about"
        )
        // Asserted on the producer, not on consumer completion: only the client
        // setting `cancelled` proves the losing turn's socket was closed, and a
        // bounded wait turns an intermittent miss into a deterministic failure on
        // that same property rather than making the ordering guaranteed.
        let closed = await aTask.awaitCancellation()
        XCTAssertTrue(closed, "the superseded turn's socket is closed")
    }

    func testSupersededTurnDoesNotExecuteLateActions() async {
        // Turn A: its action arrives only after it has already been superseded.
        self.nextTurnFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":100000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let gate = holdNextTurn()
        let sink = makeSink()
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-74") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        gate.release()

        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-75")
        _ = await slow.value

        let seeks = playback.calls.filter { if case .seekTo = $0 { return true }; return false }
        XCTAssertTrue(seeks.isEmpty, "a superseded turn must not execute actions that arrive after it lost the turn")
    }

    /// A barge-in must not leave the podcast paused. Turn A pauses for its hold
    /// and is superseded before it finishes; B inherits that hold and is the
    /// turn that releases it. With a test double whose `isPlaying` ignored
    /// `pause()` this could not fail — which is why the double now models
    /// playback state faithfully.
    func testBargeInResumesPlaybackHeldByTheSupersededTurn() async {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"slow"}

            """
        let gate = holdNextTurn()
        let sink = makeSink()
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-76") }

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(playback.calls.contains(.pause), "the first turn paused playback")
        XCTAssertFalse(playback.isPlaying, "the hold is in effect while the first turn runs")
        gate.release()

        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-77")
        _ = await slow.value

        XCTAssertTrue(playback.isPlaying, "the winning turn must release the hold taken for the superseded one")
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1, "exactly one resume")
    }

    /// The turn held open by `holdNextTurn()`, so a case can assert on the socket
    /// the superseding turn closed. A stub that answers instantly cannot express
    /// "A is still in flight when B starts", which is the whole premise of these
    /// cases; the socket is also where "the losing turn was closed, not left
    /// running" is observable (`StubWebSocketTask.cancelled`).
    private var heldTurn: (task: StubWebSocketTask, gate: Gate)?

    /// BOUNDED completion probe (review 9fc2603e): an INDEPENDENT completion flag set by a
    /// detached watcher; the probe polls the flag under a bound and NEVER awaits the watched
    /// task's value inside the group (a cancelled probe must not hang on the underlying wait).
    private func timeoutProbe<T>(_ task: Task<T, Never>, nanoseconds: UInt64) async throws -> Bool {
        let flag = ProbeCompletionFlag()
        let watcher = Task.detached { _ = await task.value; flag.set() }
        var completed = false
        var elapsed: UInt64 = 0
        while elapsed < nanoseconds {
            if flag.isSet { completed = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
            elapsed += 50_000_000
        }
        if !completed { watcher.cancel() } // benign leak: the watcher cannot free the underlying wait
        return completed
    }

    /// Bounded wait for the successor to have TAKEN its hold on the given predecessor. That is the
    /// observable instant of its interruption decision: the hold is recorded before the send, so a
    /// control can release a parked predecessor exactly after the decision and not before.
    private func waitForHeldFollowUp(
        _ state: CloudInterruptionState, requestId: String, utteranceId: String = "u-turn-b",
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let taken = await MainActor.run { state.interruptedRequestId(forHeldUtterance: utteranceId) == requestId }
            if taken { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return await MainActor.run { state.interruptedRequestId(forHeldUtterance: utteranceId) == requestId }
    }

    private func holdNextTurn() -> Gate {
        let gate = Gate()
        pendingHeldGate = gate
        return gate
    }

    private var pendingHeldGate: Gate?
    /// Consumed by the next `makeSink()`: the fixture that sink's turn carries.
    /// Explicit because these cases run two turns at once and the shared
    /// `pendingFixture` handoff would let the second overwrite the first's.
    private var nextTurnFixture: String?

    /// OPT-IN binary audio for the next built turn, mirroring `nextTurnFixture`. Empty means the
    /// turn carries no audio, so every existing case is unaffected.
    private var nextTurnAudioPayloads: [Data] = []
    /// Producer-side park (review 14f66b72 controls): blocks the NEXT built client's producer
    /// after N frames — A's audio is enqueued while A is still running.
    private var blockProducerAfterFrames: (count: Int, semaphore: DispatchSemaphore)?
    /// Install a first-frame hook on the NEXT built client that cancels the player (a stop the
    /// test itself injects, to move the shared latest identity AFTER a captured retire).
    private var cancelPlayerOnFirstFrameForNextBuild = false
    private var injectedStopDone = false
    private var hookedSink: CloudRouteSink?
    /// Opt-in action on the NEXT built client's first frame (ownership-snapshot probes).
    private var firstFrameActionForNextBuild: (@Sendable () -> Void)?
    /// Opt-in hook on the NEXT built client, applied before its producer starts. Used to park the
    /// producer at the bind seam so a control can force the pre-authentication window.
    private var parkNextProducerAtBindSeam: ((CloudRouteClient) -> Void)?
    /// Opt-in park INSIDE the next built turn's authentication send — the lost-race arm, where the
    /// producer has already recorded its send as invoked.
    private var holdNextAuthenticationSend: (gate: Gate, entered: Promise<Void>)?
    /// Grace hold lifecycle counters for ownership controls.
    private var holdCounters: (begin: AtomicInteger, end: AtomicInteger)?

    /// Per-TOKEN ledger of the holds this sink took and ended. Shared begin/end counters cannot say
    /// WHICH turn leaked — two turns share them, and a later turn's cleanup credits the earlier one
    /// (reviewer + spec on E14). Identity is the token object, so a hold is attributable to the turn
    /// that took it.
    private final class HoldLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var taken: [ObjectIdentifier] = []
        private var ended: Set<ObjectIdentifier> = []
        private var endCounts: [ObjectIdentifier: Int] = [:]
        func take(_ token: GracePeriodSignal.PlaybackHoldToken) {
            lock.lock(); taken.append(ObjectIdentifier(token)); lock.unlock()
        }
        func end(_ token: GracePeriodSignal.PlaybackHoldToken) {
            lock.lock()
            let id = ObjectIdentifier(token)
            ended.insert(id)
            endCounts[id, default: 0] += 1
            lock.unlock()
        }
        /// Every token taken ended EXACTLY once — no leak, and no double release either.
        var unbalanced: String? {
            lock.lock(); defer { lock.unlock() }
            for (n, id) in taken.enumerated() {
                let count = endCounts[id] ?? 0
                if count != 1 { return "token #\(n) ended \(count) times, expected exactly 1" }
            }
            return nil
        }
        /// Tokens taken but never ended, in take order.
        var outstanding: Int {
            lock.lock(); defer { lock.unlock() }
            return taken.filter { !ended.contains($0) }.count
        }
        var lastTaken: ObjectIdentifier? { lock.lock(); defer { lock.unlock() }; return taken.last }
        var countTaken: Int { lock.lock(); defer { lock.unlock() }; return taken.count }
        func wasEnded(_ id: ObjectIdentifier) -> Bool {
            lock.lock(); defer { lock.unlock() }; return ended.contains(id)
        }
    }
    private var holdLedger: HoldLedger?
    /// When set, every begin after the first returns nil — the window refused this turn's hold.
    private var refuseHoldBeginsAfterFirst = false

    final class AtomicInteger: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Let the predecessor turn FINISH from the server, then return.
    ///
    /// Since the interruption lifecycle landed, a successor admitted while a predecessor's turn is
    /// still live is a BARGE-IN by contract: it sends `interrupt` and parks on that turn's
    /// ACKNOWLEDGEMENT — which only the predecessor's own terminal (`done`/`error`) settles. The
    /// supersede controls below park the predecessor's producer on purpose, so no terminal ever
    /// arrives and each of them would end on the 10 s bound while actually being about LOCAL
    /// supersession (stop ordering, retire identity, analytics, late actions). Marking the
    /// predecessor's RECORD terminal does not help: the acknowledgement lives on the turn token,
    /// not the record. So these cases let the predecessor complete first.
    ///
    /// Retunes the still-open stub's script to a `done` and opens the hold gate, then waits
    /// (bounded) for the turn to return. The case keeps whatever it captured before this — the
    /// socket, its frames, its playback — which is what its assertions are about.
    private func finishPredecessor(
        _ task: StubWebSocketTask, gate: Gate, turn: Task<CloudRouteResult, Never>, timeout: TimeInterval = 5
    ) async throws {
        task.replaceRemainingScript(textFrames: [Self.completedDoneTextFrame])
        gate.release()
        let finished = try await timeoutProbe(turn, nanoseconds: UInt64(timeout * 1_000_000_000))
        XCTAssertTrue(finished, "the predecessor did not reach its terminal within \(timeout)s")
    }

    /// AN UNDELIVERED INTERRUPT WITH NO TERMINAL IS TRANSPORT LOSS, NOT A NEW TURN.
    ///
    /// The contract (`docs/specs/cloud-assistant.md` → Interruption) allows the interrupting
    /// utterance to be submitted only after the interrupted turn's terminal acknowledgement, and
    /// says that when the transport is lost "no automatic replay occurs". So an `interrupt` that
    /// never reached the server, for a turn whose terminal the sink has NOT consumed, authorizes
    /// nothing: discard the held utterance, end locally, keep the pending report.
    ///
    /// THE STATE IS REACHABLE IN PRODUCTION, not only through this seam. The client registers a
    /// turn socket and sends its authentication frame from a DETACHED producer task, while the sink
    /// publishes its result binding on the main actor as soon as the route call returns. A close
    /// that lands after registration but before the terminal — a consumer abandoning the turn, or
    /// the transport going away — retires the registration while the sink's binding still names a
    /// live predecessor. A barge-in landing there gets `.undelivered` with no terminal consumed.
    /// Measured on a full-plan run: `interrupt undelivered: registration retired for turn u-turn-a`,
    /// followed by that utterance authenticating as an ordinary turn.
    ///
    /// This is the AUTH-SENT arm. Its sibling below covers the pre-registration window, where the
    /// correct disposition is the opposite one: abandon the predecessor before it authenticates and
    /// submit the interrupting utterance as a fresh turn.
    ///
    /// This control forces exactly that ordering — retire the registration through the production
    /// retirement path while the predecessor's terminal is still withheld — and asserts the WIRE:
    /// the interrupting utterance must never authenticate.
    func testUndeliveredInterruptWithNoTerminalSubmitsNothing() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        let gate = holdNextTurn()
        addTeardownBlock { gate.release() }
        let state = CloudInterruptionState()
        let sink = makeSink(interruptionState: state)

        // Turn A genuinely in flight: its receive is parked, so no terminal can arrive on its own.
        let prior = Task {
            await sink.routeToCloud(
                request: "prior question", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-turn-a"
            )
        }
        // Wait for the TRANSPORT's registration, not merely the sink's published binding: the
        // binding appears on the main actor before the detached producer registers anything.
        var registered = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let live = await MainActor.run(body: { () -> Bool in
                // `boundIdentity` is stamped BY registration, so requiring it observes the
                // transport rather than the sink's earlier binding publication.
                return sink.activeResultSocketForTesting?.boundIdentity != nil
            })
            if live { registered = true; break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(registered, "premise: turn A's transport must be REGISTERED before it is retired")
        let observedSocket = await MainActor.run { sink.activeResultSocketForTesting }
        let priorSocket = try XCTUnwrap(observedSocket)
        // The premise is the TRANSPORT's registration, not the sink's binding: the binding is
        // published on the main actor before the detached producer registers anything, so a
        // non-nil socket alone would let this case interrupt into a window where no registration
        // existed yet — a different scenario from the retirement it means to test. `boundIdentity`
        // is stamped BY registration, so requiring it already pins the stronger fact.
        let priorIdentity = try XCTUnwrap(priorSocket.boundIdentity)
        let priorTask = try XCTUnwrap(capturedTask)
        // A is UNSETTLED and un-interrupted: its terminal is withheld by the park, so no
        // acknowledgement of any kind has been recorded. That is what separates "the transport
        // went away mid-turn" from "the turn had already ended", and the disposition differs.
        XCTAssertFalse(priorTask.sentInterrupt, "premise: no interrupt has been sent yet")
        XCTAssertTrue(
            priorTask.sentTextFrames.contains { $0.contains("u-turn-a") },
            "premise: A HAS authenticated — this is the auth-sent arm, not the pre-registration one"
        )

        // RETIRE THE REGISTRATION exactly as a consumer close does. The sink's binding and token
        // are untouched, so its barge-in gate still sees a live predecessor — the production window.
        await MainActor.run {
            sink.resultClientForTesting?.retireSocketRegistrationForTesting(
                requestId: priorSocket.requestId, identity: priorIdentity
            )
        }

        let result = await sink.routeToCloud(
            request: "play the next one", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-turn-b"
        )

        // THE WIRE ASSERTION: B never authenticated. Reading the outcome alone cannot tell
        // "nothing was submitted" from "something was submitted and also failed".
        let bFrames = capturedTask?.sentTextFrames ?? []
        XCTAssertFalse(
            bFrames.contains { $0.contains("u-turn-b") },
            "an undelivered interrupt with no terminal acknowledgement must submit NOTHING; "
            + "measured frames=\(bFrames)"
        )
        XCTAssertNotEqual(result.outcome, .completed, "transport loss is never a completion")
        XCTAssertTrue(
            state.isSuppressed("u-turn-b"),
            "the utterance must be suppressed so a queued dispatch cannot reach the wire either"
        )
        XCTAssertNil(state.heldFollowUpForTesting, "the held follow-up must be dropped, not stranded")

        gate.release()
        _ = await prior.value
    }

    // MARK: - The grace hold on an interruption that ends locally

    /// A GRACE HOLD IS ENDED ONLY BY THE TURN THAT TOOK IT.
    ///
    /// `restoreTransientAudioState()` ends whatever is in `heldPlaybackToken`, and several callers
    /// admit themselves when `activeTurn == nil`. So a predecessor that finishes AFTER its successor
    /// took the hold ends the SUCCESSOR's hold: the window's expiry timer re-arms while the
    /// successor's answer is still playing, which is the early release the grace contract forbids.
    ///
    /// Ordering forced, not raced: A's terminal is withheld until B has taken its hold, then released.
    func testAPredecessorFinishingLateDoesNotEndItsSuccessorsHold() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        let gate = holdNextTurn()
        addTeardownBlock { gate.release() }
        let state = CloudInterruptionState()
        holdCounters = (AtomicInteger(), AtomicInteger())
        let ledger = HoldLedger()
        holdLedger = ledger
        addTeardownBlock { self.holdLedger = nil }
        // Long enough that B's own wait cannot expire and end its hold for an unrelated reason.
        let sink = makeSink(withHoldCounters: true, acknowledgementTimeout: 30, interruptionState: state)

        let prior = Task {
            await sink.routeToCloud(
                request: "prior question", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-owner-a"
            )
        }
        var registered = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let live = await MainActor.run { sink.activeResultSocketForTesting?.boundIdentity != nil }
            if live { registered = true; break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(registered, "premise: A's transport must be registered")

        // B dispatches and takes its OWN hold while A is still parked.
        self.nextTurnFixture = Self.doneOnlyFixture
        let bGate = Gate()
        pendingHeldGate = bGate
        addTeardownBlock { bGate.release() }
        let b = Task {
            await sink.routeToCloud(
                request: "play the next one", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-owner-b"
            )
        }
        try await waitUntil("B takes its own hold") { ledger.countTaken >= 2 }
        let bHold = try XCTUnwrap(ledger.lastTaken, "premise: B must have taken a hold of its own")
        XCTAssertFalse(ledger.wasEnded(bHold), "premise: B's hold is live before A finishes")

        // NOW let A finish. Its cleanup must not touch B's hold. Read the ledger BEFORE B is
        // allowed to settle, or B's own legitimate release would satisfy the assertion.
        gate.release()
        _ = await prior.value
        XCTAssertFalse(
            ledger.wasEnded(bHold),
            "A ended B's grace hold. The window's expiry re-arms while B's answer is still playing."
        )
        bGate.release()
        _ = await b.value
        // HANDOVER ACCOUNTING (reviewer): B's begin ends A's token at the atomic transfer, so across
        // the whole A→B sequence every token taken must be ended EXACTLY once — not merely "B balanced".
        XCTAssertNil(ledger.unbalanced, "hold accounting across A→B: \(ledger.unbalanced ?? "")")
    }

    /// A TURN WHOSE OWN BEGIN WAS REFUSED INHERITS THE CURRENT HOLD — AND MUST STILL END IT.
    ///
    /// `beginPlaybackHold` returns nil when the window is not live for that turn's generation, so a
    /// successor can admit while taking no hold of its own. The predecessor's token stays current.
    /// Nobody may then leave it unended: the predecessor's own release paths are ownership-gated and
    /// its drain record is overwritten by the successor's, so if the successor does not own the
    /// inherited hold, the live window keeps no expiry timer at all.
    ///
    /// Forced by construction: the second begin is refused, so B genuinely inherits A's token.
    func testASuccessorWhoseBeginWasRefusedStillEndsTheInheritedHold() async throws {
        // A takes the only hold there will be and is STILL IN FLIGHT: its terminal is withheld, so
        // it cannot settle and end its own hold before B inherits it. (Letting A finish first was
        // a false green — A's own terminal released the token and the case proved nothing;
        // measured.)
        self.nextTurnFixture = Self.doneOnlyFixture
        let state = CloudInterruptionState()
        holdCounters = (AtomicInteger(), AtomicInteger())
        let ledger = HoldLedger()
        holdLedger = ledger
        // The SECOND begin is refused — the window is not live for that turn's generation — so B
        // genuinely takes no hold of its own and must inherit A's.
        refuseHoldBeginsAfterFirst = true
        addTeardownBlock { self.holdLedger = nil; self.refuseHoldBeginsAfterFirst = false }
        let sink = makeSink(withHoldCounters: true, acknowledgementTimeout: 30, interruptionState: state)
        let gate = holdNextTurn()
        addTeardownBlock { gate.release() }
        let prior = Task {
            await sink.routeToCloud(
                request: "prior question", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-inherit-a"
            )
        }
        try await waitUntil("A takes its hold", timeout: 5) { ledger.countTaken >= 1 }
        let aHold = try XCTUnwrap(ledger.lastTaken, "premise: A must have taken a hold")
        XCTAssertFalse(ledger.wasEnded(aHold), "premise: A's hold is still live")
        // PRE-CLAIM the interruption emission: B's own claim then fails, so B runs as an ORDINARY
        // successor — no barge-in machinery, no acknowledgement race. This pins the mechanism this
        // case is about: hold inheritance at an ordinary supersede whose begin was refused.
        // (Without the pre-claim the barge-in path resolved differently under load: B was
        // suppressed as refused interruption work before it could inherit anything — measured in
        // suite order. A turn already past admission and still draining was a false green too: A's
        // own stop confirmation ended the hold first — measured.)
        XCTAssertTrue(
            state.claimInterruptEmission(forRequestId: "u-inherit-a"),
            "premise: the test pre-claims A's emission so B cannot barge in"
        )

        // B supersedes A while A's hold is live and unended, and B's own begin is REFUSED, so it
        // inherits A's token rather than taking its own. B still retires A's output, so its exit
        // path must end the hold it inherited — ownership follows responsibility, not acquisition.
        self.nextTurnFixture = Self.doneOnlyFixture
        let bResult = await sink.routeToCloud(
            request: "play the next one", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-inherit-b"
        )
        gate.release()
        _ = await prior.value
        XCTAssertEqual(bResult.outcome, .completed, "premise: B must run to its terminal")
        XCTAssertEqual(ledger.countTaken, 1, "premise: B's begin was refused, so it took no new hold")
        // THE ASSERTION: read before A can settle — B's exit must have ended the hold it took over.
        XCTAssertTrue(
            ledger.wasEnded(aHold),
            "the inherited hold was never ended by the turn that took it over: B took none of its "
            + "own and superseded A, so the live window keeps no expiry timer"
        )
        XCTAssertNil(ledger.unbalanced, "hold accounting: \(ledger.unbalanced ?? "")")
    }

    /// A DELAYED INTERRUPT CAN REACH A REGISTRATION THAT HAS ALREADY RETIRED.
    ///
    /// This is the OTHER side of the ordering the two cases above pin, and a real production
    /// scenario rather than something to exclude: the interrupt is slow, the predecessor's turn ends
    /// and closes its socket first, so the frame finds nothing live. Production must then let B run
    /// as an ORDINARY turn — and every hold taken must still be ended exactly once.
    ///
    /// Forced by construction: A's terminal is served and A fully returns BEFORE B dispatches, so
    /// there is no live predecessor to interrupt. No timing assumption either way.
    func testAnInterruptThatMissesItsPredecessorStillReleasesEveryHold() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        StubWebSocketTask.sendDelayNanoseconds = 20_000_000
        addTeardownBlock { StubWebSocketTask.sendDelayNanoseconds = nil }
        let state = CloudInterruptionState()
        holdCounters = (AtomicInteger(), AtomicInteger())
        let ledger = HoldLedger()
        holdLedger = ledger
        addTeardownBlock { self.holdLedger = nil }
        let sink = makeSink(withHoldCounters: true, acknowledgementTimeout: 30, interruptionState: state)

        // A runs to its terminal and RETURNS: its registration is retired by its own close.
        let aResult = await sink.routeToCloud(
            request: "prior question", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-missed-a"
        )
        XCTAssertEqual(aResult.outcome, .completed, "premise: A must have finished on its own")

        self.nextTurnFixture = Self.doneOnlyFixture
        let bResult = await sink.routeToCloud(
            request: "play the next one", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-missed-b"
        )
        XCTAssertEqual(
            bResult.outcome, .completed,
            "with no live predecessor there is nothing to interrupt: B is an ordinary turn"
        )
        XCTAssertNil(ledger.unbalanced, "hold accounting: \(ledger.unbalanced ?? "")")
    }

    /// AN INTERRUPTION THAT ENDS LOCALLY MUST RELEASE THE GRACE HOLD ITS TURN TOOK.
    ///
    /// Every admitted turn takes the window's playback hold BEFORE the interruption block, so a turn
    /// that ends in the refused or unacknowledged arm is certainly holding one. Those arms return
    /// without releasing it, while the undelivered arm beside them does — leaving the window with no
    /// expiry timer, so the grace period never ends on its own.
    ///
    /// The ordering matters and is forced here, not raced: the predecessor's terminal is withheld
    /// until the successor has dispatched and is waiting for its acknowledgement. A refusal arriving
    /// BEFORE that dispatch suppresses the successor at the service's admission gate instead, and
    /// the arm under test never runs — measured, and the reason an earlier version of this control
    /// passed without the fix.
    func testARefusedInterruptionReleasesTheGraceHoldItsTurnTook() async throws {
        try await checkLocalInterruptionEndReleasesGraceHold(refused: true)
    }

    /// The same obligation when no acknowledgement can ever arrive. Production hits this on a slow or
    /// lost interrupt acknowledgement — a bad network, not a race.
    func testAnUnacknowledgedInterruptionReleasesTheGraceHoldItsTurnTook() async throws {
        try await checkLocalInterruptionEndReleasesGraceHold(refused: false)
    }

    /// DETERMINISTIC red for the send-in-flight race: the interrupt send is asynchronous, and a
    /// terminal that lands while it is suspended (here: a refusal, delivered by the control while
    /// the send is parked INSIDE the stub's send) ends the predecessor's route and clears the
    /// sink's active turn. The successor must still end `.refused` and submit nothing, because it
    /// waits on the token it captured BEFORE the send — not on `activeTurn` read after it.
    /// Against the unfixed sink this case fails EVERY run: the post-send read saw no active turn,
    /// skipped the acknowledgement wait, and the successor dispatched as an ordinary turn.
    func testARefusalSettledWhileTheInterruptSendIsInFlightEndsTheSuccessorRefused() async throws {
        // Under load: every frame delayed, as in the sibling cases the ordering must survive.
        StubWebSocketTask.sendDelayNanoseconds = 20_000_000
        addTeardownBlock { StubWebSocketTask.sendDelayNanoseconds = nil }
        // A's OWN fixture carries the refusal; the gate withholds it until the control releases it.
        self.nextTurnFixture = """
            event: error
            data: {"code":"invalid_request","message":"interrupt does not reference the active turn"}

            """
        let gate = holdNextTurn()
        addTeardownBlock { gate.release() }
        let state = CloudInterruptionState()
        holdCounters = (AtomicInteger(), AtomicInteger())
        let ledger = HoldLedger()
        holdLedger = ledger
        addTeardownBlock { self.holdLedger = nil }
        let sink = makeSink(
            withHoldCounters: true,
            acknowledgementTimeout: 30,
            interruptionState: state
        )

        let prior = Task {
            await sink.routeToCloud(
                request: "prior question", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-grace-a"
            )
        }
        var registered = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let live = await MainActor.run { sink.activeResultSocketForTesting?.boundIdentity != nil }
            if live { registered = true; break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(registered, "premise: A's transport must be registered")
        let priorTask = try XCTUnwrap(capturedTask)
        // ORDER BY EVENT: A must be fully AUTHENTICATED before B claims — its producer has
        // reached its first receive (which the gate then parks). Without this, B's interrupt
        // raced A's authentication send and A counted as abandoned, never refused.
        try await waitUntil("A's producer is parked at its gated receive", timeout: 10) { priorTask.receiveEntered }
        XCTAssertFalse(priorTask.sentInterrupt, "premise: nothing interrupted yet")

        // HOLD THE INTERRUPT SEND IN FLIGHT: the predecessor's own stub parks the send after the
        // frame is recorded and its delivery is marked, so the refusal below settles while B's
        // send has not returned.
        let sendGate = Gate()
        let sendEntered = Promise<Void>()
        priorTask.holdInterruptSendUntilReleased(sendGate, entered: sendEntered)

        self.nextTurnFixture = Self.doneOnlyFixture
        let b = Task {
            await sink.routeToCloud(
                request: "play the next one", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-grace-b"
            )
        }
        try await waitUntil("B takes its own grace hold", timeout: 10) { ledger.countTaken >= 2 }
        try await waitUntil("B's interrupt send is parked in flight", timeout: 10) { priorTask.sentInterrupt }
        _ = await sendEntered.value()

        // Settle A's refusal WHILE the send is parked, and let A retire fully, so the post-send
        // world the successor now walks into has no active turn at all.
        gate.release()
        _ = await prior.value
        XCTAssertTrue(
            state.isSuppressed("u-grace-b"),
            "premise: the refusal suppressed the retained utterance before the send resumed"
        )

        sendGate.release()
        let bResult = await b.value
        XCTAssertEqual(
            bResult.outcome, .refused,
            "a refusal settled while the interrupt send was in flight still ends the successor locally"
        )
        // The successor's own client is the last one the factory built.
        let bTask = try XCTUnwrap(capturedTask)
        XCTAssertTrue(bTask !== priorTask, "premise: B built its own transport")
        XCTAssertFalse(
            bTask.sentTextFrames.contains { $0.contains("\"authenticate\"") },
            "B must submit NOTHING — frames=\(bTask.sentTextFrames)"
        )
    }

    /// PIN for the retired-before-claim ordering: when the predecessor's terminal is fully
    /// processed and its route has returned before the successor claims, the sink has no live
    /// registration to interrupt, so the successor proceeds as an ORDINARY turn and dispatches.
    /// A sink that instead ends such a successor locally refuses turns nothing was interrupted.
    func testARetiredPredecessorLeavesItsSuccessorAnOrdinaryTurn() async throws {
        StubWebSocketTask.sendDelayNanoseconds = 20_000_000
        addTeardownBlock { StubWebSocketTask.sendDelayNanoseconds = nil }
        self.nextTurnFixture = Self.doneOnlyFixture
        let sink = makeSink()

        let priorResult = await sink.routeToCloud(
            request: "prior question", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-grace-a"
        )
        XCTAssertEqual(priorResult.outcome, .completed, "premise: the predecessor fully retired")
        let priorTask = try XCTUnwrap(capturedTask)

        self.nextTurnFixture = Self.doneOnlyFixture
        let successorResult = await sink.routeToCloud(
            request: "play the next one", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-grace-b"
        )
        XCTAssertEqual(
            successorResult.outcome, .completed,
            "a successor arriving after the predecessor fully retired proceeds as an ordinary turn"
        )
        let successorTask = try XCTUnwrap(capturedTask)
        XCTAssertTrue(successorTask !== priorTask, "premise: the successor built its own transport")
        XCTAssertTrue(
            successorTask.sentTextFrames.contains { $0.contains("\"authenticate\"") },
            "the successor dispatched its own turn"
        )
        XCTAssertFalse(
            priorTask.sentInterrupt,
            "nothing may interrupt a turn that already retired"
        )
    }

    private func checkLocalInterruptionEndReleasesGraceHold(refused: Bool) async throws {
        // UNDER LOAD: every frame this stub sends is delayed, so the ordering these cases assert
        // must survive a slow host rather than only a quiet machine.
        StubWebSocketTask.sendDelayNanoseconds = 20_000_000
        addTeardownBlock { StubWebSocketTask.sendDelayNanoseconds = nil }
        // A's OWN fixture carries the refusal: it is A's terminal that answers B's interrupt, and
        // the gate withholds it until B is waiting. Giving B an error fixture instead made B's own
        // turn consume the error, leaving the arm under test unreached (measured).
        self.nextTurnFixture = refused
            ? """
            event: error
            data: {"code":"invalid_request","message":"interrupt does not reference the active turn"}

            """
            : Self.doneOnlyFixture
        let gate = holdNextTurn()
        addTeardownBlock { gate.release() }
        let state = CloudInterruptionState()
        holdCounters = (AtomicInteger(), AtomicInteger())
        let ledger = HoldLedger()
        holdLedger = ledger
        addTeardownBlock { self.holdLedger = nil }
        // For the timeout arm the bound must expire inside the test; for the refused arm it must NOT
        // expire first, or the wrong arm would run and the case would prove nothing about refusal.
        let sink = makeSink(
            withHoldCounters: true,
            acknowledgementTimeout: refused ? 30 : 0.5,
            interruptionState: state
        )

        let prior = Task {
            await sink.routeToCloud(
                request: "prior question", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-grace-a"
            )
        }
        var registered = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let live = await MainActor.run { sink.activeResultSocketForTesting?.boundIdentity != nil }
            if live { registered = true; break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(registered, "premise: A's transport must be registered")
        let priorTask = try XCTUnwrap(capturedTask)
        XCTAssertFalse(priorTask.sentInterrupt, "premise: nothing interrupted yet")
        // FIX THE ORDER BY EVENT: A's retirement waits until B's interrupt has been delivered to
        // A's OPEN socket. Without this, a delayed send let A close first and B ran as an ordinary
        // turn — the case then passed or failed on a different production path (measured).
        priorTask.holdCloseUntilInterruptDelivered = true

        // B dispatches WHILE A is still parked, so B takes its hold and sends the interrupt before
        // any terminal can settle it. This is the ordering the arms are reachable in.
        self.nextTurnFixture = Self.doneOnlyFixture
        let b = Task {
            await sink.routeToCloud(
                request: "play the next one", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-grace-b"
            )
        }
        // ORDER, NOT ELAPSED TIME. Two events must both have happened before A is allowed to
        // settle: B took its hold (the ledger records the begin callback itself), and B's interrupt
        // left on A's socket. Gating on the wire frame alone left the hold capture racing it, so
        // extra work in the done path could change which case failed (spec + reviewer).
        try await waitUntil("B takes its own grace hold", timeout: 10) { ledger.countTaken >= 2 }
        let bHold = try XCTUnwrap(ledger.lastTaken, "premise: B must have taken a hold of its own")
        try await waitUntil("B sends its interrupt while holding", timeout: 10) { priorTask.sentInterrupt }
        XCTAssertTrue(
            state.heldFollowUpForTesting != nil || state.isSuppressed("u-grace-b"),
            "premise: B must be parked on its interruption, not already past it"
        )

        // Only now let A settle: its refusal lands DURING B's acknowledgement wait. For the timeout
        // arm A stays parked forever, so the bound expires instead.
        if refused { gate.release() }
        let bResult = await b.value
        // Read B's token the instant B returns, BEFORE A settles: A's own drain can end a hold too,
        // and reading later would credit A's cleanup to B (measured — my earlier false green).
        let bReleasedOnReturn = ledger.wasEnded(bHold)
        XCTAssertEqual(bResult.outcome, .refused, "premise: B must end locally, not proceed")
        if refused { _ = await prior.value } else { gate.release(); _ = await prior.value }

        // THE ASSERTION: every hold taken has been ended. A leaked hold leaves begin > end, and the
        // window keeps no expiry timer.
        XCTAssertTrue(
            bReleasedOnReturn,
            "B returned while STILL HOLDING its own grace playback hold. The window keeps no expiry "
            + "timer, so the grace period cannot end on its own — it waits for some later turn to "
            + "happen to release it."
        )
    }

    /// THE PRE-AUTHENTICATION WINDOW: an interrupt that arrives before the predecessor's transport
    /// has registered is NOT transport loss. The predecessor has not authenticated, so the server
    /// has heard nothing of it and there is no turn to settle.
    ///
    /// The window is real and ordered by construction: `routeWithResultSocket` spawns the producer
    /// as a DETACHED task and returns at once, so the sink publishes its result binding on the main
    /// actor while registration — and therefore the authentication send — happens later on the
    /// producer's own task. A barge-in landing in between finds a live-looking predecessor whose
    /// interrupt cannot be delivered.
    ///
    /// The disposition is the opposite of the auth-sent case above: abandon the predecessor BEFORE
    /// it authenticates, so nothing of it is ever submitted, and let the interrupting utterance go
    /// out as a FRESH turn carrying no interruption report. Discarding it here would leave the
    /// predecessor to answer a question the user just talked over.
    ///
    /// THE RACE IS PINNED, not waited for: the predecessor's producer is parked at the bind seam,
    /// which sits after registration in today's code but before the authentication send. The
    /// successor's decision and the predecessor's "register, then send auth" must be serialized, so
    /// either the predecessor observes the abandonment before it registers and never authenticates,
    /// or the interrupt finds it registered. Parking here forces the first arm deterministically.
    func testInterruptBeforeThePredecessorAuthenticatesAbandonsItAndSubmitsFresh() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        let state = CloudInterruptionState()
        let sink = makeSink(interruptionState: state)

        // Park A's producer BEFORE it can authenticate, and hold it there until the test releases
        // it. `onBeforeBind` runs on the producer's own task; the wait is bounded so a lost release
        // fails promptly instead of hanging the suite.
        let seamEntered = Promise<Void>()
        let abandonObserved = Promise<Void>()
        parkNextProducerAtBindSeam = { client in
            client.onBeforeBind = { _ in
                seamEntered.resolve(())
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline, !abandonObserved.didClose { usleep(1_000) }
            }
        }

        let prior = Task {
            await sink.routeToCloud(
                request: "prior question", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-turn-a"
            )
        }
        // The sink has published its binding; the producer is parked before authentication. Wait
        // for the BINDING too, not just the seam: the producer runs off the main actor, so it can
        // reach the seam before the sink's own publication lands.
        await seamEntered.value()
        var bound = false
        let bindDeadline = Date().addingTimeInterval(5)
        while Date() < bindDeadline {
            if await MainActor.run(body: { sink.activeResultSocketForTesting != nil }) { bound = true; break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(bound, "premise: the sink must have published its result binding")
        let observedSocket = await MainActor.run { sink.activeResultSocketForTesting }
        let priorSocket = try XCTUnwrap(observedSocket)
        let priorTask = try XCTUnwrap(capturedTask)
        XCTAssertTrue(
            priorTask.sentTextFrames.isEmpty,
            "premise: the predecessor must NOT have authenticated yet; frames=\(priorTask.sentTextFrames)"
        )

        // B is a SECOND turn and therefore a second socket, so it needs its own fixture: the
        // per-build handoff consumes one, and a turn built with none gets an empty script (measured
        // as `NSURLErrorDomain -1011`, which reads like a production failure and is not one).
        self.nextTurnFixture = Self.doneOnlyFixture
        // B barges in while A is still pre-authentication.
        let successor = Task {
            await sink.routeToCloud(
                request: "play the next one", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-turn-b"
            )
        }
        // WAIT FOR THE ABANDONMENT, not for a held follow-up.
        //
        // Two earlier versions used observables that cannot express this arm. The hold B takes
        // before its send is DROPPED inside the same synchronous decision
        // (`dropHoldForAbandonedPredecessor`), so there is nothing left to poll. And the socket
        // handle's `boundIdentity` is never unwound — `retireSocket` removes the client's registry
        // entry but nothing clears the handle — so it stays non-nil after any retirement.
        //
        // The abandonment's own record is the line it logs, which is a production observable and
        // the same thing a run's log shows. Polled on a bounded deadline so a missing line fails
        // here with its premise rather than silently passing.
        var abandoned = false
        let abandonDeadline = Date().addingTimeInterval(5)
        while Date() < abandonDeadline {
            let logged = await FileLog.shared.logFileAsString()
            if logged.contains("predecessor turn \(priorSocket.requestId) abandoned before authentication") {
                abandoned = true
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(abandoned, "premise: B must abandon A before A authenticates")
        XCTAssertTrue(
            priorTask.sentTextFrames.isEmpty,
            "premise: the abandonment must have landed BEFORE A's authentication send; "
            + "frames=\(priorTask.sentTextFrames)"
        )
        abandonObserved.markClosed()
        abandonObserved.resolve(())
        let priorResult = await prior.value

        // A NEVER AUTHENTICATED: nothing of it reached the server.
        XCTAssertTrue(
            priorTask.sentTextFrames.isEmpty,
            "an abandoned pre-authentication turn must submit NOTHING; frames=\(priorTask.sentTextFrames)"
        )
        XCTAssertNotEqual(priorResult.outcome, .completed, "an abandoned turn is never a completion")
        // AND IT IS NOT A FAILURE EITHER. Abandonment is not something that went wrong: nothing of
        // this turn was ever sent, so there is no failure to report and nothing to tell the user.
        // Yielding an error terminal here made A's own consumer speak "Connection lost. Please try
        // again." for a turn the server never heard of — the very symptom this disposition removes,
        // reintroduced on the predecessor's side of it. The successor cancels A's token at its
        // admission, but that is AFTER its interruption decision, so the cancelled-owner guard in
        // the error path only hid the symptom when scheduling happened to favour it.
        XCTAssertEqual(
            priorResult.outcome, .earlyClose,
            "an abandoned turn ends incomplete, not failed; got \(priorResult.outcome)"
        )
        XCTAssertEqual(
            priorResult.response, .silent,
            "nothing may be spoken for a turn that never submitted anything; got \(priorResult.response)"
        )

        // B GOES OUT AS A FRESH TURN, with no interruption report: nothing of A was heard, so there
        // is no settled history to correct.
        let bResult = await successor.value
        let bTask = try XCTUnwrap(capturedTask)
        let bFrames = bTask.sentTextFrames
        XCTAssertTrue(
            bFrames.contains { $0.contains("u-turn-b") },
            "the interrupting utterance must be submitted as a fresh turn; frames=\(bFrames)"
        )
        XCTAssertFalse(
            bFrames.contains { $0.contains("\"interrupts\"") },
            "a fresh turn after a pre-authentication abandonment carries NO interruption report; frames=\(bFrames)"
        )
        XCTAssertEqual(bResult.outcome, .completed, "the fresh turn runs normally")
        XCTAssertFalse(state.isSuppressed("u-turn-b"), "the utterance was not discarded, so it must not be suppressed")
    }

    /// THE LOST ARM of the abandon-before-authentication race. The predecessor's authentication send
    /// has already been INVOKED when the successor decides, so the server may admit that turn.
    /// Abandoning it locally would leave a turn running that the client believes it cancelled.
    ///
    /// Forced at the only place it can be: INSIDE the test transport's send of the authentication
    /// frame, which is after the producer records its send as invoked. Parking at the bind seam
    /// cannot express this — there the mark is not yet set, so an abandonment always wins.
    ///
    /// Two things must hold. The abandonment reports LOST and leaves the predecessor's socket OPEN,
    /// because the interrupt still has to travel on it; closing there would turn a deliverable
    /// interruption into transport loss and drop the user's utterance. And the interrupt is then
    /// DELIVERED on that live socket, not reported undelivered.
    func testAbandonmentLosesToAnAlreadyInvokedAuthenticationSend() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        let state = CloudInterruptionState()
        let sink = makeSink(interruptionState: state)

        let authGate = Gate()
        let authEntered = Promise<Void>()
        addTeardownBlock { authGate.release() }
        holdNextAuthenticationSend = (authGate, authEntered)

        let prior = Task {
            await sink.routeToCloud(
                request: "prior question", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-turn-a"
            )
        }
        // A is INSIDE its authentication send: invoked, not yet returned.
        await authEntered.value()
        let observedSocket = await MainActor.run { sink.activeResultSocketForTesting }
        let priorSocket = try XCTUnwrap(observedSocket)
        let priorTask = try XCTUnwrap(capturedTask)

        let successor = Task {
            await sink.routeToCloud(
                request: "play the next one", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-turn-b"
            )
        }
        let held = await waitForHeldFollowUp(state, requestId: priorSocket.requestId, timeout: 5)
        XCTAssertTrue(held, "premise: B must reach its interruption decision while A's send is in flight")

        // Let the send complete. A was NOT abandoned, so its socket must still carry the interrupt.
        authGate.release()
        _ = await prior.value
        _ = await successor.value

        XCTAssertTrue(
            priorTask.sentInterrupt,
            "a lost abandonment race must interrupt the predecessor on its still-open socket"
        )
        XCTAssertFalse(
            priorTask.isCancelledSocket && !priorTask.sentInterrupt,
            "the losing arm must not close the predecessor's transport"
        )
    }

    /// A SECOND barge-in against the same already-abandoned predecessor must read the SAME answer.
    ///
    /// The abandonment decision is a question about the turn, not an effect to perform once: once a
    /// turn is closed before its authentication send, it stays unheard for the rest of its life. The
    /// sink publishes a predecessor's binding until the successor's own publication replaces it, and
    /// dropping the abandoned hold clears the one-shot interrupt claim — so a second utterance can
    /// reach the same socket and ask again.
    ///
    /// Taking the hook on the first win made that second call answer `false`, which the sink reads as
    /// "may have been admitted, interrupt undeliverable": it suppressed the utterance and ended
    /// locally, silently discarding what the user said over a turn that never existed.
    func testASecondAbandonmentOfTheSameUnheardTurnReadsTheSameAnswer() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        let state = CloudInterruptionState()
        let sink = makeSink(interruptionState: state)

        let seamEntered = Promise<Void>()
        let abandonObserved = Promise<Void>()
        parkNextProducerAtBindSeam = { client in
            client.onBeforeBind = { _ in
                seamEntered.resolve(())
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline, !abandonObserved.didClose { usleep(1_000) }
            }
        }
        let prior = Task {
            await sink.routeToCloud(
                request: "prior question", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-turn-a"
            )
        }
        await seamEntered.value()
        var bound = false
        let bindDeadline = Date().addingTimeInterval(5)
        while Date() < bindDeadline {
            if await MainActor.run(body: { sink.activeResultSocketForTesting != nil }) { bound = true; break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(bound, "premise: the sink must have published its result binding")
        let observedSocket = await MainActor.run { sink.activeResultSocketForTesting }
        let priorSocket = try XCTUnwrap(observedSocket)

        // FIRST abandonment wins: nothing of this turn was submitted.
        let first = await MainActor.run { priorSocket.abandonBeforeAuthentication() }
        XCTAssertTrue(first, "premise: the pre-authentication window must be won here")
        // SECOND ask, same turn, same unheard state — the answer must not change.
        let second = await MainActor.run { priorSocket.abandonBeforeAuthentication() }
        XCTAssertTrue(
            second,
            "a turn already abandoned before authentication is STILL unheard: a second barge-in must "
            + "read the same answer, not classify it as undeliverable and drop the user's utterance"
        )

        abandonObserved.markClosed()
        abandonObserved.resolve(())
        _ = await prior.value
    }

    /// "ABANDONED" IS A REASON, NOT A SYNONYM FOR CLOSED.
    ///
    /// The idempotent answer above must hold only for a lifetime closed BY the abandonment decision.
    /// A turn that authenticated and then closed — completed, failed, or cancelled — was heard by the
    /// server, so it is not abandonable: answering "abandoned" for any closed lifetime would route a
    /// late barge-in against a finished turn as a fresh turn with no interruption report, dropping the
    /// settled history that turn created.
    func testATurnThatAuthenticatedAndThenClosedIsNotAbandonable() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        // HOLD the terminal until the handle has been captured. A done-only turn authenticates and
        // finishes in well under a millisecond (measured: 0.3 ms from auth frame to terminal), so an
        // unheld run publishes and clears its binding between two polls and the premise finds
        // nothing — a fixture race, not a behaviour.
        let gate = holdNextTurn()
        addTeardownBlock { gate.release() }
        let sink = makeSink()

        // A runs to its terminal on its own: it authenticates, completes, and its lifetime closes
        // through the ordinary finish path — never through the abandonment decision.
        let prior = Task {
            await sink.routeToCloud(
                request: "prior question", tier: .free, context: self.sampleContext(),
                origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-turn-a"
            )
        }
        // Capture the handle WHILE the turn is live: the turn-wide defer clears the binding on exit,
        // so reading it after the terminal would find nothing. The handle itself outlives the
        // binding, which is exactly the late-barge-in shape this case pins.
        var captured: AppOperationResultSocket?
        let captureDeadline = Date().addingTimeInterval(5)
        while Date() < captureDeadline {
            captured = await MainActor.run { sink.activeResultSocketForTesting }
            if captured != nil { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let priorSocket = try XCTUnwrap(captured, "premise: the sink must publish its result binding")
        gate.release()
        let priorResult = await prior.value
        XCTAssertEqual(priorResult.outcome, .completed, "premise: the predecessor must have run to a terminal")
        let priorTask = try XCTUnwrap(capturedTask)
        XCTAssertTrue(
            priorTask.sentTextFrames.contains { $0.contains("\"authenticate\"") },
            "premise: the predecessor must have AUTHENTICATED; frames=\(priorTask.sentTextFrames)"
        )

        // A late ask against that finished turn must NOT read as an abandonment, on the first ask or
        // any later one.
        let first = await MainActor.run { priorSocket.abandonBeforeAuthentication() }
        XCTAssertFalse(
            first,
            "a turn that authenticated was heard by the server: closing it later does not make it abandonable"
        )
        let second = await MainActor.run { priorSocket.abandonBeforeAuthentication() }
        XCTAssertFalse(second, "the answer must stay stable for a turn that was heard")
    }

    private func makeSink(conversationManager: CloudConversationManager? = nil, withHoldCounters: Bool = false, acknowledgementTimeout: TimeInterval = CloudRouteSink.interruptionAcknowledgementTimeout, interruptionState: CloudInterruptionState = CloudInterruptionState()) -> CloudRouteSink {
        let cloudConfig = CloudConfig(defaults: defaults)
        let built = CloudRouteSink(
            clientFactory: {
                let fixture = CloudRouteSinkTests.injectOperationIdentity(self.nextTurnFixture ?? self.nextFixture())
                self.nextTurnFixture = nil
                let audio = self.nextTurnAudioPayloads
                self.nextTurnAudioPayloads = []
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl, fixture: fixture, audioPayloads: audio
                )
                if let gate = self.pendingHeldGate {
                    // The held turn waits for frames; the test releases it later.
                    built.task.holdUntilReleased(gate)
                    self.heldTurn = (built.task, gate)
                    self.pendingHeldGate = nil
                }
                if let block = self.blockProducerAfterFrames {
                    self.blockProducerAfterFrames = nil
                    // SYNC park on the producer's own task (never the main queue): the control
                    // holds A's producer AFTER its audio frames are enqueued, with a bounded
                    // wait so a lost release fails promptly instead of hanging.
                    let sem = block.semaphore
                    final class Counter: @unchecked Sendable {
                        private let lock = NSLock(); private var n = 0
                        func next() -> Int { lock.lock(); n += 1; let v = n; lock.unlock(); return v }
                    }
                    let counter = Counter()
                    built.client.onFrameReceived = {
                        // Block the producer AFTER the Nth frame (frames keep flowing to the
                        // sink before that). Bounded waits: a lost release fails promptly.
                        if counter.next() >= block.count {
                            // REGISTERED so an interrupt's terminal can open it: parking here
                            // stops the receive loop before the frame is parsed, so without this
                            // a parked predecessor could never read the answer it is owed.
                            guard StubWebSocketTask.registerProductionPark(sem) else { return }
                            while sem.wait(timeout: .now() + 0.05) == .timedOut {}
                        }
                    }

                }
                if let park = self.parkNextProducerAtBindSeam {
                    self.parkNextProducerAtBindSeam = nil
                    park(built.client)
                }
                if let hold = self.holdNextAuthenticationSend {
                    self.holdNextAuthenticationSend = nil
                    built.task.holdAuthenticationSendUntilReleased(hold.gate, entered: hold.entered)
                }
                if let action = self.firstFrameActionForNextBuild {
                    self.firstFrameActionForNextBuild = nil
                    let inner = built.client
                    built.client.onFrameReceived = { action() }
                    _ = inner
                }
                if self.cancelPlayerOnFirstFrameForNextBuild {
                    self.cancelPlayerOnFirstFrameForNextBuild = false
                    built.client.onFrameReceived = { [weak self] in
                        guard let self else { return }
                        let sink = self.hookedSink
                        Task { @MainActor in
                            guard !(self.injectedStopDone) else { return }
                            self.injectedStopDone = true
                            sink?.audioPlayerForTesting?.cancel()
                        }
                    }
                }
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            analytics: VoiceAnalytics(analytics: analytics),
            operationResultConsumer: nil,
            interruptionAcknowledgementTimeout: acknowledgementTimeout,
            conversationManager: conversationManager ?? testConversationManager(),
            interruptionState: interruptionState,
            onGracePlaybackHoldBegin: withHoldCounters ? { origin in
                self.holdCounters?.begin.bump()
                // A refused begin is a real production outcome: the window is not live for this
                // turn's generation (`beginPlaybackHoldOnMain` guards on it). The turn then takes no
                // hold of its own and INHERITS whatever hold is current.
                if self.refuseHoldBeginsAfterFirst, (self.holdLedger?.countTaken ?? 0) >= 1 {
                    return nil
                }
                let token = GracePeriodSignal.PlaybackHoldToken(generation: origin ?? -1)
                self.holdLedger?.take(token)
                return token
            } : nil,
            onGracePlaybackHoldEnd: withHoldCounters ? { token in
                self.holdCounters?.end.bump()
                if let token { self.holdLedger?.end(token) }
            } : nil
        )
        return built
    }

    private func sampleContext() -> PlaybackContext {
        PlaybackContext(
            episodeId: "ep",
            podcastId: "pod",
            referencePositionMs: 1_000,
            clientPositionMs: 1_100,
            recentReferencePositions: [],
            previousReferencePositionMs: nil
        )
    }

    /// A refused stale turn must not disturb the LIVE SUCCESSOR'S state, observed on ONE sink.
    ///
    /// The first version of this case used two sink instances and awaited the first turn to
    /// completion, so it never held a live successor and could not observe `activeTurn`
    /// cancellation at all — it passed while the defect it named was present. This one holds the
    /// successor in flight on the same sink (through the gate the harness already provides) and
    /// then dispatches the stale turn against that same sink.
    func testARefusedStaleTurnDoesNotCancelTheHeldLiveSuccessor() async {
        // The successor is held mid-turn: it has claimed activeTurn and is still running.
        // The sink's manager is held so the live origin can MOVE while the successor is in
        // flight — otherwise both turns share a live origin and the second is not stale at all,
        // which is exactly how the first version of this case proved nothing.
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        // A REAL completion fixture, so the held turn can finish and be observed finishing.
        nextTurnFixture = """
            event: token
            data: {"text":"live answer"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let gate = holdNextTurn()
        let sink = makeSink(conversationManager: manager)

        let live = Task {
            await sink.routeToCloud(
                request: "live", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .wakeWord
            , utteranceId: "u-78")
        }
        // Give the live turn time to reach the socket and hold there. `Task.yield()` is not
        // enough: the turn has to get through the pause hold and into the socket, which the
        // sibling barge-in case does with a 200 ms sleep.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let heldTask = heldTurn?.task
        XCTAssertNotNil(heldTask, "the live turn never reached the socket, so nothing was held")

        // The window moves on while the successor is still in flight, so the next turn's
        // captured origin is genuinely stale.
        manager.registerLiveOrigin(cloudTestOrigin + 1)

        // The SAME sink now receives a turn whose origin is no longer live, while the held
        // successor is genuinely in flight and owns `activeTurn`.
        let staleResult = await sink.routeToCloud(
            request: "stale", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp
        , utteranceId: "u-79")

        XCTAssertEqual(staleResult.outcome, .refused)

        // The discriminator: RELEASE the held turn and observe whether it can still COMPLETE.
        // Reading the sink's current `activeTurn` cannot work — the bad ordering cancels the held
        // token and REPLACES activeTurn with the stale turn's, so that read returns the
        // replacement's flag and never the successor's. The successor's own outcome is the thing
        // that distinguishes the two orderings.
        gate.release()
        let liveResult = await live.value
        XCTAssertEqual(
            liveResult.outcome, .completed,
            "a refused stale turn prevented the held successor from completing"
        )
        // The transport close-code assertion is deliberately NOT made. In the full suite the held
        // socket carries a normal close code even when the successor completes, so a non-nil code
        // does not separate "cancelled by the stale attempt" from "closed by its own completion"
        // — it passed in isolation and failed under suite load, which is the signature of an
        // assertion reading a state the case does not control. The successor's OUTCOME above is
        // the discriminator that does separate the two orderings.
    }

    /// POSITIVE CONTROL: with the mapper configured and the turn NOT superseded, the same fixture
    /// DOES seek. Without this, "no seek happened" cannot be distinguished from "the mapping was
    /// missing, so the action was refused before any seek" — which is exactly why the earlier
    /// late-action assertion could not discriminate.
    func testTheLateActionFixtureActuallySeeksWhenNotSuperseded() async throws {
        mapper.playbackSecondsForReference = [100.0: 110.0]
        self.nextTurnFixture = Self.actionThenDoneFixture
        let sink = makeSink()
        _ = await sink.routeToCloud(
            request: "solo", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord
        , utteranceId: "u-80")
        XCTAssertTrue(
            playback.calls.contains(.seekTo(110)),
            "the fixture must produce a real seek when the turn is not superseded, otherwise the "
            + "absence of a seek proves nothing"
        )
    }

    /// A superseded turn's LATE ACTION must be suppressed, observed on the ACTION OUTPUT.
    ///
    /// Ordering is CONTROLLED: A's output is held, the case waits on an EXPLICIT BARRIER until B
    /// has reached the transport, then releases A — so A's action arrives after A lost the turn.
    /// A's stream is fed one event per receive, so releasing A delivers its ACTION.
    func testSupersededTurnsLateActionIsSuppressedAfterSuccessorInstallsItsToken() async throws {
        defer { self.heldTurn = nil }

        // A VALID mapping, so the action would seek if it were allowed to run.
        mapper.playbackSecondsForReference = [100.0: 110.0]
        self.nextTurnFixture = Self.actionThenDoneFixture
        let gate = holdNextTurn()
        let sink = makeSink()

        let a = Task {
            await sink.routeToCloud(
                request: "A", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .wakeWord
            , utteranceId: "u-81")
        }
        let maybeHeld = await waitForHeldTurn()
        let heldA = try XCTUnwrap(maybeHeld, "turn A never reached the socket")
        // A's auth frame is submitted just AFTER the turn is held, so "held" does not imply
        // "submitted": bounded wait for the frame itself, never an instant read.
        var submitted = false
        for _ in 0..<200 {
            if !heldA.task.sentTextFrames.isEmpty { submitted = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(submitted, "A must have submitted its frame")

        // B replaces the active turn while A is still held (the barge-in shape, kept on purpose
        // here: this case is about what happens to A's output AFTER it loses the turn).
        self.nextTurnFixture = Self.doneOnlyFixture
        let b = Task {
            await sink.routeToCloud(
                request: "B", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .followUp
            , utteranceId: "u-82")
        }
        // B interrupts A, so B parks on A's ACKNOWLEDGEMENT (read BEFORE B cancels anything, so
        // A's receive is deliberately kept alive for it) and only builds its own task once A
        // reaches a terminal. The real server ANSWERS an interrupt by ending that turn, so the stub
        // is configured to do the same (see `interruptTerminalFrame`) — test code only, no app
        // change. The stub appends that terminal to the queue, so A's still-scripted ACTION is
        // served FIRST and lands while A has already lost the turn, which is this case's subject;
        // the terminal then releases B.
        heldA.task.interruptTerminalFrame = Self.interruptedDoneTextFrame
        // WAIT FOR THE INTERRUPT TO ACTUALLY BE SENT before releasing A. Releasing first lets A's
        // receive serve its ACTION while it is still the live turn — the action then legitimately
        // runs and the case proves nothing (exactly the flake it showed under suite load). The
        // interrupt is what closes A's effects, so the ordering under test is: interrupt sent →
        // A's late action arrives → rejected.
        var interrupted = false
        for _ in 0..<400 {
            if heldA.task.sentTextFrames.contains(where: { $0.contains("\"type\":\"interrupt\"") }) {
                interrupted = true; break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(interrupted, "B's interrupt reached A's socket before A's late action was served")
        gate.release()
        // EXPLICIT BARRIER on B'S OWN TASK, read INSIDE the poll.
        // NOTE: `CloudRouteTestURLProtocol.requestCount` is NOT usable here — it counts
        // URLProtocol startLoading, and the route path uses URLSessionWebSocketTask, which never
        // goes through URLProtocol. An earlier version used it and the condition was never true,
        // so the "barrier" silently fell through its timeout and the ordering was really a sleep.
        //
        // `capturedTask` is replaced when a turn builds its task, and is nil until then, so it must
        // be sampled inside the poll. B's task is distinguishable from A's by identity.
        var bTask: StubWebSocketTask?
        try await waitUntil("B built and submitted its own task") {
            guard let latest = self.capturedTask, latest !== heldA.task else { return false }
            guard latest.sentAuthFrame != nil else { return false }
            bTask = latest
            return true
        }
        let bPreparedTask = try XCTUnwrap(bTask, "B must have built and submitted its own task")
        let bRequestId = try XCTUnwrap(
            bPreparedTask.sentAuthFrame?["request_id"] as? String,
            "B's prepared frame must carry a client-assigned request_id"
        )
        XCTAssertEqual(bRequestId, "u-82", "B's wire request_id IS B's admitted utterance id (delta f47e972)")
        // A and B are genuinely distinct turns, shown by their own prepared frames.
        let aRequestId = try XCTUnwrap(
            heldA.task.sentAuthFrame?["request_id"] as? String,
            "A's prepared frame must carry a client-assigned request_id"
        )
        XCTAssertEqual(aRequestId, "u-81", "A's wire request_id IS A's admitted utterance id (delta f47e972)")
        XCTAssertNotEqual(aRequestId, bRequestId, "A and B must be distinguishable by their frames")

        _ = await a.value
        _ = await b.value

        XCTAssertFalse(
            playback.calls.contains(.seekTo(110)),
            "a superseded turn's late action must not execute, though the same fixture seeks when "
            + "the turn is not superseded (see the positive control)"
        )
    }

    // MARK: - Fixtures and barriers for the controlled-ordering cases

    /// An action followed by a terminal event: the action is the late output under test.
    static let actionThenDoneFixture = """
        event: action
        data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":100000}}

        event: done
        data: {"usage":{"input_tokens":1,"output_tokens":0}}

        """

    static let doneOnlyFixture = """
        event: done
        data: {"usage":{"input_tokens":1,"output_tokens":0}}

        """

    /// The terminal an INTERRUPT sends, as ONE ALREADY-PARSED WIRE FRAME, for a socket that has
    /// served part of its script and must now be told to finish.
    ///
    /// Two things are load-bearing here. It is the JSON the transport carries, NOT the
    /// `event:`/`data:` fixture shape — a fixture literal handed to the socket verbatim parses to
    /// no events at all, so the turn never sees its terminal and ends as a transport failure. And
    /// it says `interrupted`, because that is what the server sends when an interrupt settles a
    /// turn (`cloud-assistant.md` → Interruption; pinned to the worker's own serializer test,
    /// `worker/test/protocol/session.test.ts` "an INTERRUPTED done says so"). A plain `done` here
    /// would describe a turn that finished normally, which is a different case.
    static let interruptedDoneTextFrame = #"{"type":"done","outcome":"interrupted","usage":{"input_tokens":1,"output_tokens":0}}"#

    /// The terminal for a predecessor the case lets FINISH normally (`finishPredecessor`), which
    /// is deliberately not an interruption: it completes, drains and restores.
    static let completedDoneTextFrame = #"{"type":"done","outcome":"completed","usage":{"input_tokens":1,"output_tokens":0}}"#

    /// The barrier's failure must carry its own evidence: label, elapsed time, budget and
    /// poll count — not a label alone. A label-only throw leaves a timeout undiagnosable
    /// until the log lines are hand-traced.
    func testBarrierTimeoutReportCarriesElapsedBudgetAndPolls() async throws {
        let start = Date()
        do {
            try await waitUntil("a condition that never becomes true", timeout: 0.05) { false }
            XCTFail("the barrier must throw when the condition never holds")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("a condition that never becomes true"), "label present: \(message)")
            XCTAssertTrue(message.contains("timed out after"), "elapsed present: \(message)")
            XCTAssertTrue(message.contains("budget 0.1 s") || message.contains("budget 0.0"),
                         "budget present: \(message)")
            XCTAssertTrue(message.contains("polls, condition stayed false"), "poll count present: \(message)")
            XCTAssertTrue(Date().timeIntervalSince(start) < 2, "the tiny budget is respected")
        }
    }

    /// Polls the harness's held-turn state rather than sleeping a fixed interval.
    private func waitForHeldTurn(timeout: TimeInterval = 2) async -> (task: StubWebSocketTask, gate: Gate)? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let held = heldTurn { return held }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return nil
    }

    /// Polls `condition` until it holds: an EXPLICIT BARRIER, not an elapsed sleep.
    private func waitUntil(_ description: String, timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var polls = 0
        while Date() < deadline {
            polls += 1
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        if condition() { return }
        struct BarrierNotReached: Error, CustomStringConvertible {
            let label: String
            let timeout: TimeInterval
            let elapsed: TimeInterval
            let polls: Int
            var description: String {
                "barrier never satisfied: \(label) — timed out after \(String(format: "%.3f", elapsed)) s "
                + "(budget \(String(format: "%.1f", timeout)) s, \(polls) polls, condition stayed false)"
            }
        }
        throw BarrierNotReached(label: description, timeout: timeout,
                                elapsed: Date().timeIntervalSince(start), polls: polls)
    }

    /// POSITIVE CONTROL for the audio path: a turn carrying binary audio must actually put
    /// NONEMPTY audio in front of the player. Without this, "no audio pending" afterwards cannot
    /// be distinguished from "no audio ever arrived", which is exactly how the first version of
    /// the output assertion was vacuous.
    /// A FAILED ENGINE START MUST NOT SILENTLY CONSUME THE TURN'S AUDIO.
    ///
    /// The player marked itself playing even when `engine.start()` threw, so the runner
    /// consumed every buffered frame through the no-engine `playFrame` path: nothing was ever
    /// scheduled, the turn reported success, and the answer's audio was gone. This case makes
    /// the first start attempt throw through the existing test seam and asserts the audio is
    /// scheduled once a retry succeeds. Under the old behavior it fails: the boundary never
    /// fires because the frames were consumed with no engine at all.
    @MainActor
    func testAFailedEngineStartIsRetriedAndTheAudioStillSchedules() async throws {
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        // THROW ONCE: the first attempt fails the way a contended or halted audio server fails;
        // later attempts install a real offline-rendering engine so the retry can succeed.
        final class ThrowOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var thrown = false
            func arm(_ engine: AVAudioEngine) throws {
                lock.lock(); defer { lock.unlock() }
                if !thrown { thrown = true; throw NSError(domain: "t17", code: 1) }
                let fmt = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
                try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4_096)
            }
        }
        let throwOnce = ThrowOnce()
        CloudAudioPlayer.configureEngineForTesting = { engine in try throwOnce.arm(engine) }
        addTeardownBlock {
            CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
            CloudAudioPlayer.configureEngineForTesting = nil
        }
        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = (0..<7).map { _ in Data(repeating: 0x33, count: 4_800 * 2) }
        playback.setPlaying(true)
        let sink = makeSink()
        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        let boundariesBefore = player.schedulingBoundaryCount
        addTeardownBlock { @MainActor in
            let stop = player.cancel()
            _ = await player.awaitActualStop(after: stop)
        }

        let result = await sink.routeToCloud(
            request: "audio", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord, utteranceId: "u-t17")
        XCTAssertEqual(result.outcome, .completed, "the turn completes")
        XCTAssertEqual(player.framesEnqueuedForTesting, 7, "premise: the frames arrived")
        // The audio must be SCHEDULED — the failed first start must not have consumed the
        // frames silently. The retry wake re-enters the runner without a new frame.
        try await waitUntil("the retried start schedules the audio", timeout: 5) {
            player.schedulingBoundaryCount > boundariesBefore
        }
    }

    func testATurnCarryingBinaryAudioActuallyReachesThePlayer() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = [Self.audioPayload]
        let sink = makeSink()

        _ = await sink.routeToCloud(
            request: "audio", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord
        , utteranceId: "u-83")

        // The player must have been given audio: the enqueue path ran, and by the end of the turn
        // the audio has drained rather than been dropped.
        let playerRef = await MainActor.run { sink.audioPlayerForTesting }
        let player = try XCTUnwrap(playerRef)
        let enqueued = player.framesEnqueuedForTesting
        XCTAssertTrue(
            enqueued > 0,
            "binary audio must be DELIVERED to the player — otherwise an output assertion proves nothing"
        )
        // SCOPE: this is DELIVERY and buffer state, not proof that speech was RENDERED. The player's
        // decode/render path is not observed here, so a case reading these two facts must not be
        // described as showing that audio was heard.
        // The buffer must reach empty via an EXPLICIT BARRIER, not an immediate read: audio
        // frames can legitimately arrive at the player after `done` was processed (the socket
        // delivers them independently of the event stream), and the drain only consumes what had
        // arrived. Reading once races that delivery; the barrier bounds it instead.
        // `hasPendingAudio` is buffer-lock guarded and not actor isolated, so the barrier reads
        // it directly — `waitUntil`'s closure runs off the main actor, and an
        // `assumeIsolated` here traps the process when the closure lands off main.
        // `player` was captured on the main actor above; `hasPendingAudio` itself is
        // buffer-lock guarded and safe to call from `waitUntil`'s off-main closure.
        try await waitUntil("the turn's audio drained after done", timeout: 5) {
            !player.hasPendingAudio
        }
    }

    /// AN INTERRUPTED `done` DISCARDS OUTPUT WITHOUT DRAINING IT
    /// (`cloud-assistant.md` → event table: for `outcome: "interrupted"`, "discard output and
    /// release this turn's audio ownership without draining"; Interruption: the server "sends
    /// terminal `done` with `outcome: \"interrupted\"`").
    ///
    /// The break this catches: treating every `done` as a completion. Then the answer the user
    /// already took back is PLAYED OUT to its end before the window resumes, instead of being
    /// shed. The two are distinguishable only while the audio is still buffered, so the drain is
    /// HELD here: a discard empties the buffer without playing a frame, a drain plays them all.
    ///
    /// Frame shape pinned to the worker's own serializer test, not to this client's reading:
    /// `worker/test/protocol/session.test.ts` "an INTERRUPTED done says so, rather than defaulting
    /// to completed" asserts `{ type: "done", outcome: "interrupted", usage }`.
    @MainActor
    func testAnInterruptedDoneDiscardsBufferedOutputWithoutDrainingIt() async throws {
        try await exerciseInterruptedDoneDrainsOrDiscards(outcome: "interrupted")
    }

    /// COMPANION, same wait point: a `completed` `done` DOES drain. Without it the case above
    /// could pass by never playing anything at all — a player that discards every turn's audio
    /// would satisfy "nothing was drained" just as well.
    @MainActor
    func testACompletedDoneDrainsTheSameBufferedOutput() async throws {
        try await exerciseInterruptedDoneDrainsOrDiscards(outcome: "completed")
    }

    @MainActor
    private func exerciseInterruptedDoneDrainsOrDiscards(outcome: String) async throws {
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        CloudAudioPlayer.configureEngineForTesting = { engine in
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        }
        addTeardownBlock {
            CloudAudioPlayer.configureEngineForTesting = nil
            CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        }
        // Seven binary frames then the terminal, so the producer can be parked AFTER its audio
        // is enqueued and BEFORE `done` is read.
        let producerRelease = DispatchSemaphore(value: 0)
        blockProducerAfterFrames = (8, producerRelease)
        nextTurnFixture = """
        event: done
        data: {"outcome":"\(outcome)","usage":{"input_tokens":1,"output_tokens":0}}

        """
        nextTurnAudioPayloads = (0..<7).map { _ in Data(repeating: 0x11, count: 4_800 * 2) }
        playback.setPlaying(true)
        let sink = makeSink()
        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        // The reference counts samples the player actually SCHEDULED, which is what separates
        // "played out" from "shed": both leave the buffer empty.
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)
        player.emittedPCMReference = reference
        player.echoReferenceHandoff = handoff
        addTeardownBlock { @MainActor in
            producerRelease.signal()
            player.setDrainHoldForTesting(false)
            player.openPhysicalStopGateForTesting()
            let stop = player.cancel()
            _ = await player.awaitActualStop(after: stop)
            withExtendedLifetime(handoff) {}
            withExtendedLifetime(sink) {}
        }
        // Hold the runner so the seven frames stay BUFFERED: nothing is scheduled yet, and the
        // terminal's own choice is the only thing that can move them.
        player.setDrainHoldForTesting(true)
        let turn = Task {
            await sink.routeToCloud(request: "answer", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: .wakeWord, utteranceId: "u-interrupted-\(outcome)")
        }
        // `hasOutstandingOutput` includes the ENGINE being up, which the runner sets before it
        // reaches the hold — so waiting on it proves the runner is genuinely parked inside the
        // hold with all seven frames still buffered, not merely that they arrived.
        try await waitUntil("the runner is parked in the hold with the whole answer buffered", timeout: 5) {
            player.framesEnqueuedForTesting == 7
                && player.bufferedFrameCountForTesting == 7
                && player.hasOutstandingOutput
        }
        XCTAssertEqual(reference.streamIndex, 0, "premise: nothing has been scheduled yet")
        // Let the terminal be read. The runner stays held, so whatever the terminal requests is
        // queued but not yet performed.
        producerRelease.signal()
        _ = await turn.value
        let bufferedAtTerminal = player.bufferedFrameCountForTesting
        let scheduledAtTerminal = reference.streamIndex
        // The turn's own report must name what happened: an interrupted turn is not a completion,
        // and analytics must not record it as one (`cloud-assistant.md` → Turn observability).
        let recordedOutcome = analytics.events.last(where: { $0.0 == "cloud_assistant_turn" })?.1["outcome"] as? String
        // Release the runner: a queued DRAIN plays the frames, a DISCARD has already shed them.
        player.setDrainHoldForTesting(false)
        try await waitUntil("the runner settled the terminal's request", timeout: 5) {
            !player.hasQueuedStop && player.bufferedFrameCountForTesting == 0
        }
        // The runner settles ASYNCHRONOUSLY after the hold opens, so poll for the samples rather
        // than reading once: an instant read can land before the drain has scheduled anything.
        var scheduledAfter = reference.streamIndex
        if outcome != "interrupted" {
            for _ in 0..<600 {
                scheduledAfter = reference.streamIndex
                if scheduledAfter >= 7 * 3_200 { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        if outcome == "interrupted" {
            XCTAssertEqual(recordedOutcome, "interrupted",
                           "an interrupted turn must be recorded as interrupted, never as a completion")
            XCTAssertEqual(bufferedAtTerminal, 0,
                           "an interrupted done must SHED the buffered answer at the terminal, not leave it to drain")
            XCTAssertEqual(scheduledAtTerminal, 0, "no frame of a discarded answer may be scheduled")
            XCTAssertEqual(scheduledAfter, 0,
                           "the discarded answer must never be played out: \(scheduledAfter) samples were scheduled")
        } else {
            XCTAssertEqual(recordedOutcome, "done", "a completed turn is recorded as done")
            XCTAssertEqual(scheduledAfter, 7 * 3_200,
                           "a completed done drains its answer: every sample is scheduled")
        }
    }

    /// AN INTERRUPTED TURN STILL CONTRIBUTES ITS TIMING RECORD
    /// (`cloud-assistant.md` → Conversational latency: "Measure every turn"; the record's
    /// `outcome` row lists `interrupted` alongside `done` and `error`).
    ///
    /// The break this catches: emitting the record only on the paths that finish or fail. An
    /// interrupted turn is a real turn — it sent a request and may have been heard — so omitting
    /// its line makes the slowest, most confusing case invisible in exactly the data meant to
    /// explain it. A missing line is indistinguishable from a turn that never ran.
    ///
    /// SCOPE, stated because the sibling control at `testAnInterruptedDoneDiscards…` measures
    /// something else: that one proves the audio was SHED; this one proves the turn was MEASURED.
    /// Neither implies the other — a sink can discard correctly and report nothing.
    ///
    /// The counters are the interrupted turn's own: seven frames arrived, and its own cancel is
    /// the one clear. Nothing here depends on whether the host rendered audio, so the audible leg
    /// is asserted as internally consistent rather than as a fixed duration.
    @MainActor
    func testAnInterruptedTurnEmitsItsOwnLatencyRecord() async throws {
        let utteranceId = "u-\(UUID().uuidString.prefix(12))-int-record"
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        addTeardownBlock { CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil }
        let release = DispatchSemaphore(value: 0)
        blockProducerAfterFrames = (8, release)
        nextTurnFixture = """
        event: done
        data: {"outcome":"interrupted","usage":{"input_tokens":1,"output_tokens":0}}

        """
        nextTurnAudioPayloads = (0..<7).map { _ in Data(repeating: 0x11, count: 4_800 * 2) }
        playback.setPlaying(true)
        let sink = makeSink()
        addTeardownBlock { release.signal() }
        let turn = Task {
            await sink.routeToCloud(request: "answer", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: .wakeWord, utteranceId: utteranceId)
        }
        // Barrier on the PRODUCER-side fact: all seven frames are in the player before the
        // terminal is read. Without it the turn could end with no audio at all and the frame
        // count below would be satisfied by a turn that never received any.
        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        try await waitUntil("all seven frames reached the player", timeout: 5) {
            player.framesEnqueuedForTesting == 7
        }
        release.signal()
        _ = await turn.value

        let log = await FileLog.shared.logFileAsString()
        let mine = log.split(separator: "\n").map(String.init)
            .filter { $0.contains("cloudTurnLatency") && $0.contains("request_id=\(utteranceId) ") }
        XCTAssertEqual(mine.count, 1,
                       "an interrupted turn contributes exactly one timing record: \(mine)")
        let line = try XCTUnwrap(mine.first, "no timing record for the interrupted turn: \(log.suffix(2000))")
        XCTAssertTrue(line.contains("outcome=interrupted"),
                      "the record must name what happened, not label it a completion: \(line)")
        XCTAssertTrue(line.contains("audio_frames=7"),
                      "the seven frames this turn received are its own: \(line)")
        XCTAssertTrue(line.contains("buffer_cleared=1"),
                      "the interrupted turn's own cancel is the one clear: \(line)")
        // The audible leg is asserted as INTERNAL CONSISTENCY, not as a duration: whether this
        // host's engine renders is the host's business. A record that names an instant must also
        // name the leg to it; one that names none must say so rather than report zero.
        if line.contains("first_audible=absent") {
            XCTAssertTrue(line.contains("request_to_first_audible=none"),
                          "no audible instant means the leg is unmeasured, not zero: \(line)")
        } else {
            XCTAssertFalse(line.contains("request_to_first_audible=none"),
                           "a turn that reports an audible instant must report the leg to it: \(line)")
        }
    }

    /// THE AUDIBLE INSTANT SURVIVES THE STOP THE INTERRUPT REQUESTED
    /// (`cloud-assistant.md` → Conversational latency: the record carries the turn's first audible
    /// instant; the player's teardown clears its mark).
    ///
    /// The break this catches: reading the mark AFTER `awaitActualStop`. The stop that sheds the
    /// answer also clears the player's first-audible mark, so a turn the user actually HEARD before
    /// taking it back would be recorded as silent — the one case where knowing it was heard matters
    /// most, because it explains why the user interrupted.
    ///
    /// SCOPE: the sibling control above proves the record EXISTS with the right counters. This one
    /// pins the instant, which that test cannot see: its audio is never rendered, so it reads
    /// `first_audible=absent` either way. Audio is rendered here BEFORE the terminal, so there is a
    /// real instant to lose.
    ///
    /// WHAT IT PINS, precisely: the record carries the instant measured while the answer was
    /// playing. The player's own mark is nil by the time the terminal writes (measured), so the
    /// value can only come from the sink's per-event snapshot. This is a REGRESSION CONTROL on that
    /// property, not a mutation-proof of one line: the snapshot is taken at two points (loop top and
    /// audio admission) and either alone preserves the value, so removing one is not observable.
    @MainActor
    func testAnInterruptedTurnKeepsTheAudibleInstantItMeasuredBeforeTheStop() async throws {
        let utteranceId = "u-\(UUID().uuidString.prefix(12))-int-audible"
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        let fmt = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let engineBox = OfflineEngineBox()
        CloudAudioPlayer.configureEngineForTesting = { engine in
            try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4_096)
            engineBox.engine = engine
        }
        addTeardownBlock {
            CloudAudioPlayer.configureEngineForTesting = nil
            CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        }
        let release = DispatchSemaphore(value: 0)
        blockProducerAfterFrames = (8, release)
        nextTurnFixture = """
        event: done
        data: {"outcome":"interrupted","usage":{"input_tokens":1,"output_tokens":0}}

        """
        nextTurnAudioPayloads = (0..<7).map { _ in Data(repeating: 0x11, count: 4_800 * 2) }
        playback.setPlaying(true)
        let sink = makeSink()
        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)
        player.emittedPCMReference = reference
        player.echoReferenceHandoff = handoff
        addTeardownBlock { @MainActor in
            release.signal()
            player.openPhysicalStopGateForTesting()
            let stop = player.cancel()
            _ = await player.awaitActualStop(after: stop)
            withExtendedLifetime(handoff) {}
            withExtendedLifetime(sink) {}
        }
        // The request leg needs a send instant; without a context the record reports `none` for
        // every leg regardless of the audible mark, which would make this case vacuous.
        let latencyContext = TurnLatencyContext()
        latencyContext.endOfSpeech = 0
        let turn = Task {
            await sink.routeToCloud(request: "answer", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: .wakeWord, utteranceId: utteranceId,
                                    latency: LatencyHandle(latencyContext))
        }
        try await waitUntil("all seven frames reached the player", timeout: 5) {
            player.framesEnqueuedForTesting == 7
        }
        // Render the answer BEFORE the terminal, so the player has taken its first-audible mark
        // while the turn is still live. This is the premise the whole case rests on.
        let engineDeadline = Date().addingTimeInterval(5)
        while engineBox.engine == nil && Date() < engineDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let engine = try XCTUnwrap(engineBox.engine, "premise: the player built its offline engine")
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4_096))
        let renderDeadline = Date().addingTimeInterval(8)
        while player.firstAudibleHostSeconds == nil && Date() < renderDeadline {
            _ = try? engine.renderOffline(1_024, to: output)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let measuredBeforeTerminal = player.firstAudibleHostSeconds
        XCTAssertNotNil(measuredBeforeTerminal,
                        "premise: the answer was audible BEFORE the interrupt, so there is an instant to lose")
        release.signal()
        _ = await turn.value

        let log = await FileLog.shared.logFileAsString()
        let line = try XCTUnwrap(
            log.split(separator: "\n").map(String.init)
                .first { $0.contains("cloudTurnLatency") && $0.contains("request_id=\(utteranceId) ") },
            "the interrupted turn must contribute a record")
        XCTAssertTrue(line.contains("outcome=interrupted"), line)
        XCTAssertFalse(line.contains("first_audible=absent"),
                       "an answer heard before the interrupt must not be recorded as silent: \(line)")
        // The leg is named EXACTLY, not by substring: `end_of_speech_to_first_audible=` contains
        // `to_first_audible=`, so a loose match would be satisfied by the other field.
        let leg = line.split(separator: " ").first { $0.hasPrefix("end_of_speech_to_first_audible=") }
        let value = leg.flatMap { $0.split(separator: "=").last }.map(String.init)
        XCTAssertNotNil(value, "the record carries the end-of-speech leg: \(line)")
        XCTAssertNotEqual(value, "none",
                          "an answer heard before the interrupt has a measured audible leg: \(line)")
        // And it is the instant measured BEFORE the stop, not a later read: the mark never moves
        // once taken, so the reported leg must match the one the premise observed.
        let reportedMs = Double((value ?? "").replacingOccurrences(of: "ms", with: ""))
        let expectedMs = try XCTUnwrap(measuredBeforeTerminal) * 1000
        XCTAssertEqual(try XCTUnwrap(reportedMs), expectedMs, accuracy: 1.0,
                       "the record reports the instant taken while the answer was playing: \(line)")
    }

    /// THE RACE THE CONTRACT NAMES (`cloud-assistant.md` → Interruption): "A terminal `done` for
    /// that request that races the interrupt is also settlement acknowledgement, even with
    /// `outcome: \"completed\"`: do not wait for a second terminal or reopen the closed socket."
    ///
    /// The break this catches: gating settlement on the outcome matching the interrupt. A server
    /// that had already finished when the interrupt arrived sends `completed`, and a client that
    /// insisted on `interrupted` would park until its deadline and drop the utterance the user
    /// spoke. Asserted on the RELEASE and the submission count, not on the outcome value.
    func testACompletedDoneRacingTheInterruptStillSettlesItOnce() async {
        let state = CloudInterruptionState()
        // Arm exactly as the production emit point does: one shot claimed, follow-up held against
        // the turn being interrupted.
        XCTAssertTrue(state.claimInterruptEmission(forRequestId: "u-raced"))
        XCTAssertTrue(state.hold(request: "play the next one", utteranceId: "u-after-race",
                                 origin: cloudTestOrigin, forRequestId: "u-raced"))
        // `completed`, NOT `interrupted`: the server finished before it saw the interrupt.
        self.nextTurnFixture = """
        event: done
        data: {"outcome":"completed","usage":{"input_tokens":1,"output_tokens":1}}

        """
        let sink = makeSink(interruptionState: state)
        let result = await sink.routeToCloud(
            request: "what about the second one", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-raced"
        )
        XCTAssertEqual(result.outcome, .completed, "premise: the racing terminal really was a completion")
        let released = await MainActor.run { sink.takeReleasedInterruptionFollowUp() }
        XCTAssertEqual(released?.utteranceId, "u-after-race",
                       "a completed terminal that races the interrupt IS the acknowledgement")
        let again = await MainActor.run { sink.takeReleasedInterruptionFollowUp() }
        XCTAssertNil(again, "released exactly once, so the utterance cannot be submitted twice")
        let frames = capturedTask?.sentTextFrames ?? []
        XCTAssertEqual(frames.count, 1,
                       "no second terminal is awaited and no extra frame is sent: \(frames)")
    }

    /// A refused STALE turn must leave the held live successor's AUDIO OUTPUT intact.
    ///
    /// Distinct from `testARefusedStaleTurnDoesNotCancelTheHeldLiveSuccessor`, which asserts the
    /// successor still COMPLETES. Completion is not output: a successor could finish while its
    /// audio was never delivered or was discarded.
    func testARefusedStaleTurnLeavesTheHeldSuccessorsAudioOutputIntact() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = [Self.audioPayload]
        let gate = holdNextTurn()
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(conversationManager: manager)

        let live = Task {
            await sink.routeToCloud(
                request: "live", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .wakeWord
            , utteranceId: "u-84")
        }
        let maybeHeld = await waitForHeldTurn()
        _ = try XCTUnwrap(maybeHeld, "the live turn never reached the socket")

        // The window moves on, so the next turn's captured origin is genuinely stale.
        manager.registerLiveOrigin(cloudTestOrigin + 1)
        let staleResult = await sink.routeToCloud(
            request: "stale", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp
        , utteranceId: "u-85")
        XCTAssertEqual(staleResult.outcome, .refused, "the stale turn must be refused")

        gate.release()
        let liveResult = await live.value
        XCTAssertEqual(liveResult.outcome, .completed, "the held successor must still complete")

        // THE OUTPUT ASSERTION: the successor's audio actually reached the player and drained,
        // so the stale refusal neither suppressed nor discarded the live turn's output.
        //
        // The drain is observed with a BOUNDED WAIT rather than a single read: playback drains on
        // the player's own task, so a read taken straight after completion can still see the last
        // frames and the case then failed intermittently with no code change.
        var enqueued: Int?
        var pending: Bool?
        let drainDeadline = Date().addingTimeInterval(5)
        while Date() < drainDeadline {
            enqueued = await MainActor.run { sink.audioPlayerForTesting?.framesEnqueuedForTesting }
            pending = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio }
            if (enqueued ?? 0) > 0 && pending == false { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // SCOPE: DELIVERY, not rendering — see the note in the positive control above. What these
        // two facts establish together is that the successor's audio was still handed to the
        // player after the stale refusal, and that the buffer was not left holding it.
        XCTAssertTrue(
            (enqueued ?? 0) > 0,
            "the held successor's audio must still be DELIVERED to the player despite the stale refusal"
        )
        XCTAssertEqual(pending, false, "the successor's audio buffer must be empty, not left holding frames")
    }

    /// A small, valid binary payload: the transport treats any `.data` frame as audio.
    static let audioPayload = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

    /// The HELD-LIVE / STALE-REFUSAL ordering, deterministic by driving the REAL drain event.
    ///
    /// The completion is deliberately SPLIT: when audio is still pending at `done`, the sink returns
    /// `.completed` and defers restoration to `audioPlayerDidStop`, so the answer is not played over
    /// the resumed episode. Awaiting the route's return therefore stops BEFORE restoration, which is
    /// why an earlier attempt saw the resume appear on some runs and not others. This case drives
    /// the drain event the player actually sends, so restoration is awaited rather than raced.
    func testHeldLiveStaleRefusalOrderingIsDeterministicAndRestoresPlayback() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        let gate = holdNextTurn()
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(conversationManager: manager)

        // Playback RUNNING before the hold, so the live turn takes one.
        playback.setPlaying(true)
        playback.setPositionMs(60_000)

        self.nextTurnAudioPayloads = [Self.audioPayload]
        let live = Task {
            await sink.routeToCloud(
                request: "live", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .wakeWord
            , utteranceId: "u-86")
        }

        // BARRIER: the live turn acquired its hold.
        try await waitUntil("the live turn acquired its hold") {
            playback.calls.contains(.pause)
        }
        XCTAssertEqual(playback.calls.filter { $0 == .pause }.count, 1, "one hold")
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 0, "nothing resumes yet")
        XCTAssertFalse(playback.isPlaying, "the hold is in effect")

        // A stale request is refused while the successor is held.
        manager.registerLiveOrigin(cloudTestOrigin + 1)
        let staleResult = await sink.routeToCloud(
            request: "stale", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp
        , utteranceId: "u-87")
        XCTAssertEqual(staleResult.outcome, .refused, "the stale turn must be refused")

        // THE REFUSED REQUEST CHANGED NEITHER THE HOLD NOR THE COUNTS.
        XCTAssertEqual(playback.calls.filter { $0 == .pause }.count, 1, "refusal must not pause")
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 0, "refusal must not resume")
        XCTAssertFalse(playback.isPlaying, "the refusal must not release the successor's hold")

        // Release the successor: it delivers its audio and returns .completed.
        gate.release()
        let liveResult = await live.value
        XCTAssertEqual(liveResult.outcome, .completed, "the held successor must complete")

        // THE SUCCESSOR'S AUDIO WAS DELIVERED, and because it was still pending at `done` the
        // restoration is deferred — so drive the drain event the player sends.
        let enqueued = await MainActor.run { sink.audioPlayerForTesting?.framesEnqueuedForTesting }
        XCTAssertTrue((enqueued ?? 0) > 0, "the successor's audio must reach the player")
        let currentEpoch = await MainActor.run { sink.audioPlayerForTesting?.currentDrainEpoch ?? 0 }
        await MainActor.run { sink.audioPlayerDidStop(drainEpoch: currentEpoch) }

        // ONLY NOW must restoration have happened: the live owner released its hold exactly once.
        XCTAssertEqual(
            playback.calls.filter { $0 == .pause }.count, 1,
            "exactly one pause: the live turn's, with nothing added by the refused request"
        )
        XCTAssertEqual(
            playback.calls.filter { $0 == .resume }.count, 1,
            "exactly one resume: the live owner's, on drain"
        )
        XCTAssertTrue(
            playback.isPlaying,
            "playback must return to its pre-hold (running) state"
        )
    }

    /// The SINGLE-OWNER deferred-restoration positive.
    ///
    /// One turn, owned end to end: its own task, its own prepared frame's request_id, its binary
    /// audio, its `done`, and its own drain. With audio still pending at `done` the sink defers
    /// restoration, and the release of the drain lets the player's REAL stop notification run —
    /// asserted on the same turn, so a mismatch between the turn that carried the audio and the
    /// turn the assertions read would fail.
    func testSingleOwnerPendingAudioDefersRestorationUntilItsOwnDrain() async throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(conversationManager: manager)

        playback.setPlaying(true)
        playback.setPositionMs(60_000)

        let maybePlayer = await MainActor.run { sink.audioPlayerForTesting }
        let owningPlayer = try XCTUnwrap(maybePlayer, "the sink must own an audio player")
        await MainActor.run { owningPlayer.setDrainHoldForTesting(true) }
        defer { Task { @MainActor in owningPlayer.setDrainHoldForTesting(false) } }

        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = [Self.audioPayload]
        let result = await sink.routeToCloud(
            request: "audio", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord
        , utteranceId: "u-88")

        // IDENTITY: the turn that ran is the turn this case built, named by its own prepared frame.
        let task = try XCTUnwrap(capturedTask, "the turn must have built its own transport task")
        let frame = try XCTUnwrap(task.sentAuthFrame, "the turn's own prepared frame must be readable")
        let requestId = try XCTUnwrap(frame["request_id"] as? String, "the frame carries a request_id")
        XCTAssertEqual(requestId, "u-88", "the wire request_id IS the turn's admitted utterance id (delta f47e972)")
        XCTAssertEqual(result.outcome, .completed, "this turn completes at `done`")

        let pending = await MainActor.run { owningPlayer.hasPendingAudio }
        XCTAssertTrue(pending, "this turn's audio is still PENDING at its `done`")

        // DEFERRAL: this turn completed, and nothing has resumed for it yet.
        XCTAssertTrue(playback.calls.contains(.pause), "this turn took its hold")
        XCTAssertEqual(
            playback.calls.filter { $0 == .resume }.count, 0,
            "restoration is DEFERRED while this turn's audio is pending"
        )
        XCTAssertFalse(playback.isPlaying, "the hold is still in effect before the drain")

        // RELEASE the drain. The player then drains for real and emits its OWN stop notification —
        // no manual stop-callback invocation, so the deferred callback is reached through the
        // production path rather than being called by the test.
        await MainActor.run { owningPlayer.setDrainHoldForTesting(false) }

        // The restoration is signalled by the resume landing, awaited rather than read once.
        try await waitUntil("the deferred restoration ran after the real drain") {
            playback.calls.filter { $0 == .resume }.count == 1
        }
        XCTAssertTrue(playback.isPlaying, "playback returns to its pre-hold running state")
    }

    /// A's CAPTURED, REAL stop notification must not restore once B owns the hold.
    ///
    /// Per @reviewer's interleaving, with no second pause required:
    ///   1. A completes with audio pending, so its restoration is deferred;
    ///   2. A's real drain produces its notification, which is CAPTURED rather than delivered;
    ///   3. B starts and INHERITS the outstanding hold (by design), held before its `done`;
    ///   4. the captured notification is released while B is in flight;
    ///   5. zero resumes while B still owns the hold.
    ///
    /// Clearing the shared flag prevents a DUPLICATE restoration; this asks whether the FIRST
    /// notification restores too early, which is the obligation the case names.
    func testACapturedOlderTurnNotificationDoesNotRestoreWhileTheInheritorIsInFlight() async throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(conversationManager: manager)

        let maybePlayer = await MainActor.run { sink.audioPlayerForTesting }
        let player = try XCTUnwrap(maybePlayer, "the sink must own an audio player")

        // CAPTURE A's real notification instead of letting it be delivered.
        var capturedNotification: (() -> Void)?
        await MainActor.run {
            player.setCapturedStopNotificationForTesting { _, deliver in capturedNotification = deliver }
        }
        defer { Task { @MainActor in player.setCapturedStopNotificationForTesting(nil) } }

        // (1) TURN A: completes with audio pending -> deferred.
        playback.setPlaying(true)
        playback.setPositionMs(60_000)
        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = [Self.audioPayload]
        let a = await sink.routeToCloud(
            request: "A", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord
        , utteranceId: "u-89")
        XCTAssertEqual(a.outcome, .completed, "turn A returns")
        XCTAssertEqual(
            playback.calls.filter { $0 == .resume }.count, 0,
            "turn A defers: its drain has not produced a notification yet"
        )

        // (2) A's REAL drain produces its notification, captured.
        await MainActor.run { player.setDrainHoldForTesting(false) }
        try await waitUntil("turn A's real drain produced its stop notification") {
            capturedNotification != nil
        }
        let deliverAsNotification = try XCTUnwrap(capturedNotification, "A's notification must exist")

        // (3) TURN B: starts and INHERITS the hold, held before its `done`.
        let gate = holdNextTurn()
        self.nextTurnFixture = Self.doneOnlyFixture
        let b = Task {
            await sink.routeToCloud(
                request: "B", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .followUp
            , utteranceId: "u-90")
        }
        let maybeHeldB = await waitForHeldTurn()
        let heldB = try XCTUnwrap(maybeHeldB, "turn B must be in flight and holding")
        // B's distinct identity, from ITS OWN prepared frame. Being HELD is not the same as having
        // AUTHENTICATED: the hold parks the receive before the auth frame goes out, so wait for the
        // frame itself rather than reading it the instant the hold appears.
        var bFrame: [String: Any]?
        for _ in 0..<600 {
            bFrame = heldB.task.sentAuthFrame
            if bFrame != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let bFrameUnwrapped = try XCTUnwrap(bFrame, "B's prepared frame must be readable")
        let bRequestId = try XCTUnwrap(bFrameUnwrapped["request_id"] as? String, "B carries a request_id")
        XCTAssertEqual(bRequestId, "u-90", "B's wire request_id IS B's admitted utterance id (delta f47e972)")

        let resumesBeforeNotification = playback.calls.filter { $0 == .resume }.count
        XCTAssertFalse(playback.isPlaying, "the inherited hold is in effect while B is in flight")

        // (4) Release A's captured notification WHILE B is in flight and owning.
        await MainActor.run { deliverAsNotification() }

        // (5) Zero resumes for a notification that is not B's.
        XCTAssertEqual(
            playback.calls.filter { $0 == .resume }.count, resumesBeforeNotification,
            "A's captured notification must not restore while its INHERITOR is still in flight"
        )
        XCTAssertFalse(
            playback.isPlaying,
            "the inheriting turn's hold must survive an older turn's notification"
        )

        gate.release()
        _ = await b.value
    }

    /// @reviewer's conjunct case: B has ITSELF deferred, then A's OLD notification arrives.
    ///
    /// At `7e8e7fde8` this passed the owner check, because both `activeTurn` and the deferred record
    /// contained B — so A's notification restored and CLEARED B's deferred record. Identity of the
    /// arriving stop is what distinguishes them, so the notification carries the identity captured
    /// when it was scheduled.
    func testAnOldNotificationDoesNotClearTheDeferringSuccessorsRecord() async throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(conversationManager: manager)

        let maybePlayer = await MainActor.run { sink.audioPlayerForTesting }
        let player = try XCTUnwrap(maybePlayer, "the sink must own an audio player")

        var capturedNotifications: [() -> Void] = []
        await MainActor.run {
            player.setCapturedStopNotificationForTesting { _, deliver in capturedNotifications.append(deliver) }
        }
        defer { Task { @MainActor in player.setCapturedStopNotificationForTesting(nil) } }

        // A DEFERS.
        playback.setPlaying(true)
        playback.setPositionMs(60_000)
        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = [Self.audioPayload]
        let a = await sink.routeToCloud(
            request: "A", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord
        , utteranceId: "u-91")
        XCTAssertEqual(a.outcome, .completed, "turn A returns")
        await MainActor.run { player.setDrainHoldForTesting(false) }
        try await waitUntil("A produced its stop notification") { !capturedNotifications.isEmpty }
        let aNotification = capturedNotifications[0]

        // B ALSO DEFERS, so `activeTurn` and the deferred record both name B.
        await MainActor.run { player.setDrainHoldForTesting(true) }
        playback.setPlaying(true)
        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = [Self.audioPayload]
        let b = await sink.routeToCloud(
            request: "B", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp
        , utteranceId: "u-92")
        XCTAssertEqual(b.outcome, .completed, "turn B returns")
        let resumesBeforeA = playback.calls.filter { $0 == .resume }.count

        // A's OLD notification arrives while B is the deferred owner.
        await MainActor.run { aNotification() }

        XCTAssertEqual(
            playback.calls.filter { $0 == .resume }.count, resumesBeforeA,
            "A's old notification must not restore: B is the deferring owner"
        )

        // B's OWN drain must still be able to restore — the old notification must leave B's record
        // intact rather than clearing it.
        await MainActor.run { player.setDrainHoldForTesting(false) }
        try await waitUntil("B's own drain produced its notification") { capturedNotifications.count >= 2 }
        let bNotification = capturedNotifications[1]
        await MainActor.run { bNotification() }

        XCTAssertEqual(
            playback.calls.filter { $0 == .resume }.count, resumesBeforeA + 1,
            "B's own notification must still restore, so A's arrival did not clear B's record"
        )
    }

    /// SEQUENTIAL OWNERSHIP (NOT overlap): two dispatches in turn on ONE sink, each carrying its OWN
    /// observer, must each capture their own prepared identity.
    ///
    /// SCOPE, measured rather than assumed: this case does NOT demonstrate that OVERLAPPING
    /// dispatches are isolated. It was falsified against a shared-slot mutation and SURVIVED, because
    /// the two turns run sequentially — a shared slot agrees with the correct value when nothing
    /// overlaps. Demonstrating overlap would need a second dispatch to publish between A's
    /// preparation and A's observation; the socket gate parks downstream of preparation, so this
    /// arrangement cannot create that window. Do not cite this case as overlap isolation.
    @MainActor
    func testSequentialDispatchesEachCaptureTheirOwnPreparedIdentity() async throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(conversationManager: manager)

        var preparedA: CloudPreparedConversation?
        var preparedB: CloudPreparedConversation?

        // Each dispatch needs its own fixture: the handoff is consumed per built turn.
        self.nextTurnFixture = Self.doneOnlyFixture
        // A: a wake-word turn under the live generation.
        let a = await sink.routeToCloud(
            request: "A", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord,
            utteranceId: "u-93",
            preparedObserver: { prepared in preparedA = prepared })
        XCTAssertEqual(a.outcome, .completed, "turn A completes")

        // B: a second dispatch on the SAME sink, with its OWN observer.
        self.nextTurnFixture = Self.doneOnlyFixture
        let b = await sink.routeToCloud(
            request: "B", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp,
            utteranceId: "u-94",
            preparedObserver: { prepared in preparedB = prepared })
        XCTAssertEqual(b.outcome, .completed, "turn B completes")

        // The two observations DIFFER, which proves they are distinct observations. It does NOT
        // prove attribution — that each observer received ITS OWN turn's value — and it does not
        // rule out a shared slot read per dispatch. This sequential arrangement does not test overlap.
        let aValue = try XCTUnwrap(preparedA, "A's observer must have captured A's prepared identity")
        let bValue = try XCTUnwrap(preparedB, "B's observer must have captured B's prepared identity")
        XCTAssertNotEqual(
            aValue.requestId, bValue.requestId,
            "each dispatch must capture its OWN prepared identity; equal values mean a shared slot"
        )
    }
}

/// The client-generated-diagnostic convention (PR #19 review): a code with an
/// empty message maps to a localized template when one exists, and to the error
/// earcon when it doesn't — both branches exercised, so neither is inert.
final class CloudRouteSinkErrorLocalizationTests: SocketCapturingTestCase {
    private var playback: RecordingPlaybackSink!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        suiteName = "cloud_error_loc_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTemplatedCodeIsSpoken() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"connection_lost","message":""}

            """
        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-95")

        XCTAssertEqual(response.response, .spoken("Connection lost. Please try again."), "a code with a template is spoken")
    }

    func testCodeWithoutATemplateUsesTheErrorEarcon() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"invalid_response","message":""}

            """
        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-96")

        XCTAssertEqual(response.response, .earcon(.error), "an internal diagnostic stays an earcon, never English prose")
    }

    private func makeSink() -> CloudRouteSink {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let session = URLSession(configuration: config)
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(baseURL: cloudConfig.baseUrl, fixture: self.nextFixture())
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: RecordingFingerprintMapper(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            conversationManager: testConversationManager()
        )
    }

    private func sampleContext() -> PlaybackContext {
        PlaybackContext(episodeId: "ep", podcastId: "pod", referencePositionMs: 1_000, clientPositionMs: 1_100, recentReferencePositions: [], previousReferencePositionMs: nil)
    }
}

/// Spec ruling (2026-09-24): a client-authored message is spoken **only** in the
/// user's own locale; an untranslated key falls back to the error earcon rather
/// than to base-language English.
final class CloudRouteSinkLocaleRuleTests: SocketCapturingTestCase {
    private var playback: RecordingPlaybackSink!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        suiteName = "cloud_locale_rule_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSink(localeBundle: Bundle?) -> CloudRouteSink {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(baseURL: cloudConfig.baseUrl, fixture: self.nextFixture())
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: RecordingFingerprintMapper(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            spokenTemplates: SpokenTemplateResolver(localeBundle: localeBundle),
            conversationManager: testConversationManager()
        )
    }

    private func stubError(code: String) {
        self.pendingFixture =
            """
            event: error
            data: {"code":"\(code)","message":""}

            """
    }

    private func context() -> PlaybackContext {
        PlaybackContext(episodeId: "ep", podcastId: "pod", referencePositionMs: 1_000, clientPositionMs: 1_100, recentReferencePositions: [], previousReferencePositionMs: nil)
    }

    func testUntranslatedKeyFallsBackToTheEarconRatherThanBaseLanguageSpeech() async {
        // A **real** localization that exists but carries no VoiceTemplates table
        // (ca.lproj ships InfoPlist/Intents/Localizable but no VoiceTemplates) —
        // the production shape, rather than an empty directory (PR #19 review).
        let caPath = Bundle.main.path(forResource: "ca", ofType: "lproj")
        let empty = caPath.flatMap { Bundle(path: $0) } ?? Bundle(path: NSTemporaryDirectory()) ?? Bundle(for: type(of: self))
        stubError(code: "connection_lost")
        let response = await makeSink(localeBundle: empty).routeToCloud(request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-97")
        XCTAssertEqual(response.response, .earcon(.error), "no translation in the user's locale ⇒ earcon, never English speech")
    }

    /// The default resolver discovers the user's own locale: in this test host that
    /// is English, whose bundle carries the key, so the message is spoken.
    func testDefaultResolverUsesTheUsersOwnLocale() {
        let resolver = SpokenTemplateResolver()
        XCTAssertEqual(
            resolver.resolveForUserLocale("cloud_error_connection_lost"),
            "Connection lost. Please try again."
        )
    }

    func testTranslatedKeyInTheUserLocaleIsSpoken() async {
        stubError(code: "connection_lost")
        // The test host's own bundle carries the en.lproj translation.
        let enBundle = Bundle(path: Bundle.main.path(forResource: "en", ofType: "lproj") ?? "") ?? Bundle.main
        let response = await makeSink(localeBundle: enBundle).routeToCloud(request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-98")
        XCTAssertEqual(response.response, .spoken("Connection lost. Please try again."))
    }
}

/// Spec clarification 27ced9b: a `limit_exceeded` turn must reach the user as the CLIENT's own
/// localized daily-limit template, exactly once, naming Auris and its daily allowance — and the
/// remote frame's `message` is DIAGNOSTIC-ONLY for this code, so it must not replace that
/// explanation.
@MainActor
final class CloudRouteSinkLimitExceededFeedbackTests: SocketCapturingTestCase {
    private var playback: RecordingPlaybackSink!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        suiteName = "cloud_limit_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSink() -> CloudRouteSink {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let cloudConfig = CloudConfig(defaults: defaults)
        // The test host's own bundle carries en.lproj/VoiceTemplates.strings.
        let enBundle = Bundle(path: Bundle.main.path(forResource: "en", ofType: "lproj") ?? "") ?? Bundle.main
        return CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(baseURL: cloudConfig.baseUrl, fixture: self.nextFixture())
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: RecordingFingerprintMapper(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            spokenTemplates: SpokenTemplateResolver(localeBundle: enBundle),
            conversationManager: testConversationManager()
        )
    }

    private func context() -> PlaybackContext {
        PlaybackContext(episodeId: "ep", podcastId: "pod", referencePositionMs: 1_000, clientPositionMs: 1_100, recentReferencePositions: [], previousReferencePositionMs: nil)
    }

    /// The refusal frame the server actually sends carries a GENERIC message ("this turn was not
    /// admitted"). The user must still hear WHICH limit was hit, exactly once.
    func testLimitExceededSpeaksTheClientTemplateNotTheGenericRemoteMessage() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"limit_exceeded","message":"this turn was not admitted"}

            """
        let response = await makeSink().routeToCloud(
            request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil
        , utteranceId: "u-99")
        XCTAssertEqual(
            response.response,
            .spoken("You have reached your Auris free daily limit. Please try again tomorrow."),
            "limit_exceeded must speak the client's own template naming Auris and the daily limit"
        )
        // EXACTLY ONCE, not merely "contains": the response is a single .spoken value, and it is
        // not the generic remote text.
        guard case let .spoken(text) = response.response else {
            XCTFail("expected a single .spoken response, got \(response.response)")
            return
        }
        XCTAssertNotEqual(text, "this turn was not admitted", "the remote diagnostic must not be spoken")
        XCTAssertEqual(text.components(separatedBy: "Auris").count - 1, 1, "Auris is named exactly once")
    }

    /// THE REMOTE MESSAGE IS NEVER SPOKEN (spec 961fab07) — and not only for `limit_exceeded`.
    /// A non-limit code whose frame carries a nonempty `message` must NOT speak that text: the
    /// old pass-through behaviour is superseded by the diagnostic-only contract.
    func testNonLimitRemoteMessageIsNotSpoken() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"provider_error","message":"upstream 502 from model-vendor-a"}

            """
        let response = await makeSink().routeToCloud(
            request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil
        , utteranceId: "u-100")
        // `provider_error` is Generic with no local template ⇒ the error earcon. What must NOT
        // happen is the operator diagnostic reaching the speaker.
        XCTAssertEqual(
            response.response, .earcon(.error),
            "a remote operator diagnostic must never be spoken"
        )
        if case let .spoken(text) = response.response {
            XCTAssertFalse(
                text.contains("model-vendor-a"),
                "the remote message leaked into speech: \(text)"
            )
        }
    }

    /// An UNKNOWN code (not in the vocabulary) follows the same local feedback policy: never the
    /// remote text.
    func testUnknownRemoteCodeNeverSpeaksTheRemoteMessage() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"some_unmapped_code","message":"secret operator detail 42"}

            """
        let response = await makeSink().routeToCloud(
            request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil
        , utteranceId: "u-101")
        XCTAssertEqual(response.response, .earcon(.error), "an unknown code gets local feedback, not remote text")
        if case let .spoken(text) = response.response {
            XCTAssertFalse(text.contains("42"), "the remote message leaked into speech: \(text)")
        }
        XCTAssertEqual(response.outcome, .failed(code: "some_unmapped_code"))
    }

    /// A client-authored code reaches the user as a failed turn, never a completion (the
    /// pre-existing regression guard, re-asserted for this code).
    func testLimitExceededIsAFailedTurnNotACompletion() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"limit_exceeded","message":""}

            """
        let response = await makeSink().routeToCloud(
            request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil
        , utteranceId: "u-102")
        XCTAssertEqual(response.outcome, .failed(code: "limit_exceeded"))
    }

    /// SERVICE-TO-RENDERER, DUPLICATE AND TERMINAL-CLOSE (spec a8580c0c). An executor return
    /// value from an always-owner mock does not establish exactly-once USER FEEDBACK, so this
    /// runs the whole path against the REAL sink and the REAL AudioFeedbackRenderer: an owner
    /// refusal turn, a DUPLICATE of the same utterance, and a terminal-close variant. The user must
    /// hear the daily-limit line EXACTLY ONCE, and a refused turn must not extend grace.
    @MainActor
    /// E2E REQUEST-ID PROPAGATION (reviewer d16c0246): the utterance-admitted identity must
    /// reach the wire VERBATIM. ASR mints the id at admission, the sink prepares the conversation
    /// with it, and the socket auth frame presents THAT literal string — no hop downstream may
    /// mint a fresh one. A duplicate dispatch of the SAME utterance observes the settled outcome
    /// and never opens a second wire dispatch under a second identity.
    func test_admittedUtteranceIdReachesTheWireVerbatimAndDuplicateNeverMintsAnother() async throws {
        self.pendingFixture = """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let context = PlaybackContext(
            episodeId: "ep", podcastId: "pod",
            referencePositionMs: 1_000, clientPositionMs: 1_100,
            recentReferencePositions: [], previousReferencePositionMs: nil
        )
        let sink = makeSink()
        let owner = await sink.routeToCloud(
            request: "play the news", tier: .free, context: context,
            origin: cloudTestOrigin, selection: nil, utteranceId: "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88"
        )
        let ownerFrame = try XCTUnwrap(capturedTask?.sentAuthFrame)
        XCTAssertEqual(
            ownerFrame["request_id"] as? String, "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88",
            "the wire request_id is the ADMITTED utterance UUID, not a freshly minted one"
        )

        // Duplicate of the SAME utterance: the settled result, no new dispatch, no second id.
        capturedTask = nil
        let duplicate = await sink.routeToCloud(
            request: "play the news", tier: .free, context: context,
            origin: cloudTestOrigin, selection: nil, utteranceId: "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88"
        )
        XCTAssertEqual(duplicate, owner, "the duplicate observes the owner's settled outcome")
        XCTAssertNil(
            capturedTask?.sentAuthFrame,
            "a settled duplicate must not open a second wire dispatch"
        )
    }

    func test_dailyLimitFeedbackRendersExactlyOnceAcrossDuplicateAndTerminalClose() async throws {
        let grace = GracePeriodSignal()
        grace.onWakeWordDetected()
        let generation = grace.currentGeneration()
        XCTAssertTrue(grace.claimRefusalTone(), "a refusal was announced (window spent)")

        self.pendingFixture =
            """
            event: error
            data: {"code":"limit_exceeded","message":"this turn was not admitted"}

            """
        let sink = makeSink()
        let executor = VoiceIntentExecutor(
            playbackSink: NoOpCloudPlaybackSink(),
            effectsSink: NoOpCloudEffectsSink(),
            volumeSink: NoOpCloudVolumeSink(),
            sleepSink: NoOpCloudSleepSink(),
            chapterSink: NoOpCloudChapterSink(),
            bookmarkSink: NoOpCloudBookmarkSink(),
            queueSink: NoOpCloudQueueSink(),
            playbackQuerySink: NoOpCloudPlaybackQuerySink(),
            statsQuerySink: NoOpCloudStatsQuerySink(),
            cloudRouteSink: sink,
            playbackContextProvider: NoOpCloudPlaybackContextProvider(),
            gracePeriodSignal: grace
        )
        let tts = CountingDailyLimitTtsEngine()
        let renderer = AudioFeedbackRenderer(
            earconPlayer: SilentCloudEarconPlayer(), ttsEngine: tts, ducker: NoOpCloudDucker()
        )

        let utterance = "limit-utterance-\(UUID().uuidString)"
        // OWNER turn: renders the daily-limit line.
        let owner = await executor.execute(CloudRouteIntent(
            request: "play something", tier: .free,
            utteranceId: utterance, origin: .modelCall, generation: generation, latency: LatencyHandle()))
        renderer.render(owner)
        XCTAssertEqual(
            owner,
            .spoken("You have reached your Auris free daily limit. Please try again tomorrow.")
        )
        // DUPLICATE of the SAME utterance: the sink settles it and the executor renders nothing.
        let duplicate = await executor.execute(CloudRouteIntent(
            request: "play something", tier: .free,
            utteranceId: utterance, origin: .modelCall, generation: generation, latency: LatencyHandle()))
        renderer.render(duplicate)
        // TERMINAL CLOSE on a FRESH utterance (stream ends without a terminal frame).
        self.pendingFixture = ""
        let closeResponse = await executor.execute(CloudRouteIntent(
            request: "play something", tier: .free,
            utteranceId: "limit-close-\(UUID().uuidString)", origin: .modelCall, generation: generation,
            latency: LatencyHandle()
        ))
        renderer.render(closeResponse)

        // Let any late render land, then assert the TOTAL is exactly one.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            tts.dailyLimitUtterances, 1,
            "the daily-limit line must be rendered EXACTLY ONCE across owner, duplicate and close"
        )
        XCTAssertFalse(
            grace.windowIsRenewedForTesting(),
            "a refused turn must not extend the grace window"
        )
    }

    /// EVERY SUPPORTED RESPONSE LANGUAGE CARRIES THE DAILY-LIMIT KEY (spec c259dc64). The scope is
    /// exactly en/de/es/fr/ja/ko/zh/yue: an English entry alone does not satisfy localized
    /// daily-limit feedback, and a Chinese turn must not be answered by an English earcon. This
    /// uses the REAL resolver's own locale discovery (`SpokenTemplateResolver(locale:)`), not a
    /// forced en bundle.
    func test_dailyLimitKeyResolvesInEverySupportedResponseLanguage() {
        // Every locale name the resolver can be handed. "zh" is covered by zh-Hans/zh-Hant.
        let cases: [(locale: String, bundleName: String)] = [
            ("en", "en"), ("de", "de"), ("es", "es"), ("fr", "fr"),
            ("ja", "ja"), ("ko", "ko"), ("zh-Hans", "zh-Hans"), ("zh-Hant", "zh-Hant"),
            ("yue", "yue"),
        ]
        for c in cases {
            guard let bundle = Bundle.main.path(forResource: c.bundleName, ofType: "lproj").flatMap({ Bundle(path: $0) }) else {
                XCTFail("\(c.bundleName).lproj is missing from the app bundle")
                continue
            }
            let resolver = SpokenTemplateResolver(localeBundle: bundle)
            let text = resolver.resolveForUserLocale("cloud_error_limit_exceeded")
            XCTAssertFalse(
                text.isEmpty,
                "\(c.locale) has no daily-limit template: a non-English user would hear only an earcon"
            )
            XCTAssertTrue(
                text.contains("Auris"),
                "\(c.locale) daily-limit text must name Auris (got: \(text))"
            )
        }
    }

    /// The RESOLVER FINDS each of those languages from the user's own locale — the production
    /// discovery path, not an injected bundle.
    func test_dailyLimitKeyResolvesInRegionalLocaleVariantsSelectedByRealDiscovery() {
        // Reviewer cffd67d1: the app ships fr-CA.lproj and es-MX.lproj, and REAL locale
        // discovery hands the resolver those regional bundles for fr_CA/es_MX users — a
        // base-identifier-only list misses them and returns empty. Both regional variants
        // must carry the key AND discovery must select them from the user's own locale.
        for localeID in ["fr_CA", "es_MX"] {
            // lproj directories are named with a HYPHEN ("fr-CA.lproj"), so the resource
            // lookup uses the hyphenated form even for an underscore Locale identifier.
            let dirName = localeID.replacingOccurrences(of: "_", with: "-")
            guard let path = Bundle.main.path(forResource: dirName, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                XCTFail("\(dirName).lproj is missing from the app bundle")
                continue
            }
            let resolver = SpokenTemplateResolver(locale: Locale(identifier: localeID))
            let text = resolver.resolveForUserLocale("cloud_error_limit_exceeded")
            XCTAssertFalse(
                text.isEmpty,
                "\(localeID) discovers a bundle without the daily-limit template: a regional user would hear only an earcon"
            )
            XCTAssertTrue(
                text.contains("Auris"),
                "\(localeID) daily-limit text must name Auris (got: \(text))"
            )
        }
    }

    func test_dailyLimitKeyIsFoundByRealLocaleDiscovery() {
        for identifier in ["en", "de", "es", "fr", "ja", "ko", "zh-Hans", "yue"] {
            let resolver = SpokenTemplateResolver(locale: Locale(identifier: identifier))
            let text = resolver.resolveForUserLocale("cloud_error_limit_exceeded")
            XCTAssertFalse(
                text.isEmpty,
                "the resolver did not discover a daily-limit template for \(identifier)"
            )
            XCTAssertTrue(text.contains("Auris"), "\(identifier) text must name Auris: \(text)")
        }
    }

    /// The template ships with the app, so it resolves through the SAME code-keyed route every
    /// other client failure uses (no special-case lookup that could go missing).
    func testLimitExceededTemplateResolvesThroughTheCodeKeyedRoute() {
        let enBundle = Bundle(path: Bundle.main.path(forResource: "en", ofType: "lproj") ?? "") ?? Bundle.main
        let resolver = SpokenTemplateResolver(localeBundle: enBundle)
        XCTAssertEqual(
            resolver.resolveForUserLocale("cloud_error_limit_exceeded"),
            "You have reached your Auris free daily limit. Please try again tomorrow."
        )
    }
}

/// THE RECORDING GAP (cloud-assistant.md: "Record Required codes whose local template is
/// missing"). A Required code with no template in the user's locale falls back to the earcon —
/// correct speech behaviour, but the client GAP itself must be OBSERVABLE in the log, or a
/// missing translation is indistinguishable from a code that was never meant to speak.
///
/// The three cases separate the two axes so none of them can pass for the wrong reason:
///   - Required + missing template  ⇒ earcon AND a gap line
///   - Required + present template  ⇒ spoken AND NO gap line (the line means "missing", not "error")
///   - Generic  + missing template  ⇒ earcon AND NO gap line (an internal diagnostic is not a gap)
final class CloudRequiredErrorGapRecordingTests: SocketCapturingTestCase {
    private var playback: RecordingPlaybackSink!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        suiteName = "cloud_req_gap_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// `ca.lproj` is a REAL shipped localization carrying no VoiceTemplates table — the
    /// production shape of "this user's language has no template", not an empty directory.
    private func localeWithoutTemplates() -> Bundle {
        let path = Bundle.main.path(forResource: "ca", ofType: "lproj")
        return path.flatMap { Bundle(path: $0) } ?? Bundle(for: type(of: self))
    }

    private func englishBundle() -> Bundle {
        Bundle(path: Bundle.main.path(forResource: "en", ofType: "lproj") ?? "") ?? Bundle.main
    }

    private func makeSink(localeBundle: Bundle) -> CloudRouteSink {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(baseURL: cloudConfig.baseUrl, fixture: self.nextFixture())
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: RecordingFingerprintMapper(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            spokenTemplates: SpokenTemplateResolver(localeBundle: localeBundle),
            conversationManager: testConversationManager()
        )
    }

    /// Runs one error turn and returns THIS turn's gap lines. The log is shared by the whole
    /// run, so the filter is scoped to this control's own utterance id — counting globally
    /// would measure the suite rather than the turn.
    private func runTurn(code: String, bundle: Bundle, utterance: String) async -> (CloudRouteResult, [String]) {
        self.pendingFixture =
            """
            event: error
            data: {"code":"\(code)","message":""}

            """
        let response = await makeSink(localeBundle: bundle).routeToCloud(
            request: "x", tier: .free, context: context(), origin: cloudTestOrigin,
            selection: nil, utteranceId: utterance)
        let log = await FileLog.shared.logFileAsString()
        let mine = log.split(separator: "\n")
            .filter { $0.contains("cloudErrorTemplateMissing") && $0.contains(utterance) }
            .map(String.init)
        return (response, mine)
    }

    private func context() -> PlaybackContext {
        PlaybackContext(episodeId: "ep", podcastId: "pod", referencePositionMs: 1_000,
                        clientPositionMs: 1_100, recentReferencePositions: [],
                        previousReferencePositionMs: nil)
    }

    func test_aRequiredCodeWithNoLocalTemplateIsRecordedAsAGap() async {
        let utterance = "req-gap-\(UUID().uuidString)"
        // PREMISE: this locale really has no template for the code, so the earcon below is
        // the missing-template branch and not some other failure.
        XCTAssertTrue(
            SpokenTemplateResolver(localeBundle: localeWithoutTemplates())
                .resolveForUserLocale("cloud_error_no_answer").isEmpty,
            "the chosen locale must genuinely lack the template"
        )
        let (response, lines) = await runTurn(code: "no_answer", bundle: localeWithoutTemplates(), utterance: utterance)
        XCTAssertEqual(response.response, .earcon(.error), "speech behaviour is unchanged: still the earcon")
        XCTAssertEqual(lines.count, 1, "a Required code with no local template must record exactly one gap line: \(lines)")
        // Guarded so a missing line reports as a FAILURE rather than crashing the runner on
        // an out-of-range index — the crash would hide which assertion actually failed.
        guard let line = lines.first else { return XCTFail("no gap line was recorded for this turn") }
        XCTAssertTrue(line.contains("no_answer"), "the line must name the code: \(line)")
    }

    func test_aRequiredCodeWithATemplateRecordsNoGap() async {
        let utterance = "req-ok-\(UUID().uuidString)"
        XCTAssertFalse(
            SpokenTemplateResolver(localeBundle: englishBundle())
                .resolveForUserLocale("cloud_error_limit_exceeded").isEmpty,
            "premise: English carries this template"
        )
        let (response, lines) = await runTurn(code: "limit_exceeded", bundle: englishBundle(), utterance: utterance)
        XCTAssertEqual(
            response.response,
            .spoken("You have reached your Auris free daily limit. Please try again tomorrow.")
        )
        XCTAssertTrue(lines.isEmpty, "a translated Required code is not a gap: \(lines)")
    }

    func test_aGenericCodeWithNoTemplateRecordsNoGap() async {
        let utterance = "gen-gap-\(UUID().uuidString)"
        let (response, lines) = await runTurn(code: "invalid_response", bundle: localeWithoutTemplates(), utterance: utterance)
        XCTAssertEqual(response.response, .earcon(.error), "an internal diagnostic stays an earcon")
        XCTAssertTrue(lines.isEmpty, "a Generic code has no required template, so its absence is not a gap: \(lines)")
    }
}

/// EVERY Required code carries a template in EVERY locale that ships a VoiceTemplates table
/// (cloud-assistant.md: "the client must have a code-specific template in the user's language").
/// The locale list is DISCOVERED from the app bundle rather than hard-coded, so adding a
/// localization cannot silently skip this control.
final class CloudRequiredErrorTemplateCoverageTests: XCTestCase {
    /// The contract's Required rows, plus the two client-side codes that are spoken feedback the
    /// user is owed: `conversation_expired` (Required and rendered) and `connection_lost`
    /// (client-authored, no server row; the client maps duplicate_request onto it).
    /// Every code the contract marks Required, plus the two client-side spoken codes
    /// (docs/specs/cloud-assistant.md#error-codes). This list mirrors
    /// `CloudRouteSink.requiredTemplateCodes`, so a code recorded as a gap and a code asserted
    /// as translated cannot drift apart.
    private let requiredCodes = [
        "limit_exceeded", "no_answer", "retrieval_unavailable", "speech_unavailable",
        "queue_overflow", "budget_exceeded", "turn_conflict", "corrupt_record",
        "conversation_expired", "connection_lost",
    ]

    /// Every shipped `.lproj` that carries a VoiceTemplates table. A locale with no table at all
    /// is out of scope here — it has no voice vocabulary yet, which is a separate decision.
    private func localesWithVoiceTemplates() -> [(name: String, bundle: Bundle)] {
        let dir = Bundle.main.bundleURL
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasSuffix(".lproj") }
            .sorted() ?? []
        return names.compactMap { name in
            let base = String(name.dropLast(".lproj".count))
            guard let path = Bundle.main.path(forResource: base, ofType: "lproj"),
                  let bundle = Bundle(path: path),
                  bundle.path(forResource: "VoiceTemplates", ofType: "strings") != nil else { return nil }
            return (base, bundle)
        }
    }

    func test_everyRequiredCodeResolvesInEveryVoiceLocale() throws {
        let locales = localesWithVoiceTemplates()
        // PREMISE: discovery found the shipped tables. Without this the loop could iterate
        // nothing and pass while asserting no coverage at all.
        XCTAssertGreaterThanOrEqual(locales.count, 11, "expected the shipped voice locales, got \(locales.map(\.name))")
        XCTAssertTrue(locales.contains { $0.name == "en" }, "English must be among them")
        for locale in locales {
            let resolver = SpokenTemplateResolver(localeBundle: locale.bundle)
            for code in requiredCodes {
                let text = resolver.resolveForUserLocale("cloud_error_\(code)")
                XCTAssertFalse(
                    text.isEmpty,
                    "\(locale.name) has no template for Required code \(code): that user hears only an earcon"
                )
            }
        }
    }

    /// The approved copy, verbatim. Presence alone is not the contract: a
    /// locale carrying English text would satisfy a non-empty check while speaking the wrong
    /// language. Proven by mutation — English placed in the de `no_answer` string left the
    /// coverage control GREEN. So each line is asserted exactly, and Android asserts the same
    /// strings, which is what keeps the two apps saying one thing.
    private let approvedCopy: [String: [String: String]] = [
        "en": [
            "no_answer": "Sorry, I couldn't find an answer to that. Please try asking another way.",
            "retrieval_unavailable": "Sorry, I couldn't look that up just now. Please try again.",
            "queue_overflow": "Sorry, I couldn't finish answering that. Please try again.",
            "budget_exceeded": "Sorry, that took too long to answer. Please try again.",
            "turn_conflict": "I'm still answering your last question. Please try again in a moment.",
            "corrupt_record": "Sorry, I've lost track of our conversation. Please ask again to start a new one.",
            "connection_lost": "Connection lost. Please try again.",
        ],
        "de": [
            "no_answer": "Entschuldigung, ich konnte darauf keine Antwort finden. Bitte versuche es anders zu fragen.",
            "retrieval_unavailable": "Entschuldigung, ich konnte das gerade nicht nachschlagen. Bitte versuche es noch einmal.",
            "queue_overflow": "Entschuldigung, ich konnte die Antwort nicht zu Ende geben. Bitte versuche es noch einmal.",
            "budget_exceeded": "Entschuldigung, die Antwort hat zu lange gedauert. Bitte versuche es noch einmal.",
            "turn_conflict": "Ich beantworte gerade noch deine letzte Frage. Bitte versuche es gleich noch einmal.",
            "corrupt_record": "Entschuldigung, ich habe den Überblick über unser Gespräch verloren. Bitte frag noch einmal, dann beginnt ein neues.",
            "connection_lost": "Die Verbindung wurde unterbrochen. Bitte versuche es noch einmal.",
        ],
        "es": [
            "no_answer": "Lo siento, no he encontrado una respuesta a eso. Prueba a preguntarlo de otra manera.",
            "retrieval_unavailable": "Lo siento, no he podido consultarlo ahora mismo. Inténtalo de nuevo.",
            "queue_overflow": "Lo siento, no he podido terminar de responder. Inténtalo de nuevo.",
            "budget_exceeded": "Lo siento, responder ha tardado demasiado. Inténtalo de nuevo.",
            "turn_conflict": "Todavía estoy respondiendo a tu última pregunta. Inténtalo de nuevo en un momento.",
            "corrupt_record": "Lo siento, he perdido el hilo de nuestra conversación. Vuelve a preguntar para empezar una nueva.",
            "connection_lost": "Se ha perdido la conexión. Inténtalo de nuevo.",
        ],
        "es-MX": [
            "no_answer": "Lo siento, no he encontrado una respuesta a eso. Prueba a preguntarlo de otra manera.",
            "retrieval_unavailable": "Lo siento, no he podido consultarlo ahora mismo. Inténtalo de nuevo.",
            "queue_overflow": "Lo siento, no he podido terminar de responder. Inténtalo de nuevo.",
            "budget_exceeded": "Lo siento, responder ha tardado demasiado. Inténtalo de nuevo.",
            "turn_conflict": "Todavía estoy respondiendo a tu última pregunta. Inténtalo de nuevo en un momento.",
            "corrupt_record": "Lo siento, he perdido el hilo de nuestra conversación. Vuelve a preguntar para empezar una nueva.",
            "connection_lost": "Se perdió la conexión. Inténtalo de nuevo.",
        ],
        "fr": [
            "no_answer": "Désolé, je n'ai pas trouvé de réponse à cela. Essayez de le demander autrement.",
            "retrieval_unavailable": "Désolé, je n'ai pas pu le vérifier pour le moment. Veuillez réessayer.",
            "queue_overflow": "Désolé, je n'ai pas pu terminer ma réponse. Veuillez réessayer.",
            "budget_exceeded": "Désolé, la réponse a pris trop de temps. Veuillez réessayer.",
            "turn_conflict": "Je suis encore en train de répondre à votre dernière question. Veuillez réessayer dans un instant.",
            "corrupt_record": "Désolé, j'ai perdu le fil de notre conversation. Reposez votre question pour en commencer une nouvelle.",
            "connection_lost": "La connexion a été perdue. Veuillez réessayer.",
        ],
        "fr-CA": [
            "no_answer": "Désolé, je n'ai pas trouvé de réponse à cela. Essayez de le demander autrement.",
            "retrieval_unavailable": "Désolé, je n'ai pas pu le vérifier pour le moment. Veuillez réessayer.",
            "queue_overflow": "Désolé, je n'ai pas pu terminer ma réponse. Veuillez réessayer.",
            "budget_exceeded": "Désolé, la réponse a pris trop de temps. Veuillez réessayer.",
            "turn_conflict": "Je suis encore en train de répondre à votre dernière question. Veuillez réessayer dans un instant.",
            "corrupt_record": "Désolé, j'ai perdu le fil de notre conversation. Reposez votre question pour en commencer une nouvelle.",
            "connection_lost": "La connexion a été perdue. Veuillez réessayer.",
        ],
        "ja": [
            "no_answer": "申し訳ありません。それに対する答えが見つかりませんでした。別の聞き方でお試しください。",
            "retrieval_unavailable": "申し訳ありません。今は調べられませんでした。もう一度お試しください。",
            "queue_overflow": "申し訳ありません。最後までお答えできませんでした。もう一度お試しください。",
            "budget_exceeded": "申し訳ありません。お答えするのに時間がかかりすぎました。もう一度お試しください。",
            "turn_conflict": "前の質問にまだお答えしています。少し待ってからもう一度お試しください。",
            "corrupt_record": "申し訳ありません。会話の流れがわからなくなってしまいました。もう一度話しかけていただくと、新しい会話が始まります。",
            "connection_lost": "接続が切れました。もう一度お試しください。",
        ],
        "ko": [
            "no_answer": "죄송합니다. 그에 대한 답을 찾지 못했습니다. 다른 방식으로 물어봐 주세요.",
            "retrieval_unavailable": "죄송합니다. 지금은 확인하지 못했습니다. 다시 시도해 주세요.",
            "queue_overflow": "죄송합니다. 답변을 끝까지 드리지 못했습니다. 다시 시도해 주세요.",
            "budget_exceeded": "죄송합니다. 답변하는 데 시간이 너무 오래 걸렸습니다. 다시 시도해 주세요.",
            "turn_conflict": "이전 질문에 아직 답변하고 있습니다. 잠시 후에 다시 시도해 주세요.",
            "corrupt_record": "죄송합니다. 대화의 흐름을 놓쳤습니다. 다시 말씀해 주시면 새 대화를 시작합니다.",
            "connection_lost": "연결이 끊어졌습니다. 다시 시도해 주세요.",
        ],
        "yue": [
            "no_answer": "唔好意思，我搵唔到呢個問題嘅答案。唔該試吓用第二種問法。",
            "retrieval_unavailable": "唔好意思，我啱啱查唔到呢樣嘢。唔該再試一次。",
            "queue_overflow": "唔好意思，我答唔晒呢個問題。唔該再試一次。",
            "budget_exceeded": "唔好意思，答咗太耐都答唔完。唔該再試一次。",
            "turn_conflict": "我仲答緊你上一個問題。唔該等一陣再試一次。",
            "corrupt_record": "唔好意思，我唔記得咗我哋傾到邊。唔該再問一次，咁就會開新嘅對話。",
            "connection_lost": "連線斷咗。唔該再試一次。",
        ],
        "zh-Hans": [
            "no_answer": "抱歉，我没找到这个问题的答案。请换一种问法试试。",
            "retrieval_unavailable": "抱歉，我刚才没能查到这个内容。请再试一次。",
            "queue_overflow": "抱歉，我没能把这个回答说完。请再试一次。",
            "budget_exceeded": "抱歉，回答这个问题用的时间太长了。请再试一次。",
            "turn_conflict": "我还在回答你上一个问题。请稍等一下再试。",
            "corrupt_record": "抱歉，我跟不上我们这段对话了。请再问一次，这样就会开始新的对话。",
            "connection_lost": "连接已断开。请再试一次。",
        ],
        "zh-Hant": [
            "no_answer": "抱歉，我沒找到這個問題的答案。請換一種問法試試。",
            "retrieval_unavailable": "抱歉，我剛才沒能查到這個內容。請再試一次。",
            "queue_overflow": "抱歉，我沒能把這個回答說完。請再試一次。",
            "budget_exceeded": "抱歉，回答這個問題用的時間太長了。請再試一次。",
            "turn_conflict": "我還在回答你上一個問題。請稍等一下再試。",
            "corrupt_record": "抱歉，我跟不上我們這段對話了。請再問一次，這樣就會開始新的對話。",
            "connection_lost": "連線已中斷。請再試一次。",
        ],
    ]

    /// The Cantonese adverb is 啱啱 ("just now"), not 啱啲. Pinned as its own word because every
    /// other assertion compares a line to a copy of itself — which is exactly why this typo
    /// survived in both apps: the expected table was written from the same wrong source.
    ///
    /// SCOPE: this checks one word in one language. It does not validate Cantonese grammar, and
    /// it is not a substitute for a reader on the yue lines.
    func test_theCantoneseJustNowAdverbIsSpelledCorrectly() throws {
        let yue = localesWithVoiceTemplates().first { $0.name == "yue" }
        let bundle = try XCTUnwrap(yue?.bundle, "yue.lproj must ship a VoiceTemplates table")
        let resolver = SpokenTemplateResolver(localeBundle: bundle)
        // The three lines that say "just now" in Cantonese.
        for code in ["speech_unavailable", "internal_error", "retrieval_unavailable"] {
            let text = resolver.resolveForUserLocale("cloud_error_\(code)")
            XCTAssertFalse(text.isEmpty, "yue/\(code) lost its line")
            XCTAssertTrue(text.contains("啱啱"), "yue/\(code) must use 啱啱: \(text)")
            XCTAssertFalse(text.contains("啱啲"), "yue/\(code) uses the misspelling 啱啲: \(text)")
        }
    }

    /// Every locale speaks the APPROVED line, not merely a non-empty one. A translation that
    /// exists but says the wrong thing — or says it in English — is the defect this catches.
    func test_everyVoiceLocaleSpeaksTheApprovedLineVerbatim() throws {
        let locales = localesWithVoiceTemplates()
        XCTAssertEqual(Set(locales.map(\.name)), Set(approvedCopy.keys),
                       "the shipped voice locales and the approved copy table must be the same set")
        for locale in locales {
            let resolver = SpokenTemplateResolver(localeBundle: locale.bundle)
            let expected = try XCTUnwrap(approvedCopy[locale.name], locale.name)
            for code in requiredCodes where expected[code] != nil {
                XCTAssertEqual(
                    resolver.resolveForUserLocale("cloud_error_\(code)"),
                    expected[code],
                    "\(locale.name)/\(code) does not speak the approved line"
                )
            }
        }
    }

    /// The coverage list and the production recording set must name the SAME codes: a code
    /// asserted as translated but absent from the recorder would never report a regression, and
    /// one recorded but never asserted could ship untranslated unnoticed.
    func test_coverageListMatchesTheProductionRecordingSet() {
        XCTAssertEqual(
            Set(requiredCodes), CloudRouteSink.requiredTemplateCodes,
            "the tested vocabulary and the recorded vocabulary must be one set"
        )
    }

    /// The two codes that speak ONE line by decision (`speech_unavailable` / `internal_error`)
    /// must stay identical in every language — they are one sentence, not two that may drift.
    func test_theSharedFailureLineStaysIdenticalInEveryVoiceLocale() throws {
        for locale in localesWithVoiceTemplates() {
            let resolver = SpokenTemplateResolver(localeBundle: locale.bundle)
            let speech = resolver.resolveForUserLocale("cloud_error_speech_unavailable")
            let internalError = resolver.resolveForUserLocale("cloud_error_internal_error")
            XCTAssertFalse(speech.isEmpty, "\(locale.name) lost the shared failure line")
            XCTAssertEqual(speech, internalError, "\(locale.name): the two keys must speak one identical line")
        }
    }

    /// No spoken line may name the machinery — **checked for the Latin-script locales only**.
    ///
    /// HONEST SCOPE: a substring search for English words cannot detect a system term written in
    /// Japanese, Korean or Chinese. Verified by mutation: replacing the ja `queue_overflow` line
    /// with "サーバーのキューがあふれました" ("the server queue overflowed") left this control
    /// GREEN, while the same sentence in ASCII turned it red. So the non-Latin lines are reviewed
    /// by a reader, not by this control, and claiming otherwise would be a blind assertion.
    func test_noRequiredLineNamesTheMachineryInLatinScriptLocales() throws {
        let forbidden = ["server", "service", "provider", "websocket", "api", "queue", "budget"]
        // Latin-script locales only: en/de/es/es-MX/fr/fr-CA. The CJK and yue tables are checked
        // by review, because an English substring test cannot see their scripts.
        let latinLocales = localesWithVoiceTemplates().filter {
            ["en", "de", "es", "es-MX", "fr", "fr-CA"].contains($0.name)
        }
        XCTAssertEqual(latinLocales.count, 6, "expected the six Latin-script voice locales")
        for locale in latinLocales {
            let resolver = SpokenTemplateResolver(localeBundle: locale.bundle)
            for code in requiredCodes {
                let text = resolver.resolveForUserLocale("cloud_error_\(code)").lowercased()
                for word in forbidden where text.contains(word) {
                    XCTFail("\(locale.name)/\(code) speaks the system term '\(word)': \(text)")
                }
            }
        }
    }
}

/// A whitespace-only server message is treated as absent (PR #19 review): it must
/// not be spoken as silence, and it follows the same localized-template/earcon
/// route as a missing message.
final class CloudRouteSinkWhitespaceMessageTests: SocketCapturingTestCase {
    private var playback: RecordingPlaybackSink!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        suiteName = "cloud_ws_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testWhitespaceOnlyServerMessageIsNotSpokenAsSilence() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"invalid_response","message":"   "}

            """
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let cloudConfig = CloudConfig(defaults: defaults)
        let sink = CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(baseURL: cloudConfig.baseUrl, fixture: self.nextFixture())
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: RecordingFingerprintMapper(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            conversationManager: testConversationManager()
        )
        let context = PlaybackContext(episodeId: "ep", podcastId: "pod", referencePositionMs: 1_000, clientPositionMs: 1_100, recentReferencePositions: [], previousReferencePositionMs: nil)

        let response = await sink.routeToCloud(request: "x", tier: .free, context: context, origin: cloudTestOrigin, selection: nil, utteranceId: "u-103")

        XCTAssertEqual(response.response, .earcon(.error), "a spaces-only message follows the code route, never spoken as silence")
    }
}

/// The locale rule must not fall back to the app's default bundle: an unsupported
/// non-English locale hears the earcon, not English (PR #19 review).
final class SpokenTemplateLocaleFallbackTests: XCTestCase {
    func testUnsupportedNonEnglishLocaleDoesNotFallBackToEnglish() {
        // The app ships en.lproj; a locale with no matching bundle must not get it.
        let resolver = SpokenTemplateResolver(locale: Locale(identifier: "xx-XX"))
        XCTAssertEqual(resolver.resolveForUserLocale("cloud_error_connection_lost"), "",
                       "no bundle for the user's language ⇒ nothing to speak ⇒ the caller uses the earcon")
    }

    func testSupportedLocaleStillResolves() {
        let resolver = SpokenTemplateResolver(locale: Locale(identifier: "en-US"))
        XCTAssertEqual(resolver.resolveForUserLocale("cloud_error_connection_lost"), "Connection lost. Please try again.")
    }

    /// Asserts the **discovered bundle**, not a translation: `zh-Hans.lproj` ships
    /// no VoiceTemplates table, so a behavioural assertion would pass whether or
    /// not the hyphenated candidate matched anything (PR #19 review).
    func testHyphenatedLocaleSelectsItsOwnBundle() {
        let resolver = SpokenTemplateResolver(locale: Locale(identifier: "zh-Hans-CN"))
        XCTAssertEqual(resolver.resolvedLocalization, "zh-Hans", "the language-script candidate must match the shipped zh-Hans bundle")
    }

    func testExactHyphenatedTagMatchesItsOwnBundle() {
        // pt-BR ships its own `.lproj`, so this exercises the full-tag candidate
        // without depending on any script inference (reviewer's point: a zh-CN
        // assertion would rest on Foundation inferring `Hans`).
        let resolver = SpokenTemplateResolver(locale: Locale(identifier: "pt-BR"))
        XCTAssertEqual(resolver.resolvedLocalization, "pt-BR", "a shipped hyphenated tag matches exactly")
    }

    func testLanguageSubtagCandidateMatchesAShippedBundle() {
        // fr-FR: no fr-FR.lproj, and no script to infer — only the bare-language
        // candidate can match, and fr.lproj ships. This exercises that candidate
        // without resting on Foundation's script inference (PR #19 review).
        let resolver = SpokenTemplateResolver(locale: Locale(identifier: "fr-FR"))
        XCTAssertEqual(resolver.resolvedLocalization, "fr", "the bare-language candidate finds the shipped fr bundle")
}
}

/// A minimal delegate: `notifyDidStop` returns early when `delegate` is nil, so a directly
/// constructed player emits nothing without one.
private final class RecordingAudioPlayerDelegate: CloudAudioPlayer.Delegate {
    func audioPlayerDidStartPlaying() {}
    func audioPlayerDidPause() {}
    func audioPlayerDidStop(drainEpoch: Int) {}
}

/// The IDENTITY-PLACEMENT control, driven against the REAL `CloudAudioPlayer` directly.
final class CloudAudioPlayerClaimIdentityTests: XCTestCase {

    /// Prerequisites asserted, then the two snapshot placements separated.
    ///
    /// ORDERING CONSTRAINT: the runner releases `runnerLock` BEFORE signalling arrival or waiting on
    /// release, so no lock spans the barrier. Both waits are BOUNDED and cleanup signals the
    /// semaphores BEFORE clearing the references, so a setup error fails in seconds rather than
    /// consuming the runner.
    @MainActor
    func testAClaimedDrainKeepsItsAllocatedIdentityWhenASuccessorSchedulesInsideTheWindow() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate
        defer { player.setDrainHoldForTesting(false) }

        var emittedIdentities: [Int] = []
        player.setCapturedStopNotificationForTesting { identity, completion in
            emittedIdentities.append(identity)
            completion() // the REAL notification continuation: records the physical confirmation
        }

        // PREREQUISITE: nonempty audio is enqueued and pending.
        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertEqual(player.framesEnqueuedForTesting, 1, "a frame must be enqueued")
        XCTAssertTrue(player.hasPendingAudio, "the frame must still be pending")

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        player.claimReached = arrived
        player.claimRelease = release
        // CLEANUP SIGNALS BEFORE CLEARING: nil cannot release a runner already waiting.
        defer {
            release.signal()
            arrived.signal()
            player.claimReached = nil
            player.claimRelease = nil
        }

        // PREREQUISITE: finish allocates an identity and schedules the drain.
        let aAllocated = player.finish()
        XCTAssertGreaterThan(aAllocated, 0, "finish must allocate an identity")

        // BOUNDED arrival wait: a setup error must fail fast.
        let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(claimedInTime, "the runner must reach the claim within the bound")

        // INSIDE THE WINDOW: B schedules; its allocated identity must differ.
        let bAllocated = player.finish()
        XCTAssertNotEqual(bAllocated, aAllocated, "B's identity must differ from A's")

        release.signal()

        try await waitUntilCondition(timeout: 5) { !emittedIdentities.isEmpty }

        // THE RELEASE IS ASSERTED, not merely bounded: a bound only prevents an infinite block.
        XCTAssertEqual(
            player.claimReleaseOutcome, .released,
            "the runner's bounded wait must end RELEASED, not timed out"
        )

        // THE ASSERTION, on the EMITTED identity: A's notification carries A's allocated identity.
        XCTAssertEqual(
            emittedIdentities, [aAllocated],
            "emitted=\(emittedIdentities) aAllocated=\(aAllocated) bAllocated=\(bAllocated)"
        )
        assertNoStrandedStopNotifications(player, "parked A + successor B finish")
    }


    /// REVIEWER-SPECIFIED CONTROL (dc70303d): parked-A → mid-drain CANCEL. The cancel arrives
    /// while A's drain holds the claim window. The physical stop IS the cancel's stop, so the
    /// cancel's own identity must be emitted exactly once, A's claimant identity must NOT be
    /// relabelled onto it, and A's unperformed identity must never be promoted by a later stop.
    @MainActor
    func testAMidDrainCancelEmitsTheCancelIdentityExactlyOnceAndNeverRelabelsA() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate
        defer { player.setDrainHoldForTesting(false) }

        var emittedIdentities: [Int] = []
        player.setCapturedStopNotificationForTesting { identity, _ in
            emittedIdentities.append(identity)
        }

        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertTrue(player.hasPendingAudio, "a frame must be pending for the drain to be scheduled")

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        player.claimReached = arrived
        player.claimRelease = release
        defer {
            release.signal()
            arrived.signal()
            player.claimReached = nil
            player.claimRelease = nil
        }

        // A schedules its drain and reaches the claim.
        let aAllocated = player.finish()
        let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(claimedInTime, "the runner must reach A's claim within the bound")

        // CANCEL INSIDE THE WINDOW: the cancel's identity supersedes A's queued drain.
        let cRequested = player.cancel()
        XCTAssertNotEqual(cRequested, aAllocated, "the cancel must allocate its own identity")

        release.signal()

        try await waitUntilCondition(timeout: 5) { !emittedIdentities.isEmpty }

        XCTAssertEqual(
            player.claimReleaseOutcome, .released,
            "the runner's bounded wait must end RELEASED, not timed out"
        )
        // EXACTLY the cancel's identity, exactly once — not A's, not both.
        XCTAssertEqual(
            emittedIdentities, [cRequested],
            "emitted=\(emittedIdentities) aAllocated=\(aAllocated) cRequested=\(cRequested): the physical stop belongs to the cancel"
        )
        assertNoStrandedStopNotifications(player, "mid-drain cancel")
    }

    /// REVIEWER-SPECIFIED CONTROL (dc70303d): combined B.finish + cancel. A successor's
    /// independently queued finish must NOT be recorded as stopped merely because the
    /// cancel's stop is newer: its own notification identity stays distinct and no
    /// second stop fires for it.
    @MainActor
    func testCombinedSuccessorFinishAndCancelKeepDistinctIdentitiesWithoutASecondStop() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate
        defer { player.setDrainHoldForTesting(false) }

        var emittedIdentities: [Int] = []
        player.setCapturedStopNotificationForTesting { identity, _ in
            emittedIdentities.append(identity)
        }

        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertTrue(player.hasPendingAudio, "a frame must be pending for the drain to be scheduled")

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        player.claimReached = arrived
        player.claimRelease = release
        defer {
            release.signal()
            arrived.signal()
            player.claimReached = nil
            player.claimRelease = nil
        }

        let aAllocated = player.finish()
        let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(claimedInTime, "the runner must reach A's claim within the bound")

        // BOTH, inside the window: B queues a finish, then a cancel supersedes the queue.
        let bAllocated = player.finish()
        let cRequested = player.cancel()
        XCTAssertNotEqual(bAllocated, aAllocated)
        XCTAssertNotEqual(cRequested, bAllocated)

        release.signal()

        try await waitUntilCondition(timeout: 5) { !emittedIdentities.isEmpty }

        XCTAssertEqual(player.claimReleaseOutcome, .released)
        // ONE physical stop: the cancel's identity. B's queued finish was SUPERSEDED — it must
        // neither steal the emitted identity nor fire a second notification of its own.
        XCTAssertEqual(
            emittedIdentities, [cRequested],
            "emitted=\(emittedIdentities) a=\(aAllocated) b=\(bAllocated) c=\(cRequested): exactly one stop, the cancel's"
        )
        assertNoStrandedStopNotifications(player, "combined B finish + cancel")
    }

    /// REVIEWER 47f67d4d: coalesced accounting must include in-flight claim work — the
    /// pending-stop-notification counter must return to ZERO after every parked scenario,
    /// or a stranded increment refuses every future admission.
    private func assertNoStrandedStopNotifications(_ player: CloudAudioPlayer, _ label: String) {
        XCTAssertEqual(
            player.pendingStopNotificationsForTesting, 0,
            "\(label): pending stop notifications must settle to zero"
        )
    }

    /// REVIEWER 47f67d4d: a cancelled drain's displaced owner must appear in the EXPLICIT
    /// settlement record — and an identity NOT in that record must not be implicitly settled
    /// by it. A waiter on a lower, never-performed identity stays stranded (returning false
    /// on its bound), proving the exact-set settlement does not promote bystanders.
    @MainActor
    func testMidDrainCancelSettlesTheDisplacedOwnerExplicitlyAndNeverABystanderLowerIdentity() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate
        defer { player.setDrainHoldForTesting(false) }

        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertTrue(player.hasPendingAudio)

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        player.claimReached = arrived
        player.claimRelease = release
        defer {
            release.signal()
            arrived.signal()
            player.claimReached = nil
            player.claimRelease = nil
        }

        // THE BYSTANDER: an identity ABOVE the cancel's (it will allocate cancel+1 implicitly? no —
        // identities allocate only on request), so use the identity the cancel WILL take: register
        // the bystander waiter on `aAllocated + 1` AFTER the cancel (so the value is known), while
        // the runner is still parked mid-stop? The stop fires on release. Simpler: take the bystander
        // as an identity allocated but never satisfied — cancel() BEFORE the bystander registration
        // is released? We register the bystander waiter AFTER the cancel request and BEFORE the
        // release: the bystander's epoch = cancelEpoch (performed ⇒ settles true, useless) — so use
        // bystander = aAllocated - 1 relative to a RAISED floor: perform one full turn first.
        let firstAllocated = player.finish()
        let settledFirst = await player.awaitActualStop(after: firstAllocated, timeout: 5)
        XCTAssertTrue(settledFirst, "setup: the first turn must fully stop to raise the floor to \(firstAllocated)")
        // Now floor == firstAllocated. The bystander must be ABOVE the floor (else it answers
        // immediately) and NEVER requested. Identities allocate sequentially on request, so the
        // next request takes firstAllocated+1. The bystander takes the identity AFTER the cancel's:
        // request A (takes +1), cancel (+2, performed), bystander (+3, never performed, above floor 2).
        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertTrue(player.hasPendingAudio, "setup: a frame must be pending for A's drain")
        let aAllocated = player.finish()
        XCTAssertNotEqual(aAllocated, firstAllocated)
        let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(claimedInTime)

        let cancelEpoch = player.cancel() // supersedes A's in-flight claim
        let bystanderEpoch = cancelEpoch + 1 // never requested; floor is firstAllocated < it
        XCTAssertGreaterThan(bystanderEpoch, firstAllocated, "bystander must sit above the confirmed floor")
        var bystanderSettled = false
        async let bystander: Bool = player.awaitActualStop(after: bystanderEpoch, timeout: 1)
        try await Task.sleep(nanoseconds: 100_000_000) // let it register
        release.signal()

        // A's waiter settles EXPLICITLY via the displaced record.
        let aSettled = await player.awaitActualStop(after: aAllocated, timeout: 5)
        XCTAssertTrue(aSettled, "the displaced owner's waiter settles via the explicit record")

        bystanderSettled = await bystander
        XCTAssertFalse(
            bystanderSettled,
            "a lower identity outside the displaced record must NOT be implicitly promoted"
        )
        assertNoStrandedStopNotifications(player, "mid-drain cancel")
    }

    /// REVIEWER 82714c29, deterministic: a coalesced B.finish settles under A's physical stop;
    /// a waiter on B that registers ONLY AFTER the settlement must still resolve from B's
    /// retained explicit settlement fact — not strand because the confirmed floor is A's.
    @MainActor
    func testLatelyRegisteredWaiterOnACoalescedFinishResolvesFromItsRetainedSettlement() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate
        defer { player.setDrainHoldForTesting(false) }

        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertTrue(player.hasPendingAudio)

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        player.claimReached = arrived
        player.claimRelease = release
        defer {
            release.signal()
            arrived.signal()
            player.claimReached = nil
            player.claimRelease = nil
        }

        let aAllocated = player.finish()
        let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(claimedInTime)

        // B coalesces onto A's physical stop.
        let bAllocated = player.finish()
        XCTAssertNotEqual(bAllocated, aAllocated)

        release.signal()

        // A's notification terminal, observed FIRST.
        var aEmitted = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !aEmitted {
            aEmitted = player.confirmedStopEpochForTesting >= aAllocated
            if !aEmitted { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(aEmitted, "A's physical stop must be confirmed before B's waiter registers")

        // NOW register B's waiter — after settlement. It must resolve from the retained fact.
        let bSettled = await player.awaitActualStop(after: bAllocated, timeout: 5)
        XCTAssertTrue(
            bSettled,
            "a late waiter on a coalesced finish resolves from its explicit settlement, never strands"
        )
        assertNoStrandedStopNotifications(player, "late B waiter after settlement")
    }

    /// REVIEWER 20ec6eaa: the retained settlement set must be BOUNDED — a repeated
    /// coalesce→physical-stop lifecycle drives it back to the empty baseline, while a late
    /// settled waiter still resolves BEFORE retirement gets to its entry.
    @MainActor
    func testRepeatedCoalesceStopCyclesKeepTheRetainedSettlementSetBounded() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate
        defer { player.setDrainHoldForTesting(false) }

        // EXACTLY-ONCE LEDGER (reviewer 38dffe3e): every notification identity across ALL
        // cycles — a second physical stop for a coalesced request would show up here.
        var emittedIdentities: [Int] = []
        player.setCapturedStopNotificationForTesting { identity, completion in
            emittedIdentities.append(identity)
            completion() // the REAL notification continuation: records the physical confirmation
        }

        // Before any stop, the baseline is empty.
        XCTAssertEqual(player.settledDisplacedIdentitiesForTesting, [], "baseline: nothing settled")

        for cycle in 1...4 {
            player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
            XCTAssertTrue(player.hasPendingAudio, "cycle \(cycle): a frame must be pending")

            let arrived = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            player.claimReached = arrived
            player.claimRelease = release
            defer {
                release.signal()
                arrived.signal()
                player.claimReached = nil
                player.claimRelease = nil
            }

            let aAllocated = player.finish()
            let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
            XCTAssertTrue(claimedInTime, "cycle \(cycle): the runner must reach the claim")

            // B coalesces onto A's physical stop; C ALSO coalesces — two retained facts.
            let bAllocated = player.finish()
            let cAllocated = player.finish()
            XCTAssertNotEqual(bAllocated, aAllocated)
            XCTAssertNotEqual(cAllocated, bAllocated)

            // LATE-BUT-PRE-RETIREMENT proof: register B's waiter BEFORE the release so it
            // resolves from the retained fact even if a later physical stop retires it after.
            async let bWaiter: Bool = player.awaitActualStop(after: bAllocated, timeout: 5)

            release.signal()

            let bSettled = await bWaiter
            XCTAssertTrue(bSettled, "cycle \(cycle): the coalesced finish's late waiter resolves")

            // Let the physical stop confirm and retire.
            let physicalConfirmed = await player.awaitActualStop(after: aAllocated, timeout: 5)
            XCTAssertTrue(physicalConfirmed, "cycle \(cycle): A's physical stop confirms")
            try await Task.sleep(nanoseconds: 200_000_000)

            // BOUNDEDNESS, per cycle: this cycle retained at most its own coalesced requests
            // (b, c) — earlier cycles' entries were retired by this cycle's physical floor.
            // The exact membership can lag the confirmation (async notification delivery), so
            // assert the BOUND, not a specific set.
            XCTAssertLessThanOrEqual(
                player.settledDisplacedIdentitiesForTesting.count, 2,
                "cycle \(cycle): retained settlements must stay within this cycle's coalesced requests"
            )
            assertNoStrandedStopNotifications(player, "cycle \(cycle)")
        }

        // FINAL RETIREMENT: one more plain physical stop confirms a floor above every retained
        // identity from all cycles — storage must return to the EMPTY baseline.
        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        let lastAllocated = player.finish()
        let lastSettled = await player.awaitActualStop(after: lastAllocated, timeout: 5)
        XCTAssertTrue(lastSettled, "setup: the final turn must fully stop")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !player.settledDisplacedIdentitiesForTesting.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(
            player.settledDisplacedIdentitiesForTesting, [],
            "a physical floor above every retained identity retires them all — bounded storage"
        )
        assertNoStrandedStopNotifications(player, "final retirement")

        // EXACTLY ONCE (reviewer 38dffe3e), asserted AFTER all notifications settled: one
        // physical stop per cycle plus the final one; the coalesced b/c requests never
        // produced notifications of their own.
        XCTAssertEqual(
            emittedIdentities, [1, 4, 7, 10, 13],
            "exactly one physical stop per cycle plus the final one: emitted=\(emittedIdentities)"
        )
    }

    /// THE TIMEOUT PATH, deterministically: the release is WITHHELD, so the runner's bounded wait
    /// must record `.timedOut` and the case asserting `.released` must fail. This does not depend on
    /// scheduling luck the way a shortened bound does.
    @MainActor
    func testAWithheldReleaseTimesOutSoTheSuccessAssertionIsLoadBearing() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate

        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertTrue(player.hasPendingAudio, "a frame must be pending for the drain to be scheduled")

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        player.claimReached = arrived
        player.claimRelease = release
        defer {
            release.signal()
            arrived.signal()
            player.claimReached = nil
            player.claimRelease = nil
        }

        _ = player.finish()

        // Wait for the claim, then deliberately DO NOT release: the runner's bounded wait must end
        // `.timedOut`.
        let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(claimedInTime, "the runner must reach the claim")

        // Give the runner's bound time to expire, then read the recorded outcome.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if player.claimReleaseOutcome != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(
            player.claimReleaseOutcome, .timedOut,
            "WITHHELD release must be recorded as TIMED OUT — this is what makes the success "
                + "assertion load-bearing rather than a bound that silently swallows a timeout"
        )
    }
    private func waitUntilCondition(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}


/// Store that fails every write and reports unreadable history — fail-closed fixtures.
final class AlwaysFailingOperationRecordStore: OperationRecordStore {
    private var records: [String: StoredRecord] = [:]
    func load() -> [String: StoredRecord] { records }
    func save(_ records: [String: StoredRecord]) -> Bool { false }
    func loadResult() -> OperationRecordLoadResult { .loaded([:]) }
}


/// Store that persists in-progress claims but FAILS every finished-record write — settlement
/// failure observed through the real write path. A `backing` store is consulted for loads so a
/// recreated journal can observe the same durable state.
final class SettlementFailingOperationRecordStore: OperationRecordStore {
    private let backing: SettlementFailingOperationRecordStore?
    private var records: [String: StoredRecord] = [:]
    init(backing: SettlementFailingOperationRecordStore? = nil) { self.backing = backing }
    func load() -> [String: StoredRecord] { backing?.records ?? records }
    func save(_ records: [String: StoredRecord]) -> Bool {
        guard !records.values.contains(where: { if case .finished = $0 { return true }; return false }) else { return false }
        self.records = records
        return true
    }
    func loadResult() -> OperationRecordLoadResult { .loaded(load()) }
}


// MARK: - Service-to-renderer helpers (spec a8580c0c)

/// Counts daily-limit utterances so "exactly once" is measured, not inferred from a substring.
private final class CountingDailyLimitTtsEngine: TtsEngineProtocol {
    private(set) var dailyLimitUtterances = 0
    func warmUp(language: String) {}
    func speak(text: String, language: String) async {
        if text.contains("Auris") && text.contains("daily limit") { dailyLimitUtterances += 1 }
    }
    func cancel() {}
    func releaseEngine() {}
}

/// A silent earcon player: the daily-limit response is SPOKEN, so no earcon asset is needed and
/// no audio graph is built.
private final class SilentCloudEarconPlayer: EarconPlayer {
    init() { super.init(engine: nil) }
    override func hasEarcon(_ id: EarconId) -> Bool { false }
    override func play(_ id: EarconId) {}
}

private struct NoOpCloudDucker: AudioSessionDucking {
    func duck() {}
    func unduck() {}
}

private struct NoOpCloudPlaybackContextProvider: PlaybackContextProvider {
    func current() -> PlaybackContext? {
        PlaybackContext(
            episodeId: "ep", podcastId: "pod", referencePositionMs: 0, clientPositionMs: 0,
            recentReferencePositions: [], previousReferencePositionMs: nil
        )
    }
}

private final class NoOpCloudPlaybackSink: VoicePlaybackSink {
    var isPlaying: Bool { false }
    func pause() -> VoiceResponse { .silent }
    func resume() -> VoiceResponse { .silent }
    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse { .silent }
    func seekTo(positionSeconds: Int) -> VoiceResponse { .silent }
    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse { .silent }
    func nextEpisode() -> VoiceResponse { .silent }
}

private final class NoOpCloudEffectsSink: VoiceEffectsSink {
    func setSpeed(_ speed: Double) -> VoiceResponse { .silent }
    func adjustSpeed(delta: Double) -> VoiceResponse { .silent }
    func setTrimMode(_ mode: TrimMode) -> VoiceResponse { .silent }
    func setVolumeBoost(enabled: Bool) -> VoiceResponse { .silent }
    func queryEffects() -> VoiceResponse { .silent }
}

private final class NoOpCloudVolumeSink: VoiceVolumeSink {
    func setVolume(_ volume: Int) -> VoiceResponse { .silent }
    func adjustVolume(delta: Int) -> VoiceResponse { .silent }
    func queryVolume() -> VoiceResponse { .silent }
}

private final class NoOpCloudSleepSink: VoiceSleepSink {
    func set(minutes: Int) -> VoiceResponse { .silent }
    func endOfEpisode() -> VoiceResponse { .silent }
    func endOfChapter() -> VoiceResponse { .silent }
    func addTime(minutes: Int) -> VoiceResponse { .silent }
    func cancel() -> VoiceResponse { .silent }
    func query() -> VoiceResponse { .silent }
}

private final class NoOpCloudChapterSink: VoiceChapterSink {
    func next() -> VoiceResponse { .silent }
    func previous() -> VoiceResponse { .silent }
    func byIndex(_ index: Int) -> VoiceResponse { .silent }
    func byTitle(_ title: String) -> VoiceResponse { .silent }
    func openLink(index: Int?, query: String?) -> VoiceResponse { .silent }
    func queryList() -> VoiceResponse { .silent }
    func queryCurrent() -> VoiceResponse { .silent }
    func queryCount() -> VoiceResponse { .silent }
    func queryNext() -> VoiceResponse { .silent }
}

private final class NoOpCloudBookmarkSink: VoiceBookmarkSink {
    func add(title: String?) -> VoiceResponse { .silent }
    func rename(ref: String, title: String) -> VoiceResponse { .silent }
    func play(ref: String) -> VoiceResponse { .silent }
    func delete(ref: String) -> VoiceResponse { .silent }
    func deleteAll() -> VoiceResponse { .silent }
    func queryList() -> VoiceResponse { .silent }
    func queryCount() -> VoiceResponse { .silent }
    func queryNearby() -> VoiceResponse { .silent }
}

private final class NoOpCloudQueueSink: VoiceQueueSink {
    func addTop(episode: String) -> VoiceResponse { .silent }
    func addBottom(episode: String) -> VoiceResponse { .silent }
    func remove(episode: String) -> VoiceResponse { .silent }
    func moveToTop(episode: String) -> VoiceResponse { .silent }
    func moveToBottom(episode: String) -> VoiceResponse { .silent }
    func clear() -> VoiceResponse { .silent }
    func removeByPodcast(podcast: String) -> VoiceResponse { .silent }
    func sort(sortOrder: podcasts.SortOrder) -> VoiceResponse { .silent }
    func queryContents() -> VoiceResponse { .silent }
    func queryNext() -> VoiceResponse { .silent }
    func queryLength() -> VoiceResponse { .silent }
    func queryIsQueued(episode: String) -> VoiceResponse { .silent }
}

private final class NoOpCloudPlaybackQuerySink: VoicePlaybackQuerySink {
    func whatsPlaying() -> VoiceResponse { .silent }
    func position() -> VoiceResponse { .silent }
    func timeRemaining() -> VoiceResponse { .silent }
    func episodeDuration() -> VoiceResponse { .silent }
    func publishDate() -> VoiceResponse { .silent }
    func episodeDescription() -> VoiceResponse { .silent }
    func downloadStatus() -> VoiceResponse { .silent }
    func episodeTitle() -> VoiceResponse { .silent }
}

private final class NoOpCloudStatsQuerySink: VoiceStatsQuerySink {
    func listeningTime(period: String?) -> VoiceResponse { .silent }
    func topPodcasts(period: String?) -> VoiceResponse { .silent }
    func episodesFinished(period: String?) -> VoiceResponse { .silent }
    func listeningStreak() -> VoiceResponse { .silent }
    func subscriptionCount() -> VoiceResponse { .silent }
    func unplayedTotal() -> VoiceResponse { .silent }
    func downloadStats() -> VoiceResponse { .silent }
    func newEpisodes(timeframe: String?) -> VoiceResponse { .silent }
    func timeSinceLastListen() -> VoiceResponse { .silent }

    // MARK: - Buffered playback after an ordinary `done` (reviewer 79614a4f item 3)

}

/// Records the turn outcomes the sink reports, so a control can prove WHICH turn ran a path.
private final class ExpiredTurnAnalytics: AnalyticsService {
    private(set) var turnOutcomes: [String] = []
    func track(_ event: String, properties: [String: Any]) {
        guard event == "cloud_assistant_turn", let outcome = properties["outcome"] as? String else { return }
        turnOutcomes.append(outcome)
    }
}

/// An expired conversation is a NORMAL end of a conversation, not a malfunction: the user hears
/// that it ended, in their own language, and the next request opens a new conversation instead of
/// resuming one the server no longer holds. Without the second half every later follow-up in the
/// same window fails the same way until a wake word starts over.
final class CloudRouteExpiredConversationTests: SocketCapturingTestCase {
    private var playback: RecordingPlaybackSink!
    private var analytics: ExpiredTurnAnalytics!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        analytics = ExpiredTurnAnalytics()
        suiteName = "cloud_expired_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The spoken line comes from the client's own table for this code — never the wire message,
    /// which is operator diagnostics.
    func testExpiredConversationIsSpokenRatherThanSoundedAsAnError() async {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        self.pendingFixture = Self.expiredFixture
        let response = await makeSink(manager: manager).routeToCloud(
            request: "x", tier: .free, context: context(), origin: cloudTestOrigin,
            selection: .wakeWord, utteranceId: "expired-spoken-1"
        )
        XCTAssertEqual(
            response.response, .spoken("That conversation has ended."),
            "an ended conversation is explained in words; an earcon tells the user nothing (outcome \(response.outcome))"
        )
    }

    /// The break this catches: the handle survives the refusal, so the NEXT follow-up resumes the
    /// same dead id and is refused again. Asserted on the wire identity the second turn actually
    /// sends, not on a manager accessor.
    func testTheNextFollowUpOpensANewConversationInsteadOfResumingTheDeadOne() async throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(manager: manager)

        var first: CloudPreparedConversation?
        self.pendingFixture = Self.expiredFixture
        _ = await sink.routeToCloud(
            request: "first", tier: .free, context: context(), origin: cloudTestOrigin,
            selection: .wakeWord, utteranceId: "expired-seq-1",
            preparedObserver: { first = $0 }
        )
        let dead = try XCTUnwrap(first, "the first turn must have been admitted and prepared")
        XCTAssertEqual(dead.mode, "create", "a wake-word turn opens the conversation")

        var second: CloudPreparedConversation?
        self.pendingFixture = Self.doneFixture
        _ = await sink.routeToCloud(
            request: "second", tier: .free, context: context(), origin: cloudTestOrigin,
            selection: .followUp, utteranceId: "expired-seq-2",
            preparedObserver: { second = $0 }
        )
        let next = try XCTUnwrap(second, "the follow-up must be admitted")
        XCTAssertEqual(
            next.mode, "create",
            "after the server said the conversation ended, the next request must open a new one"
        )
        XCTAssertNotEqual(
            next.conversationId, dead.conversationId,
            "resuming the id the server just expired would fail exactly the same way"
        )
    }

    /// Only the expired code leaves the conversation. A transport failure says nothing about the
    /// server's conversation, so dropping the handle there would start a new conversation and lose
    /// the thread of a conversation that is still alive.
    func testAnotherFailureKeepsTheConversationForTheNextFollowUp() async throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(manager: manager)

        var first: CloudPreparedConversation?
        self.pendingFixture = Self.connectionLostFixture
        _ = await sink.routeToCloud(
            request: "first", tier: .free, context: context(), origin: cloudTestOrigin,
            selection: .wakeWord, utteranceId: "kept-seq-1",
            preparedObserver: { first = $0 }
        )
        let opened = try XCTUnwrap(first)

        var second: CloudPreparedConversation?
        self.pendingFixture = Self.doneFixture
        _ = await sink.routeToCloud(
            request: "second", tier: .free, context: context(), origin: cloudTestOrigin,
            selection: .followUp, utteranceId: "kept-seq-2",
            preparedObserver: { second = $0 }
        )
        let next = try XCTUnwrap(second)
        XCTAssertEqual(next.mode, "resume", "a connection failure does not end the conversation")
        XCTAssertEqual(next.conversationId, opened.conversationId)
    }

    /// Every language the app ships carries the line, through the resolver's own locale discovery.
    /// An English-only entry would leave a non-English user with an earcon.
    func testExpiredConversationLineExistsInEveryShippedResponseLanguage() {
        let expected: [String: String] = [
            "en": "That conversation has ended.",
            "de": "Dieses Gespräch ist beendet.",
            "es": "Esa conversación ha terminado.",
            "es-MX": "Esa conversación ha terminado.",
            "fr": "Cette conversation est terminée.",
            "fr-CA": "Cette conversation est terminée.",
            "ja": "その会話は終了しました。",
            "ko": "그 대화는 종료되었습니다.",
            "zh-Hans": "该对话已结束。",
            "zh-Hant": "該對話已結束。",
            "yue": "嗰個對話已經結束咗。",
        ]
        for (dir, line) in expected {
            guard let path = Bundle.main.path(forResource: dir, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                XCTFail("\(dir).lproj is missing from the app bundle")
                continue
            }
            let resolver = SpokenTemplateResolver(localeBundle: bundle)
            XCTAssertEqual(
                resolver.resolveForUserLocale("cloud_error_conversation_expired"), line,
                "\(dir) must speak the same ended-conversation line as the other app"
            )
        }
    }

    /// A turn the server could not voice is still a turn the user asked for: they must hear that it
    /// did not work and can be retried. Without a line for this code the app plays a bare error tone,
    /// which says nothing about what happened or what to do next.
    func testSpeechUnavailableIsSpokenRatherThanSoundedAsAnError() async {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        self.pendingFixture = Self.speechUnavailableFixture
        let response = await makeSink(manager: manager).routeToCloud(
            request: "x", tier: .free, context: context(), origin: cloudTestOrigin,
            selection: .wakeWord, utteranceId: "unavailable-spoken-1"
        )
        XCTAssertEqual(
            response.response,
            .spoken("Sorry, I couldn't answer that just now. Please try again."),
            "a failed answer needs words, not a tone (outcome \(response.outcome))"
        )
    }

    /// The same apology for an internal failure: from the listener's side these are one situation —
    /// the answer did not come — so they say one thing, and neither may fall back to a tone.
    func testInternalErrorSpeaksTheSameLineAsSpeechUnavailable() async {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        self.pendingFixture = Self.internalErrorFixture
        let response = await makeSink(manager: manager).routeToCloud(
            request: "x", tier: .free, context: context(), origin: cloudTestOrigin,
            selection: .wakeWord, utteranceId: "internal-spoken-1"
        )
        XCTAssertEqual(
            response.response,
            .spoken("Sorry, I couldn't answer that just now. Please try again."),
            "an internal failure is explained the same way as a missing voice (outcome \(response.outcome))"
        )
    }

    /// Both codes carry the line in every shipped language, and it is the SAME sentence in each —
    /// one decision, so the two keys must not drift apart in any locale.
    func testBothFailureCodesSpeakOneLocalizedLineInEveryShippedLanguage() {
        let expected: [String: String] = [
            "en": "Sorry, I couldn't answer that just now. Please try again.",
            "de": "Entschuldigung, ich konnte das gerade nicht beantworten. Bitte versuche es noch einmal.",
            "es": "Lo siento, no he podido responder a eso ahora mismo. Inténtalo de nuevo.",
            "es-MX": "Lo siento, no he podido responder a eso ahora mismo. Inténtalo de nuevo.",
            "fr": "Désolé, je n'ai pas pu répondre à cela pour le moment. Veuillez réessayer.",
            "fr-CA": "Désolé, je n'ai pas pu répondre à cela pour le moment. Veuillez réessayer.",
            "ja": "申し訳ありません。今はお答えできませんでした。もう一度お試しください。",
            "ko": "죄송합니다. 지금은 답변드리지 못했습니다. 다시 시도해 주세요.",
            "zh-Hans": "抱歉，我刚才没能回答这个问题。请再试一次。",
            "zh-Hant": "抱歉，我剛才沒能回答這個問題。請再試一次。",
            "yue": "唔好意思，我啱啱答唔到你呢個問題。唔該再試一次。",
        ]
        for (dir, line) in expected {
            guard let path = Bundle.main.path(forResource: dir, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                XCTFail("\(dir).lproj is missing from the app bundle")
                continue
            }
            let resolver = SpokenTemplateResolver(localeBundle: bundle)
            XCTAssertEqual(
                resolver.resolveForUserLocale("cloud_error_speech_unavailable"), line,
                "\(dir) must explain a missing voice in its own language"
            )
            XCTAssertEqual(
                resolver.resolveForUserLocale("cloud_error_internal_error"), line,
                "\(dir) must say the same sentence for an internal failure"
            )
        }
    }

    /// A turn that is told its conversation ended may belong to an EARLIER window, while a newer
    /// window has already opened its own conversation. Releasing every conversation there would
    /// drop the one the user is actually in, and their next follow-up would silently start over.
    /// Only the conversation this turn sent may be released.
    ///
    /// The refusal is delivered while the turn is still the live one — a superseded turn stops
    /// consuming before its error branch, so it never reaches this code at all. What makes it a
    /// delayed turn is that its WINDOW has moved on: it was admitted earlier, and a newer window
    /// opened its own conversation before this answer came back.
    @MainActor
    func testAnExpiredDelayedTurnDoesNotReleaseTheLiveWindowsConversation() async throws {
        let signal = GracePeriodSignal(timeout: 30)
        let manager = CloudConversationManager()
        manager.admittedWorkAuthority = { signal.admittedWorkAuthority }

        // The older window opens a conversation; its turn stays in flight with its terminal withheld.
        signal.onWakeWordDetected()
        let olderOrigin = signal.currentGeneration()
        manager.registerLiveOrigin(olderOrigin)
        signal.admitInFlightTurn(utteranceId: "delayed-1", origin: olderOrigin)

        var olderPrepared: CloudPreparedConversation?
        let hold = HoldLatch()
        self.pendingFixture = Self.expiredFixture
        let sink = makeSink(
            manager: manager, firstReceiveHold: hold,
            admittedWorkAuthority: { signal.admittedWorkAuthority }
        )
        let delayed = Task { @MainActor in
            await sink.routeToCloud(
                request: "older question", tier: .free, context: self.context(), origin: olderOrigin,
                selection: .wakeWord, utteranceId: "delayed-1",
                preparedObserver: { olderPrepared = $0 }
            )
        }
        // PREMISE: the older turn must have prepared AND own the live socket before anything else
        // happens — otherwise there is no in-flight turn to refuse and this proves nothing.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if olderPrepared != nil, sink.activeResultSocketForTesting?.requestId == "delayed-1" { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let older = try XCTUnwrap(olderPrepared, "premise: the delayed turn must have prepared")
        XCTAssertEqual(
            sink.activeResultSocketForTesting?.requestId, "delayed-1",
            "premise: the delayed turn must still be the live turn when its refusal lands"
        )
        XCTAssertFalse(hold.released, "premise: the delayed turn's terminal is still withheld")

        // A NEWER WINDOW opens its own conversation while that turn is still waiting for its answer.
        // Prepared directly at the manager: this is the state a second window leaves behind, and it
        // keeps the older turn live so its refusal is actually processed.
        signal.onWakeWordDetected()
        let liveOrigin = signal.currentGeneration()
        manager.registerLiveOrigin(liveOrigin)
        let live = try XCTUnwrap(
            manager.prepare(selection: .wakeWord, origin: liveOrigin, utteranceId: "live-1"),
            "premise: the newer window must open its own conversation"
        )
        XCTAssertNotEqual(live.conversationId, older.conversationId, "premise: two distinct conversations")

        // Now the older turn's refusal lands and is processed.
        hold.release()
        let delayedResult = await delayed.value
        XCTAssertEqual(
            delayedResult.response, .spoken("That conversation has ended."),
            "premise: the delayed turn must report the expired conversation (outcome \(delayedResult.outcome))"
        )

        // The newer window's follow-up must still continue ITS conversation.
        let next = try XCTUnwrap(manager.prepare(selection: .followUp, origin: liveOrigin, utteranceId: "live-2"))
        XCTAssertEqual(
            next.conversationId, live.conversationId,
            "the live window lost its conversation to another window's expired turn"
        )
        XCTAssertEqual(next.mode, "resume", "the user's next follow-up must continue the conversation they are in")

        // And the expired conversation really was released for its OWN window: a later admitted
        // turn of that window opens a new conversation rather than resuming the dead id. Without
        // this the control would also pass for a client that releases nothing.
        signal.admitInFlightTurnForTesting(utteranceId: "delayed-2", origin: olderOrigin)
        let olderFollowUp = try XCTUnwrap(
            manager.prepare(selection: .followUp, origin: olderOrigin, utteranceId: "delayed-2"),
            "the older window's admitted turn must still prepare"
        )
        XCTAssertEqual(olderFollowUp.mode, "create", "the expired conversation must not be resumed by its own window either")
        XCTAssertNotEqual(olderFollowUp.conversationId, older.conversationId)
    }

    private static let speechUnavailableFixture = """
        event: error
        data: {"code":"speech_unavailable","message":""}

        """

    private static let internalErrorFixture = """
        event: error
        data: {"code":"internal_error","message":""}

        """

    private static let expiredFixture = """
        event: error
        data: {"code":"conversation_expired","message":"conversation no longer held"}

        """

    private static let connectionLostFixture = """
        event: error
        data: {"code":"connection_lost","message":""}

        """

    private static let doneFixture = """
        event: done
        data: {"usage":{"input_tokens":1,"output_tokens":0}}

        """

    private func makeSink(
        manager: CloudConversationManager,
        firstReceiveHold: HoldLatch? = nil,
        admittedWorkAuthority: (() -> GracePeriodSignal.AdmittedWorkAuthority?)? = nil
    ) -> CloudRouteSink {
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl, fixture: self.nextFixture(),
                    prepareTask: { task in firstReceiveHold.map(task.holdFirstReceiveUntilReleased) }
                )
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: RecordingFingerprintMapper(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            analytics: VoiceAnalytics(analytics: analytics),
            conversationManager: manager,
            admittedWorkAuthority: admittedWorkAuthority
        )
    }

    private func context() -> PlaybackContext {
        PlaybackContext(episodeId: "ep", podcastId: "pod", referencePositionMs: 1_000, clientPositionMs: 1_100, recentReferencePositions: [], previousReferencePositionMs: nil)
    }
}

/// Hands the engine the player built (on its runner thread) to the test that renders it.
private final class OfflineEngineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AVAudioEngine?
    var engine: AVAudioEngine? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class TurnReturnedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
