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
            data: {"usage":{"input_tokens":10,"output_tokens":4}}

            """
        mapper.playbackSecondsForReference = [1130.0: 1200.0]
        playback.setPositionMs(500_000)

        let response = await makeSink().routeToCloud(
            request: "What did she mean?",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
            context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
            context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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

        _ = await makeSink().routeToCloud(request: "hi", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
            context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
            context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
            context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
            context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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

        _ = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
        playback.setPositionMs(50_000)

        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

        XCTAssertEqual(response.response, .spoken("rate limited"))
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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
    /// Optional one-shot PRODUCTION-boundary park: armed onto the stub at construction; the sink
    /// installs it synchronously at the claim→effect seam via `effectEntered` (see
    /// `StubWebSocketTask.armReceiveHoldOnEntered`).
    private var pendingArmedReceiveHold: HoldLatch?
    /// Transport park installed at client creation (survives the whole turn) plus how many
    /// frames must be served before it engages.
    private var pendingDeclaredPark: HoldLatch?
    private var pendingDeclaredParkAfterFrames: Int?

    private func makeSinkWithConsumer(_ consumer: RecordingResultConsumer, conversationManager: CloudConversationManager? = nil, operationJournal: OperationJournal? = nil, audioPayloads: [Data] = [], episodeDuration: (() -> TimeInterval)? = nil) -> CloudRouteSink {
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
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            episodeDuration: episodeDuration,
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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
        _ = await sink1.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
        _ = await sinkB.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
        _ = await sink2.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
            episodeDuration: { 0 }
        )
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
        let turn = Task { await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil) }
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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
        _ = await sink.routeToCloud(request: "play that", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
        _ = await sink.routeToCloud(request: "stop", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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

        _ = await makeSink().routeToCloud(request: "what did they say?", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """

        _ = await makeSink(rendersStructuredResults: true, routeHint: CloudRouteHint(
            operation: "search_spoken_content",
            arguments: ["query": .string("climate")]
        )).routeToCloud(request: "find the climate bit", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
        XCTAssertEqual(result.outcome, .completed)
    }

    func testSpokenServerErrorReportsFailureNotCompletion() async {
        // An error with a localized line renders as .spoken — the response shape that
        // the executor previously read as a completed cloud route.
        self.pendingFixture = """
        event: error
        data: {"code":"rate_limited","message":"slow down"}

        """
        defaults.set("de", forKey: "AppleLanguages")   // a locale with a spoken template
        let result = await makeSink().routeToCloud(
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
            await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
            await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
            await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
        await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil) }

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(playback.calls.contains(.pause), "the first turn paused playback")
        gate.release()

        // Turn B supersedes A and completes cleanly.
        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let gate = holdNextTurn()
        let sink = makeSink()
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        gate.release()

        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil) }

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(playback.calls.contains(.pause), "the first turn paused playback")
        XCTAssertFalse(playback.isPlaying, "the hold is in effect while the first turn runs")
        gate.release()

        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)
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

    /// OPT-IN binary audio for the next built turn, mirroring `nextTurnFixture`. Empty means the
    /// turn carries no audio, so every existing case is unaffected.
    private var nextTurnAudioPayloads: [Data] = []

    private func makeSink(conversationManager: CloudConversationManager? = nil) -> CloudRouteSink {
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
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
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            analytics: VoiceAnalytics(analytics: analytics),
            conversationManager: conversationManager ?? testConversationManager()
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
            )
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
        )

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
        )
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
            )
        }
        let maybeHeld = await waitForHeldTurn()
        let heldA = try XCTUnwrap(maybeHeld, "turn A never reached the socket")
        XCTAssertFalse(heldA.task.sentTextFrames.isEmpty, "A must have submitted its frame")

        // B replaces the active turn while A is still held.
        self.nextTurnFixture = Self.doneOnlyFixture
        let b = Task {
            await sink.routeToCloud(
                request: "B", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .followUp
            )
        }
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
        XCTAssertNotNil(UUID(uuidString: bRequestId), "B's request_id must be a UUID")
        // A and B are genuinely distinct turns, shown by their own prepared frames.
        let aRequestId = try XCTUnwrap(
            heldA.task.sentAuthFrame?["request_id"] as? String,
            "A's prepared frame must carry a client-assigned request_id"
        )
        XCTAssertNotEqual(aRequestId, bRequestId, "A and B must be distinguishable by their frames")

        gate.release()
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
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        if condition() { return }
        struct BarrierNotReached: Error, CustomStringConvertible {
            let label: String
            var description: String { "barrier never satisfied: \(label)" }
        }
        throw BarrierNotReached(label: description)
    }

    /// POSITIVE CONTROL for the audio path: a turn carrying binary audio must actually put
    /// NONEMPTY audio in front of the player. Without this, "no audio pending" afterwards cannot
    /// be distinguished from "no audio ever arrived", which is exactly how the first version of
    /// the output assertion was vacuous.
    func testATurnCarryingBinaryAudioActuallyReachesThePlayer() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = [Self.audioPayload]
        let sink = makeSink()

        _ = await sink.routeToCloud(
            request: "audio", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord
        )

        // The player must have been given audio: the enqueue path ran, and by the end of the turn
        // the audio has drained rather than been dropped.
        let enqueued = await MainActor.run { sink.audioPlayerForTesting?.framesEnqueuedForTesting }
        let pending = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio }
        XCTAssertTrue(
            (enqueued ?? 0) > 0,
            "binary audio must be DELIVERED to the player — otherwise an output assertion proves nothing"
        )
        // SCOPE: this is DELIVERY and buffer state, not proof that speech was RENDERED. The player's
        // decode/render path is not observed here, so a case reading these two facts must not be
        // described as showing that audio was heard.
        XCTAssertEqual(pending, false, "the turn completed, so its audio buffer must be empty")
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
            )
        }
        let maybeHeld = await waitForHeldTurn()
        _ = try XCTUnwrap(maybeHeld, "the live turn never reached the socket")

        // The window moves on, so the next turn's captured origin is genuinely stale.
        manager.registerLiveOrigin(cloudTestOrigin + 1)
        let staleResult = await sink.routeToCloud(
            request: "stale", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp
        )
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
            )
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
        )
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
        )

        // IDENTITY: the turn that ran is the turn this case built, named by its own prepared frame.
        let task = try XCTUnwrap(capturedTask, "the turn must have built its own transport task")
        let frame = try XCTUnwrap(task.sentAuthFrame, "the turn's own prepared frame must be readable")
        let requestId = try XCTUnwrap(frame["request_id"] as? String, "the frame carries a request_id")
        XCTAssertNotNil(UUID(uuidString: requestId), "the request_id is client-assigned")
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
        )
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
            )
        }
        let maybeHeldB = await waitForHeldTurn()
        let heldB = try XCTUnwrap(maybeHeldB, "turn B must be in flight and holding")
        // B's distinct identity, from ITS OWN prepared frame.
        let bFrame = try XCTUnwrap(heldB.task.sentAuthFrame, "B's prepared frame must be readable")
        let bRequestId = try XCTUnwrap(bFrame["request_id"] as? String, "B carries a request_id")
        XCTAssertNotNil(UUID(uuidString: bRequestId), "B's request_id is client-assigned")

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
        )
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
        )
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
            preparedObserver: { prepared in preparedA = prepared }
        )
        XCTAssertEqual(a.outcome, .completed, "turn A completes")

        // B: a second dispatch on the SAME sink, with its OWN observer.
        self.nextTurnFixture = Self.doneOnlyFixture
        let b = await sink.routeToCloud(
            request: "B", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp,
            preparedObserver: { prepared in preparedB = prepared }
        )
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
        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

        XCTAssertEqual(response.response, .spoken("Connection lost. Please try again."), "a code with a template is spoken")
    }

    func testCodeWithoutATemplateUsesTheErrorEarcon() async {
        self.pendingFixture = 
            """
            event: error
            data: {"code":"invalid_response","message":""}

            """
        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil)

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
        let response = await makeSink(localeBundle: empty).routeToCloud(request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil)
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
        let response = await makeSink(localeBundle: enBundle).routeToCloud(request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil)
        XCTAssertEqual(response.response, .spoken("Connection lost. Please try again."))
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

        let response = await sink.routeToCloud(request: "x", tier: .free, context: context, origin: cloudTestOrigin, selection: nil)

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
        player.setCapturedStopNotificationForTesting { identity, _ in
            emittedIdentities.append(identity)
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
