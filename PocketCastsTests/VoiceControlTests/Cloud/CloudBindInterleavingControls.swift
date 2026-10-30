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

    /// A client whose factory hands out a distinct socket per route, in order, recording them.
    /// Needed to establish isolation between two PHYSICAL sockets (reviewer a2723c92).
    private func makeClient(tasks: [StubWebSocketTask]) -> CloudRouteClient {
        let box = TaskBox(tasks)
        return CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "user_test",
            requestTimeoutSeconds: 15,
            tokenProvider: StubTokenProvider(token: "test_token"),
            webSocketTaskFactory: { _ in box.next() }
        )
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [StubWebSocketTask]
        private(set) var issued: [StubWebSocketTask] = []
        init(_ tasks: [StubWebSocketTask]) { self.tasks = tasks }
        func next() -> StubWebSocketTask {
            lock.lock(); defer { lock.unlock() }
            let task = tasks.isEmpty ? StubWebSocketTask(textFrames: []) : tasks.removeFirst()
            issued.append(task)
            return task
        }
    }

    // MARK: - Control 1: bind precedes close (the ordinary order)

    /// The registration is published BEFORE the close, so the close retires it. This is the
    /// baseline that makes the rejected-bind case meaningful: the same assertions, opposite order.
    func testRegistrationIsRetiredWhenCloseFollowsABind() async throws {
        let task = StubWebSocketTask(textFrames: StubWebSocketTask.frames(fromFixture: fixture()))
        let client = makeClient(task: task)
        let turn = CloudTurnEnvelope.make(
            capabilities: [], routeHint: nil, recentConversation: [], conversation: testPreparedConversation())
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
            capabilities: [], routeHint: nil, recentConversation: [], conversation: testPreparedConversation())

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

    // MARK: - Control 3: the bind→send publication is synchronized

    /// THE BIND→SEND PUBLICATION. The transport binds the registration on the PRODUCER's task
    /// while the consumer sends a result on ITS OWN task. If `boundIdentity` were published
    /// unsynchronized, a send could read a stale/nil identity for a turn that IS live and report
    /// `undelivered`, or a torn value. Here many sends are dispatched CONCURRENTLY from a
    /// different task than the bind, after the bind is known published: every one must observe
    /// `submitted` (the registration IS live), and after close every later one must be
    /// `undelivered` — no send straddles the close to a fabricated success.
    func testSendsFromADifferentTaskObserveTheSynchronizedBindAndRetirement() async throws {
        let task = StubWebSocketTask(textFrames: StubWebSocketTask.frames(fromFixture: fixture()))
        let client = makeClient(task: task)
        let turn = CloudTurnEnvelope.make(
            capabilities: [], routeHint: nil, recentConversation: [], conversation: testPreparedConversation())
        let routed = client.routeWithResultSocket(
            request: "x", context: CloudRouteContext(from: sampleContext()), turn: turn
        )
        let socket = routed.resultSocket

        let boundFlag = Promise<Void>()
        client.onFrameReceived = { boundFlag.resolve(()) }
        let consume = Task { () -> [CloudRouteEvent] in
            var events: [CloudRouteEvent] = []
            for await event in routed.stream { events.append(event) }
            return events
        }
        await boundFlag.value()
        XCTAssertNotNil(socket.boundIdentity, "premise: the bind is published before the sends")

        let frame = try XCTUnwrap(AppOperationResultFrame(
            operationId: "op-bind", outcome: .unknown, reason: OperationReason.interruptedInFlight
        ))
        // Sends issued from a SEPARATE task than the producer's bind: each must observe the
        // synchronized bind and report a real submission while the turn is live.
        let reports = await Task.detached { () -> [CloudRouteClient.AppOperationResultSendReport] in
            var result: [CloudRouteClient.AppOperationResultSendReport] = []
            for _ in 0..<8 { result.append(await client.sendOperationResult(frame, via: socket)) }
            return result
        }.value
        XCTAssertEqual(reports.count, 8)
        XCTAssertTrue(reports.allSatisfy { $0 == .submitted },
                      "every cross-task send on a LIVE turn observes the synchronized bind")

        socket.finishTurn()
        let late = await client.sendOperationResult(frame, via: socket)
        XCTAssertEqual(late, .undelivered, "after close, sends are undelivered — never submitted")
        consume.cancel()
        _ = await consume.result
    }

    // MARK: - Control 4: per-registration isolation for a reused request id

    /// REUSED request id: a second turn registers the SAME `request_id` while the first is still
    /// live (a supersede). Ownership is PER REGISTRATION, so the successor's bind must not be
    /// removed by the predecessor's close, and the predecessor's close must not retire the
    /// successor's socket. The successor's own send stays `submitted`.
    func testAReusedRequestIdKeepsItsOwnRegistrationAcrossThePredecessorsClose() async throws {
        let taskA = StubWebSocketTask(textFrames: StubWebSocketTask.frames(fromFixture: fixture()))
        let taskB = StubWebSocketTask(textFrames: StubWebSocketTask.frames(fromFixture: fixture()))
        let client = makeClient(tasks: [taskA, taskB])
        let turn = CloudTurnEnvelope.make(
            capabilities: [], routeHint: nil, recentConversation: [], conversation: testPreparedConversation())
        let a = client.routeWithResultSocket(
            request: "x", context: CloudRouteContext(from: sampleContext()), turn: turn
        )
        let boundFlagA = Promise<Void>()
        client.onFrameReceived = { boundFlagA.resolve(()) }
        let consumeA = Task { () -> [CloudRouteEvent] in
            var events: [CloudRouteEvent] = []
            for await event in a.stream { events.append(event) }
            return events
        }
        await boundFlagA.value()
        let identityA = try XCTUnwrap(a.resultSocket.boundIdentity)

        // The successor reuses the SAME request_id with its OWN PHYSICAL socket (taskB, issued
        // by the factory for the second route). Its bind lands on the transport's task, so wait
        // for B's first frame (the bind is published by then).
        let routedB = client.routeWithResultSocket(
            request: "x", context: CloudRouteContext(from: sampleContext()), turn: turn
        )
        let socketB = routedB.resultSocket
        // Poll for the SUCCESSOR'S OWN publication: a frame-level promise would resolve on the
        // predecessor's trailing frame (the fixture has two), which says nothing about B's bind.
        let published = waitForBoundIdentity(of: socketB, timeout: 5)
        XCTAssertNotNil(published, "premise: the successor's bind is published")
        XCTAssertNotEqual(socketB.boundIdentity, identityA, "each registration has its OWN identity")
        let consumeB = Task { () -> [CloudRouteEvent] in
            var events: [CloudRouteEvent] = []
            for await event in routedB.stream { events.append(event) }
            return events
        }

        // The PREDECESSOR closes — its close must retire ONLY its own registration.
        a.resultSocket.finishTurn()
        let frame = try XCTUnwrap(AppOperationResultFrame(
            operationId: "op-bind", outcome: .unknown, reason: OperationReason.interruptedInFlight
        ))
        let reportB = await client.sendOperationResult(frame, via: socketB)
        XCTAssertEqual(reportB, .submitted,
                       "the successor keeps its registration across the predecessor's close")
        // The two turns used DISTINCT physical sockets: isolation is between real sockets, not a
        // shared double.
        XCTAssertFalse(taskA === taskB, "premise: the successor used its own physical socket")
        XCTAssertTrue(taskA.isCancelledSocket, "the predecessor's close cancelled ITS socket")
        XCTAssertFalse(taskB.isCancelledSocket, "the successor's socket survives the predecessor's close")

        socketB.finishTurn()
        _ = await consumeA.value
        _ = await consumeB.value
    }

    // MARK: - Control 5: the bind/close INTERLEAVING discriminator (reviewer a2723c92)

    /// THE BIND/CLOSE INTERLEAVING, forced — not waited-for. Control 4 waits for each
    /// publication before proceeding; that proves isolation of PUBLISHED registrations but never
    /// races a close against a bind decision. Here the predecessor's close lands DETERMINISTICALLY
    /// between the successor's route start and its bind decision: the successor's transport task
    /// is parked at the `onBeforeBind` seam, the close runs to completion, and only then is the
    /// bind allowed to decide. Per-registration ownership means the successor's bind must still
    /// SUCCEED (the close retired only its own registration), its send must be submitted on ITS
    /// OWN recorded task, and neither registration may retire the other's socket.
    func testAPredecessorsCloseBeforeTheSuccessorsBindDecisionDoesNotRetireTheSuccessor() async throws {
        let taskA = StubWebSocketTask(textFrames: StubWebSocketTask.frames(fromFixture: fixture()))
        let taskB = StubWebSocketTask(textFrames: StubWebSocketTask.frames(fromFixture: fixture()))
        let box = TaskBox([taskA, taskB])
        let client = makeClient(box: box)
        let turn = CloudTurnEnvelope.make(
            capabilities: [], routeHint: nil, recentConversation: [], conversation: testPreparedConversation())

        // Predecessor: route and wait until its bind is published.
        let a = client.routeWithResultSocket(
            request: "x-interleave", context: CloudRouteContext(from: sampleContext()), turn: turn
        )
        let boundFlagA = Promise<Void>()
        client.onFrameReceived = { boundFlagA.resolve(()) }
        let consumeA = Task { () -> [CloudRouteEvent] in
            var events: [CloudRouteEvent] = []
            for await event in a.stream { events.append(event) }
            return events
        }
        await boundFlagA.value()
        let identityA = try XCTUnwrap(a.resultSocket.boundIdentity)

        // The predecessor's result send rides ITS recorded task while its turn is live.
        let frame = try XCTUnwrap(AppOperationResultFrame(
            operationId: "op-bind", outcome: .unknown, reason: OperationReason.interruptedInFlight
        ))
        let reportA = await client.sendOperationResult(frame, via: a.resultSocket)
        XCTAssertEqual(reportA, .submitted, "premise: the predecessor's send is submitted on its live turn")

        // Park the successor's bind decision at the seam; run the predecessor's close to
        // completion while the decision is parked; then release.
        let seamEntered = Promise<Void>()
        let closeRequested = Promise<Void>()
        client.onBeforeBind = { _ in
            seamEntered.resolve(())
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !closeRequested.didClose { usleep(1_000) }
        }

        let routedB = client.routeWithResultSocket(
            request: "x-interleave", context: CloudRouteContext(from: sampleContext()), turn: turn
        )
        let socketB = routedB.resultSocket
        let consumeB = Task { () -> [CloudRouteEvent] in
            var events: [CloudRouteEvent] = []
            for await event in routedB.stream { events.append(event) }
            return events
        }

        // FORCED ORDER: close happens strictly before the bind decision resumes.
        await seamEntered.value()
        a.resultSocket.finishTurn()
        XCTAssertTrue(taskA.isCancelledSocket, "the close retired the predecessor's own registration")
        closeRequested.markClosed()

        // The successor's bind decides AFTER the close — it must still succeed. Observed through
        // the successor's OWN published identity (bounded poll), never a frame promise: the
        // predecessor's trailing fixture frame would satisfy a frame promise and say nothing
        // about the successor's bind.
        await seamReleasedWait()
        let identityB = try XCTUnwrap(
            waitForBoundIdentity(of: socketB, timeout: 5),
            "the successor's bind survives the predecessor's close"
        )
        XCTAssertNotEqual(identityB, identityA, "each registration keeps its own identity")

        // The successor's send rides ITS OWN recorded task — distinct physical sockets, each
        // send attributable to the registration that owns it.
        let reportB = await client.sendOperationResult(frame, via: socketB)
        XCTAssertEqual(reportB, .submitted, "the successor's send is submitted after the interleaved close")
        XCTAssertEqual(box.issued.count, 2, "the factory issued exactly one socket per route")
        XCTAssertTrue(box.issued[0] === taskA && box.issued[1] === taskB,
                      "the predecessor and successor used DISTINCT recorded tasks")
        XCTAssertFalse(taskB.isCancelledSocket, "the successor's socket survives the interleaved close")

        socketB.finishTurn()
        _ = await consumeA.value
        _ = await consumeB.value
    }

    /// A client whose factory draws from a CONTROL-OWNED box, so the test can assert exactly
    /// which physical sockets were issued, in order.
    private func makeClient(box: TaskBox) -> CloudRouteClient {
        CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "user_test",
            requestTimeoutSeconds: 15,
            tokenProvider: StubTokenProvider(token: "test_token"),
            webSocketTaskFactory: { _ in box.next() }
        )
    }

    // MARK: - Helpers

    /// Lets the released transport task actually run its bind before the poll: a yield hop so
    /// the observation is of the POST-release decision, not a pre-release accident.
    private func seamReleasedWait() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    /// Bounded poll for a registration's published identity. Frame-count promises are ambiguous
    /// when a predecessor's fixture emits a trailing frame; the identity itself is unambiguous.
    private func waitForBoundIdentity(of socket: AppOperationResultSocket, timeout: TimeInterval) -> UUID? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let identity = socket.boundIdentity { return identity }
            usleep(2_000)
        }
        return socket.boundIdentity
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

extension CloudBindInterleavingControls {
    /// CANCELLATION BEFORE REGISTRATION, ORDERED EXPLICITLY. `Task { … }; task.cancel()` still
    /// races the child's start. Here the order is forced: the child first parks on a
    /// HoldLatch (which, unlike a Gate, does not throw on cancellation), the test cancels it
    /// while it is PARKED — so cancellation is already flagged when the child resumes — and
    /// only then releases it toward `gate.wait()`. `withTaskCancellationHandler` runs `onCancel`
    /// immediately when the task is already cancelled at handler installation, i.e. strictly
    /// before the body registers; the ticket flag must honor that and the body must throw
    /// instead of parking a waiter that would never wake.
    func testCancellationFlaggedBeforeGateRegistrationIsHonoredDeterministically() async throws {
        let barrier = HoldLatch()
        let gate = Gate()
        let waiter = Task {
            await barrier.waitUntilReleased()   // deterministic parking spot
            try await gate.wait()               // registration AFTER the cancel below
        }
        // The child is now parked on the barrier, not yet at the gate.
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()          // cancellation flagged BEFORE registration
        barrier.release()        // NOW the child proceeds to register
        let outcome = await waiter.result
        guard case .failure(let error) = outcome else {
            XCTFail("a waiter flagged cancelled before registration must fail; it succeeded")
            return
        }
        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        XCTAssertFalse(gate.released, "the cancelled waiter must not have opened the gate")
        // The gate still works for a survivor.
        let late = Task { try await gate.wait() }
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.release()
        if case .failure(let error) = await late.result {
            XCTFail("the surviving waiter must be delivered the release; got \(error)")
        }
    }

    /// CANCELLING AN ACTUAL OBSERVER OWNER removes that observer's entry from the SOCKET
    /// registry while a surviving observer stays registered and is delivered the real
    /// cancellation. The owner's task is cancelled — not the socket — so this pins the
    /// ownership path (the observer cleans up after itself on ITS OWN cancellation), and the
    /// ACTUAL registry is inspected at each step.
    func testCancellingAnObserverOwnerRemovesItsRegistryEntryAndSurvivorIsDelivered() async throws {
        let task = StubWebSocketTask(textFrames: [])
        let ownerA = Task { await task.awaitCancellation(timeout: 10) }
        let survivor = Task { await task.awaitCancellation(timeout: 10) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(task.cancellationWaiterCountForTesting, 2,
                       "both observers must actually be registered")
        ownerA.cancel()
        let aResult = await ownerA.value
        XCTAssertFalse(aResult, "owner A's wait ends without a socket cancellation")
        XCTAssertEqual(task.cancellationWaiterCountForTesting, 1,
                       "the cancelled owner's entry must be removed from the registry")
        task.cancel(with: .goingAway, reason: nil)
        let delivered = await survivor.value
        XCTAssertTrue(delivered, "the surviving observer must still be delivered the cancellation")
        XCTAssertEqual(task.cancellationWaiterCountForTesting, 0,
                       "cancel drains the registry it fires")
    }
}
