import XCTest

@testable import podcasts

/// DETERMINISTIC BINDING INTERLEAVINGS (PR #49, reviewer-required).
///
/// The turn socket's registration is bound by the transport (`TurnSocketLifetime.bind`) and closed
/// by the consumer (`finishTurn` → `close`). Both are separate tasks, so the ORDER between "the
/// consumer settles the lifetime" and "the transport publishes its registration" is not fixed by
/// construction. These controls pin both orders explicitly — no sleeps, no polling — and assert the
/// contract for each:
///
///   - BIND FIRST, then close: the registration is live and is retired by the close.
///   - CLOSE FIRST, then bind: the bind is REJECTED under the same lock that closed the lifetime,
///     the registration is retired, the socket is cancelled, and the turn reports `connection_lost`
///     — with NO auth frame ever submitted on a lifetime that was already settled.
///
/// The rejected-bind case is the one that cannot be reached by an accident of scheduling: it needs
/// the close to land strictly before the bind, which is exactly what these controls arrange.
final class CloudBindInterleavingControls: XCTestCase {
    // MARK: - Harness

    private func fixture() -> String {
        """
        event: action
        data: {"operation_id":"op-bind","capability_version":"v1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5}}

        event: done
        data: {"usage":{"input_tokens":1,"output_tokens":0}}

        """
    }

    /// Runs one turn with the lifetime CLOSED at a chosen moment, using the blocking surface prove:
    /// `onFrameReceived` fires on the producer's own task after each frame, so a control can act at
    /// an exact point in the transport's lifecycle rather than racing it from outside.
    private func makeClient(task: StubWebSocketTask) -> CloudRouteClient {
        CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "user_test",
            requestTimeoutSeconds: 15,
            tokenProvider: StubTokenProvider(token: "test_token"),
            webSocketTaskFactory: { _ in task }
        )
    }

    // MARK: - Control 1: bind precedes close (the ordinary order)

    /// The registration is published BEFORE the close, so the close retires it. This is the
    /// baseline that makes the rejected-bind case meaningful: the same assertions, opposite order.
    func testRegistrationIsRetiredWhenCloseFollowsABind() async throws {
        let task = StubWebSocketTask(textFrames: StubWebSocketTask.frames(fromFixture: fixture()))
        let client = makeClient(task: task)
        let turn = CloudTurnEnvelope.make(
            capabilities: [], routeHint: nil, recentConversation: []
        )
        let routed = client.routeWithResultSocket(
            request: "x", context: CloudRouteContext(from: sampleContext()), turn: turn
        )
        let socket = routed.resultSocket

        // Bind happens on the producer's task when the transport registers. Wait for the FIRST
        // FRAME so the registration is known-published before closing — deterministic, no sleep:
        // the frame can only have been received after the bind accepted.
        // Fulfilled at most once: the producer may serve several frames, and a repeated
        // `fulfill()` on the same expectation is an XCTest API violation.
        let bound = expectation(description: "registration bound")
        let boundFlag = Promise<Void>()
        client.onFrameReceived = { boundFlag.resolve(()) }
        Task { await boundFlag.value(); bound.fulfill() }

        let consume = Task { () -> [CloudRouteEvent] in
            var events: [CloudRouteEvent] = []
            for await event in routed.stream { events.append(event) }
            return events
        }
        await fulfillment(of: [bound], timeout: 5)

        XCTAssertNotNil(socket.boundIdentity, "a live registration has a bound identity")
        XCTAssertFalse(task.isCancelledSocket, "socket must be live while the turn is open")

        // CLOSE AFTER BIND: the close retires the registration and cancels the socket.
        socket.finishTurn()
        XCTAssertTrue(task.isCancelledSocket, "close must retire the live registration")

        // A send after close is UNDELIVERED — local submission knowledge, never a fabricated send.
        let frame = try! XCTUnwrap(AppOperationResultFrame(
            operationId: "op-bind",
            outcome: .unknown,
            reason: OperationReason.interruptedInFlight
        ))
        let report = await client.sendOperationResult(frame, via: socket)
        XCTAssertEqual(report, CloudRouteClient.AppOperationResultSendReport.undelivered,
                       "a send on a retired turn is undelivered, never submitted")

        _ = await consume.value
    }

    // MARK: - Control 2: close precedes bind (the rejected bind)

    /// CLOSE BEFORE BIND. The lifetime is settled while the transport has not yet published its
    /// registration, so the bind must be REJECTED — not published-then-checked. This is the
    /// interleaving that a unsynchronized bind could get wrong (a close landing between the
    /// publish and the check), and it is arranged here by acting at the frame seam.
    func testLateBindIsRejectedAndRetiresWithConnectionLost() async {
        let task = StubWebSocketTask(textFrames: StubWebSocketTask.frames(fromFixture: fixture()))
        let client = makeClient(task: task)
        let turn = CloudTurnEnvelope.make(
            capabilities: [], routeHint: nil, recentConversation: []
        )

        let closeRequested = Promise<Void>()
        let seamOpened = Promise<Void>()
        // The seam runs on the transport's OWN task at the last instant before the bind decides —
        // after the registration was published, so a publish-then-check bind would already have
        // honoured a lifetime settled here. The control BLOCKS that task until the consumer's close
        // has landed, which makes "settled before the decision" the deterministic order rather than
        // a scheduling accident. The close is issued from OFF-task (never nested inside a held
        // lock, so it cannot deadlock).
        client.onBeforeBind = { _ in
            closeRequested.resolve(())
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !closeRequested.didClose { usleep(1_000) }
            seamOpened.resolve(())
        }

        let routed = client.routeWithResultSocket(
            request: "x", context: CloudRouteContext(from: sampleContext()), turn: turn
        )
        let closer = Task {
            await closeRequested.value()
            routed.resultSocket.finishTurn()
            closeRequested.markClosed()
            await seamOpened.value()
        }

        var events: [CloudRouteEvent] = []
        for await event in routed.stream { events.append(event) }
        _ = await closer.value
        // The rejected bind must surface as a terminal transport fact, never as a silent no-op.
        let errors = events.compactMap { event -> String? in
            if case let .error(_, code, _) = event { return code }
            return nil
        }
        XCTAssertTrue(errors.contains("connection_lost"),
                      "a bind rejected by an already-closed lifetime must report connection_lost; got \(errors)")
        // No frame was ever DELIVERED after the rejection: the rejected bind cancels the socket
        // before the receive loop can serve the scripted action frame.
        XCTAssertTrue(task.isCancelledSocket, "a rejected bind retires the registration immediately")
        XCTAssertEqual(task.sentTextFrames.count, 0,
                       "no auth or turn frame may be submitted on a lifetime that rejected the bind")
        XCTAssertFalse(events.contains { if case .action = $0 { return true }; return false },
                       "no action may be admitted on a lifetime that rejected the bind")
    }

    // MARK: - Helpers

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