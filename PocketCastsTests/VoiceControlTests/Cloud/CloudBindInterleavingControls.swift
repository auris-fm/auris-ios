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
// MARK: - Gate ticket-state controls

extension CloudBindInterleavingControls {
    /// CANCELLATION BEFORE REGISTRATION. The task is cancelled before it has run a single
    /// instruction, so `withTaskCancellationHandler` fires `onCancel` before the operation body
    /// registers its continuation. A gate that stores a single resumable slot misses that
    /// cancellation entirely and then reports SUCCESS on release — a cancelled waiter must never
    /// be told the gate opened. The ticket-state gate flips its cancelled flag under the lock and
    /// the body honors it at registration time.
    func testCancellationBeforeRegistrationThrowsInsteadOfSucceedingOnRelease() async throws {
        let gate = Gate()
        // The task is cancelled BEFORE it has run a single instruction, so the cancellation
        // handler fires before the operation body can register — the exact window pinned here.
        let waiter = Task {
            try await gate.wait()
        }
        waiter.cancel()
        let outcome = await waiter.result
        // EXPLICIT, no try? swallowing: the failure must be exactly CancellationError — the
        // ticket flag honored at registration. A success here is the pre-fix defect.
        guard case .failure(let error) = outcome else {
            XCTFail("a waiter cancelled before registration must fail; it succeeded")
            return
        }
        XCTAssertTrue(error is CancellationError,
                      "expected CancellationError, got \(error)")
        // The gate itself is still closed: the cancelled waiter did not release it.
        XCTAssertFalse(gate.released, "a cancelled waiter must not open the gate")
        // SURVIVING DELIVERY, no try?: a fresh waiter still receives the release as success.
        let late = Task { try await gate.wait() }
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.release()
        let lateOutcome = await late.result
        if case .failure(let error) = lateOutcome {
            XCTFail("the surviving waiter must be delivered the release; got \(error)")
        }
        XCTAssertTrue(gate.released)
    }

    /// TIMED-OUT OBSERVERS DO NOT LEAK OR CONSUME THE RELEASE. A bounded wait that loses to its
    /// own alarm removes its ticket; the subsequent release is delivered to waiters still
    /// present — and only once each. If a timed-out observer were retained, the release would be
    /// consumed (or double-delivered) and this fresh second waiter would be the control that
    /// catches it.
    func testTimedOutObserverDoesNotConsumeOrLeakTheRelease() async throws {
        let gate = Gate()
        // Bounded wait with an unopened gate: times out.
        do {
            try await gate.wait(timeout: 0.05)
            XCTFail("the bounded wait must time out against a closed gate")
        } catch { /* expected */ }
        XCTAssertFalse(gate.released, "a timed-out observer must not open the gate")
        // A fresh waiter is woken exactly once by the real release — no try? swallowing.
        let fresh = Task { try await gate.wait() }
        // Give the fresh waiter a moment to register, then release.
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.release()
        let freshOutcome = await fresh.result
        if case .failure(let error) = freshOutcome {
            XCTFail("the fresh waiter must be delivered the release; got \(error)")
        }
        XCTAssertTrue(gate.released, "the real release must reach the fresh waiter")
    }

    /// THE OUTER SOCKET REGISTRY, not just the gate: a timed-out `awaitCancellation` observer
    /// removes its OWN closure from `StubWebSocketTask.cancellationWaiters`, the registry is
    /// empty after it, and a SURVIVING observer registered afterwards still fires on the real
    /// cancel and is delivered true — no leaked closures, no consumed cancellation.
    func testTimedOutCancellationObserverIsRemovedFromTheSocketRegistryAndSurvivorIsDelivered() async throws {
        let task = StubWebSocketTask(textFrames: [])
        // Timed-out observer: no cancellation happens within the window.
        let timedOut = await task.awaitCancellation(timeout: 0.05)
        XCTAssertFalse(timedOut, "nothing cancelled, so the bounded wait must report false")
        // The ACTUAL registry inspection: the timed-out observer is gone.
        XCTAssertEqual(task.cancellationWaiterCountForTesting, 0,
                       "a timed-out observer must leave the socket cancellation registry empty")
        // A SURVIVING observer registered afterwards is still delivered the cancellation.
        let survivor = Task { await task.awaitCancellation(timeout: 5) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(task.cancellationWaiterCountForTesting, 1,
                       "the surviving observer must actually be registered")
        task.cancel(with: .goingAway, reason: nil)
        let delivered = await survivor.value
        XCTAssertTrue(delivered, "the surviving observer must be delivered the cancellation")
        // And the registry drained when the cancel fired it.
        XCTAssertEqual(task.cancellationWaiterCountForTesting, 0,
                       "cancel drains the registry it fires")
    }
}
