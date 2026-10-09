import XCTest
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
            data: {"input_tokens":10,"output_tokens":4}

            """
        mapper.playbackSecondsForReference = [1130.0: 1200.0]
        playback.positionMs = 500_000

        let response = await makeSink().routeToCloud(
            request: "What did she mean?",
            tier: .free,
            context: sampleContext()
        )

        XCTAssertEqual(response, .silent, "cloud answers are played as audio, not spoken")
        XCTAssertTrue(playback.calls.contains(.pause))
        XCTAssertTrue(playback.calls.contains(.resume), "done must restore turn-owned auto-pause")
        XCTAssertEqual(playback.calls.filter { $0 == .seekTo(1200) }.count, 1)
        XCTAssertEqual(analytics.events.last?.0, "cloud_assistant_turn")
        XCTAssertEqual(analytics.events.last?.1["outcome"] as? String, "done")
        let snap = contextState.snapshot()
        XCTAssertEqual(snap.recentReferencePositions.last, 1_130_000)
        XCTAssertEqual(snap.previousReferencePositionMs, 500_000)
    }

    func testDoneResumesTurnOwnedAutoPause() async {
        self.pendingFixture = 
            """
            event: token
            data: {"text":"Answer."}

            event: done
            data: {"input_tokens":1,"output_tokens":1}

            """

        let response = await makeSink().routeToCloud(
            request: "summarize",
            tier: .free,
            context: sampleContext()
        )

        XCTAssertEqual(response, .silent, "cloud answers are played as audio, not spoken")
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
            data: {"input_tokens":1,"output_tokens":1}

            """
        playback.setPlaying(false)

        let response = await makeSink().routeToCloud(
            request: "what was that about",
            tier: .free,
            context: sampleContext()
        )

        XCTAssertEqual(response, .silent)
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

        _ = await makeSink().routeToCloud(request: "hi", tier: .free, context: sampleContext())

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
            data: {"input_tokens":1,"output_tokens":0}

            """
        mapper.playbackSecondsForReference = [500.0: 510.0]
        playback.positionMs = 900_000

        let response = await makeSink().routeToCloud(
            request: "play that",
            tier: .free,
            context: sampleContext()
        )

        XCTAssertEqual(response, .silent)
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
            data: {"input_tokens":1,"output_tokens":0}

            """
        playback.positionMs = 120_000

        let response = await makeSink().routeToCloud(
            request: "forward 15 seconds",
            tier: .free,
            context: sampleContext()
        )

        XCTAssertEqual(response, .silent)
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
            data: {"input_tokens":1,"output_tokens":0}

            """
        playback.positionMs = 120_000

        _ = await makeSink().routeToCloud(
            request: "go back",
            tier: .free,
            context: sampleContext()
        )

        // No delta manufactured — direction preserved as nil.
        XCTAssertTrue(playback.calls.contains(.seekRelative(nil, .backward)))
    }

    func testSeekRelativeNeitherDeltaNorDirectionUsesForwardDefault() async {
        self.pendingFixture = 
            """
            event: action
            data:{"tool":"playback","action":"seek_relative","params":{}}

            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        playback.positionMs = 120_000

        _ = await makeSink().routeToCloud(
            request: "skip forward",
            tier: .free,
            context: sampleContext()
        )

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
            data: {"input_tokens":1,"output_tokens":0}

            """

        _ = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext())
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
            data: {"code":"limit_exceeded","message":"rate limited"}

            """
        mapper.playbackSecondsForReference = [100.0: 110.0]
        playback.positionMs = 50_000

        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext())

        XCTAssertEqual(response, .spoken("rate limited"))
        XCTAssertTrue(playback.calls.contains(.seekTo(110)))
        XCTAssertTrue(playback.calls.contains(.resume))
        XCTAssertEqual(analytics.events.last?.1["outcome"] as? String, "error")
    }

    func testUnmappedReferenceSeeksAsIsBestEffort() async {
        self.pendingFixture = 
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":200000}}

            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        _ = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext())
        XCTAssertTrue(playback.calls.contains(.seekTo(200)))
    }

    /// Per-turn state: a `stop_quote` in a turn that issued no `play_quote`
    /// must NOT seek to a previous turn's captured pre-quote position.
    func testStopQuoteWithoutPlayQuoteInLaterTurnDoesNotUseStalePosition() async {
        // RecordingFingerprintMapper is a struct — configure it before the sink copies it.
        mapper.playbackSecondsForReference = [500.0: 510.0]
        playback.positionMs = 900_000
        let sink = makeSink()

        // Turn 1 captures a pre-quote position via play_quote.
        self.pendingFixture = 
            """
            event: action
            data: {"tool":"playback","action":"play_quote","params":{"reference_position_ms":500000}}

            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        _ = await sink.routeToCloud(request: "play that", tier: .free, context: sampleContext())
        XCTAssertTrue(playback.calls.contains(.seekTo(510)))

        // Turn 2 (same sink): stop_quote without play_quote must be a no-op seek-wise.
        playback.calls.removeAll()
        self.pendingFixture = 
            """
            event: action
            data: {"tool":"playback","action":"stop_quote","params":{}}

            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        _ = await sink.routeToCloud(request: "stop", tier: .free, context: sampleContext())
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
            data: {"input_tokens":1,"output_tokens":1}

            """

        _ = await makeSink().routeToCloud(request: "what did they say?", tier: .free, context: sampleContext())

        let body = try XCTUnwrap(capturedTask?.sentAuthFrame)
        let requestId = try XCTUnwrap(body["request_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: requestId), "request_id must be a client-assigned UUID")
        XCTAssertNil(body["capabilities"], "no renderer yet: capabilities must be omitted so the server uses token+done")
        XCTAssertNil(body["route_hint"], "free-text turns carry no hint")
    }

    func testSinkAdvertisesSearchResultsV1OnlyWhenRendererAvailable() async throws {
        self.pendingFixture = 
            """
            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """

        _ = await makeSink(rendersStructuredResults: true, routeHint: CloudRouteHint(
            operation: "search_spoken_content",
            arguments: ["query": .string("climate")]
        )).routeToCloud(request: "find the climate bit", tier: .free, context: sampleContext())

        let body = try XCTUnwrap(capturedTask?.sentAuthFrame)
        XCTAssertEqual(body["capabilities"] as? [String], ["search_results_v1"])
        let hint = try XCTUnwrap(body["route_hint"] as? [String: Any])
        XCTAssertEqual(hint["operation"] as? String, "search_spoken_content")
    }

    // MARK: - Helpers

    private func makeSink(
        rendersStructuredResults: Bool = false,
        routeHint: CloudRouteHint? = nil
    ) -> CloudRouteSink {
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl,
                    fixture: self.nextFixture()
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
            routeHintProvider: { routeHint }
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
}

private final class RecordingPlaybackSink: VoicePlaybackSink {
    /// Host playing at the moment the turn reads it. `pause()` and `resume()`
    /// keep it true to playback: a constant `true` hides a lost hold, because a
    /// turn that inherits an outstanding pause would still read "playing".
    private(set) var isPlaying = true
    enum Call: Equatable {
        case pause, resume, seekRelative(Int?, SeekDirection), seekTo(Int), nextEpisode
    }

    /// Models the state before a turn: a user who paused before speaking, or a
    /// player that is running. `pause()`/`resume()` maintain it thereafter.
    func setPlaying(_ playing: Bool) { isPlaying = playing }

    var calls: [Call] = []
    var positionMs: Int64 = 0

    func pause() -> VoiceResponse {
        calls.append(.pause)
        isPlaying = false
        return .earcon(.success)
    }

    func resume() -> VoiceResponse {
        calls.append(.resume)
        isPlaying = true
        return .silent
    }

    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse {
        calls.append(.seekRelative(deltaSeconds, direction))
        return .silent
    }

    func seekTo(positionSeconds: Int) -> VoiceResponse {
        calls.append(.seekTo(positionSeconds))
        return .silent
    }

    /// A negative position resolves back from the episode end, as the real sink
    /// does; the double records the resolved absolute position.
    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse {
        let resolved = positionSeconds < 0
            ? max(episodeDurationSeconds + positionSeconds, 0)
            : positionSeconds
        calls.append(.seekTo(resolved))
        return .silent
    }

    func nextEpisode() -> VoiceResponse {
        calls.append(.nextEpisode)
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
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSupersededTurnDoesNotRestoreOrRecordAnalytics() async throws {
        // Turn A: held open, so it is still running when B starts. Its fixture is
        // bound to A's client explicitly, because B's turn is built in between.
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"slow"}

            """
        let gate = holdNextTurn()
        let sink = makeSink()
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext()) }

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(playback.calls.contains(.pause), "the first turn paused playback")
        gate.release()

        // Turn B supersedes A and completes cleanly.
        self.nextTurnFixture =
            """
            event: done
            data: {"input_tokens":1,"output_tokens":1}

            """
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext())
        _ = await slow.value

        // Exactly one resume: the superseding turn's. A must not restore after B.
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1, "only the winning turn restores playback")
        // Analytics records only the winning turn's outcome.
        XCTAssertEqual(analytics.events.count, 1)
        // The losing turn's socket is closed rather than left running: the client
        // closes the socket on every exit path, and a superseded turn that kept it
        // open would bill for a stream nobody reads and hold the connection until
        // the server's own idle timeout.
        XCTAssertEqual(
            heldTurn?.task.sentTextFrames.count, 1,
            "the held turn sent its auth frame and is the turn these assertions are about"
        )
        // Asserted on the producer, not on consumer completion: only the client
        // setting `cancelled` proves the losing turn's socket was closed, and a
        // bounded wait turns an intermittent miss into a deterministic failure on
        // that same property rather than making the ordering guaranteed.
        let heldTask = try XCTUnwrap(heldTurn?.task, "the case held a turn open")
        let closed = await heldTask.awaitCancellation()
        XCTAssertTrue(closed, "the superseded turn's socket is closed")
    }

    func testSupersededTurnDoesNotExecuteLateActions() async {
        // Turn A: its action arrives only after it has already been superseded.
        self.nextTurnFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":100000}}

            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        let gate = holdNextTurn()
        let sink = makeSink()
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext()) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        gate.release()

        self.nextTurnFixture =
            """
            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext())
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
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext()) }

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(playback.calls.contains(.pause), "the first turn paused playback")
        XCTAssertFalse(playback.isPlaying, "the hold is in effect while the first turn runs")
        gate.release()

        self.nextTurnFixture =
            """
            event: done
            data: {"input_tokens":1,"output_tokens":1}

            """
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext())
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

    /// Stalls the *next* client's turn until `release()` is called on the returned
    /// gate, so another turn can supersede it while it is still running.
    @discardableResult
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

    private func makeSink() -> CloudRouteSink {
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                let fixture = self.nextTurnFixture ?? self.nextFixture()
                self.nextTurnFixture = nil
                let built = CloudRouteClient.stubbed(baseURL: cloudConfig.baseUrl, fixture: fixture)
                if let gate = self.pendingHeldGate {
                    // The held turn waits for frames; the test releases it later.
                    built.task.holdUntilReleased(gate)
                    self.heldTurn = (built.task, gate)
                    self.pendingHeldGate = nil
                }
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            analytics: VoiceAnalytics(analytics: analytics)
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
        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext())

        XCTAssertEqual(response, .spoken("Connection lost. Please try again."), "a code with a template is spoken")
    }

    func testCodeWithoutATemplateUsesTheErrorEarcon() async {
        self.pendingFixture = 
            """
            event: error
            data: {"code":"invalid_response","message":""}

            """
        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext())

        XCTAssertEqual(response, .earcon(.error), "an internal diagnostic stays an earcon, never English prose")
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
            cloudPlaybackContextState: CloudPlaybackContextState()
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
            spokenTemplates: SpokenTemplateResolver(localeBundle: localeBundle)
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
        let response = await makeSink(localeBundle: empty).routeToCloud(request: "x", tier: .free, context: context())
        XCTAssertEqual(response, .earcon(.error), "no translation in the user's locale ⇒ earcon, never English speech")
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
        let response = await makeSink(localeBundle: enBundle).routeToCloud(request: "x", tier: .free, context: context())
        XCTAssertEqual(response, .spoken("Connection lost. Please try again."))
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
            cloudPlaybackContextState: CloudPlaybackContextState()
        )
        let context = PlaybackContext(episodeId: "ep", podcastId: "pod", referencePositionMs: 1_000, clientPositionMs: 1_100, recentReferencePositions: [], previousReferencePositionMs: nil)

        let response = await sink.routeToCloud(request: "x", tier: .free, context: context)

        XCTAssertEqual(response, .earcon(.error), "a spaces-only message follows the code route, never spoken as silence")
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
