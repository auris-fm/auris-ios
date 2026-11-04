import XCTest
@testable import podcasts

/// PRE-TERMINAL REFUSAL, named for exactly what it establishes (client review e03f3ecc).
///
/// The contract (`docs/specs/cloud-assistant.md` → Interruption; @spec ruling c9bfa2e9) says a
/// refused interrupt before any terminal acknowledgement is a TERMINAL FAILURE: discard the
/// retained next utterance, report local generic failure, terminate the old transport, retain the
/// pending interruption report, never treat refusal as settlement, never auto-submit the held
/// utterance.
///
/// **SCOPE LIMITS, stated first because an earlier version of this control overclaimed them**
/// (client review 26d5e8b9):
///
///   1. It drives `CloudRouteSink.routeToCloud` DIRECTLY — not `VoiceIntentExecutor.execute`. The
///      executor's outcome switch is a separate layer; the outcome VALUE asserted here is what
///      that switch consumes, but this control does not execute it.
///   2. It creates NO interruption state: no active predecessor turn, no held successor utterance,
///      no pending interruption report. The iOS client has no such machinery (barge-in supersedes
///      locally via `CloudTurnToken` and never sends an `interrupt` frame), so held-follow-up
///      DISCARD and pending-report RETENTION are not observable here and are NOT claimed. That
///      half of the ruling is a missing production path, reconciled separately with @spec.
///   3. What it does establish, and only this: a served pre-terminal error classifies as a FAILED
///      turn (never `completed` — the value the executor reads to decide whether the grace window
///      may open, so misreporting it would let a refusal settle the turn); the user hears locally
///      resolved feedback rather than the server's free-form message; the turn submits exactly the
///      frames it sent (a refused turn issues NO additional submission of its own — counted, not
///      inferred from an outcome); and the transport is cancelled at the terminal, so no later
///      `done` can arrive on it.
final class PreTerminalRefusalClientControl: SocketCapturingTestCase {
    private var playback: RefusalPlaybackSink!
    private var mapper: EmptyFingerprintMap!
    private var contextState: CloudPlaybackContextState!
    private var analytics: RefusalAnalytics!
    private var voiceAnalytics: VoiceAnalytics!
    private var defaults: UserDefaults!
    private var suiteName: String!

    private static let origin = 1

    override func setUp() {
        super.setUp()
        playback = RefusalPlaybackSink()
        mapper = EmptyFingerprintMap()
        contextState = CloudPlaybackContextState()
        analytics = RefusalAnalytics()
        voiceAnalytics = VoiceAnalytics(analytics: analytics)
        suiteName = "pre_terminal_refusal_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSink() -> CloudRouteSink {
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
            rendersStructuredResults: false,
            routeHintProvider: { nil },
            conversationManager: {
                let manager = CloudConversationManager()
                manager.registerLiveOrigin(Self.origin)
                return manager
            }()
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

    // MARK: - Refusal is a failed turn, never settlement

    func testRefusalIsAFailedTurnNotSettlement() async {
        self.pendingFixture = """
        event: error
        data: {"code":"invalid_request","message":"interrupt does not reference the active turn"}

        """
        let result = await makeSink().routeToCloud(
            request: "play the next one",
            tier: .free,
            context: sampleContext(),
            origin: Self.origin,
            selection: .followUp,
            utteranceId: "u-refused-1"
        )

        // LOAD-BEARING: `VoiceIntentExecutor` switches on this outcome and treats
        // `.failed, .earlyClose, .refused` as "Cloud turn did not complete — no grace period".
        // Reporting `.completed` would let a refusal settle the turn and re-open the window the
        // contract forbids a refusal from settling.
        XCTAssertNotEqual(
            result.outcome, .completed,
            "a pre-terminal refusal was reported as a completed turn — refusal is not settlement"
        )
        guard case let .failed(code) = result.outcome else {
            return XCTFail("expected a failed outcome, got \(result.outcome)")
        }
        XCTAssertEqual(code, "invalid_request", "the refusal's own code must survive to the outcome")
    }

    /// "NO AUTOMATIC SUBMISSION" AS A COUNT, not an inference from an outcome (review 26d5e8b9).
    ///
    /// A refused turn must produce no outbound submission beyond its own. The earlier version
    /// re-dispatched with a call of its own and checked only "not completed" — which a second
    /// network submission that also failed would satisfy. This counts what the socket actually
    /// received: the refused turn sends its one request, and the socket is retired at the refusal,
    /// so no follow-up frame leaves the client.
    func testARefusedTurnSubmitsNothingBeyondItsOwnRequest() async {
        self.pendingFixture = """
        event: error
        data: {"code":"invalid_request","message":"refused"}

        """
        _ = await makeSink().routeToCloud(
            request: "play the next one",
            tier: .free,
            context: sampleContext(),
            origin: Self.origin,
            selection: .followUp,
            utteranceId: "u-refused-count"
        )

        // LIMIT OF THIS ASSERTION, stated so it cannot be read as more than it is: a SocketStub
        // records frames per SOCKET, so this counts submissions on the refusal's own transport.
        // A hypothetical follow-up opened on a NEW socket with a NEW sink would not appear here,
        // and this client has no retained utterance that could produce one — so the count is a
        // necessary check, not a proof that no client anywhere could resubmit.
        let frames = capturedTask?.sentTextFrames ?? []
        XCTAssertFalse(frames.isEmpty, "premise: the refused turn did actually submit its request")
        XCTAssertEqual(
            frames.count, 1,
            "a refused turn submitted \(frames.count) frames; it must submit only its own request "
                + "and nothing on refusal. Frames: \(frames)"
        )
    }

    func testRefusalFeedbackIsLocalAndNeverTheServerMessage() async {
        self.pendingFixture = """
        event: error
        data: {"code":"invalid_request","message":"interrupt does not reference the active turn"}

        """
        let result = await makeSink().routeToCloud(
            request: "x",
            tier: .free,
            context: sampleContext(),
            origin: Self.origin,
            selection: .followUp,
            utteranceId: "u-refused-2"
        )
        switch result.response {
        case let .spoken(text):
            XCTAssertFalse(
                text.contains("interrupt does not reference"),
                "the server's free-form message reached the user — it is operator diagnostics only"
            )
        case .earcon(.error), .silent:
            break
        case let other:
            XCTFail("unexpected response for a refused turn: \(other)")
        }
    }

    func testTransportIsTerminatedAtTheRefusal() async {
        self.pendingFixture = """
        event: error
        data: {"code":"invalid_request","message":"refused"}

        """
        _ = await makeSink().routeToCloud(
            request: "x",
            tier: .free,
            context: sampleContext(),
            origin: Self.origin,
            selection: .followUp,
            utteranceId: "u-refused-3"
        )
        // This is what makes "no later done on that transport" true by construction rather than by
        // the fixture happening to end: the receive loop stops and retires the socket.
        XCTAssertTrue(
            capturedTask?.isCancelledSocket ?? false,
            "the transport was still live after a terminal error frame"
        )
    }

    /// The contrasting case that keeps the control honest: a served `done` on the SAME wiring
    /// still completes. A control that always reported failure would fail this one.
    func testDoneOnTheSameWiringCompletes() async {
        self.pendingFixture = """
        event: done
        data: {"usage":{"input_tokens":1,"output_tokens":1}}

        """
        let result = await makeSink().routeToCloud(
            request: "x",
            tier: .free,
            context: sampleContext(),
            origin: Self.origin,
            selection: .followUp,
            utteranceId: "u-normal-1"
        )
        XCTAssertEqual(result.outcome, .completed)
    }
}

// MARK: - Doubles

private struct EmptyFingerprintMap: FingerprintMappingProviding {
    func matchedReferenceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval? { nil }
    func playbackTime(forReferenceTime referenceTime: TimeInterval) -> TimeInterval? { nil }
}

private final class RefusalPlaybackSink: VoicePlaybackSink, @unchecked Sendable {

    /// App-operation observation (voice-intents.md @ 818c8f75): this double has no notion of an
    /// unavailable engine, so it mirrors `isPlaying`.
    var observedPlaying: Bool? { isPlaying }

    private(set) var positionMs: Int64 = 0
    func setPositionMs(_ ms: Int64) { positionMs = ms }
    var isPlaying: Bool { false }
    func pause() -> VoiceResponse { .silent }
    func resume() -> VoiceResponse { .silent }
    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse { .silent }
    func seekTo(positionSeconds: Int) -> VoiceResponse { .silent }
    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse { .silent }
    func nextEpisode() -> VoiceResponse { .silent }
}

private final class RefusalAnalytics: AnalyticsService, @unchecked Sendable {
    func track(_ event: String, properties: [String: Any]) {}
}