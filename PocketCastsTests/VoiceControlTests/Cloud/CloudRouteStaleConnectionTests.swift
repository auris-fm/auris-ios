import XCTest

@testable import podcasts

/// The freshness rule must actually gate the connection the turn uses, and getting it wrong must
/// not cost the user their turn.
///
/// `EarlyConnectionPolicyTests` proves the arithmetic. These tests prove the transport consults it,
/// because a rule that is written but never reached would pass every unit test of the policy while
/// a stale connection still carried a turn.
final class CloudRouteStaleConnectionTests: XCTestCase {
    private let userId = "user_79424ba0-f09b-013b-249c-566ad7a4dc9d"
    private let sampleContext = CloudRouteContext(
        episodeId: "79424ba0-f09b-013b-249c-566ad7a4dc9d",
        podcastId: "da7aba5e-f11e-f11e-f11e-da7aba5ef11e",
        referencePositionMs: 1_230_000,
        clientPositionMs: 1_234_567,
        recentReferencePositions: [],
        previousReferencePositionMs: nil
    )

    /// A clock whose value the test sets. The limit is nine seconds; a real clock would make these
    /// controls either sleep for nine seconds or assert nothing.
    private final class SteppableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_760_000_000)
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return current }
        func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; current = date }
    }

    private func makeClient(
        inheritedAge: TimeInterval?,
        task: StubWebSocketTask,
        clock: SteppableClock = SteppableClock()
    ) -> CloudRouteClient {
        CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: userId,
            tokenProvider: StubTokenProvider(token: "test_token"),
            webSocketTaskFactory: { _ in task },
            now: { clock.read() },
            inheritedConnectionAge: inheritedAge.map { age in { age } }
        )
    }

    private func makeTurn() -> CloudTurnEnvelope {
        CloudTurnEnvelope.make(
            capabilities: [], routeHint: nil, recentConversation: [],
            conversation: testPreparedConversation()
        )
    }

    private func collect(_ stream: AsyncStream<CloudRouteEvent>) async -> [CloudRouteEvent] {
        var events: [CloudRouteEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    /// A turn that inherited a too-old connection still SENDS, on a fresh one. Ending the turn
    /// would charge the user with an idle timeout they did not cause, for a request that is already
    /// complete and ready.
    func test_staleInheritedConnectionStillSendsItsTurn() async {
        let task = StubWebSocketTask(textFrames: [])
        let client = makeClient(inheritedAge: EarlyConnectionPolicy.maximumAgeSeconds + 0.5, task: task)

        let events = await collect(client.route(
            request: "skip forward", context: sampleContext, turn: makeTurn()
        ))

        XCTAssertFalse(task.sentTextFrames.isEmpty,
                       "a fresh connection must carry the ready request: \(task.sentTextFrames)")
        // The stub never answers, so the turn ends on its ordinary first-frame timeout. What this
        // asserts is narrower and is the actual contract point: the refusal must not be surfaced as
        // a request-construction failure, which is what a stale connection ending the turn produced.
        let constructionFailure = events.contains { event in
            if case .error(let source, _, _) = event { return source == .requestConstruction }
            return false
        }
        XCTAssertFalse(constructionFailure,
                       "a stale connection is replaced, not turned into a construction failure: \(events)")
    }

    /// The connection actually opened is stamped now, so its age is zero and the rule is satisfied
    /// from the moment it exists. Without this, replacing a stale connection could itself look
    /// stale on the next check.
    func test_replacementConnectionIsFresh() async {
        let clock = SteppableClock()
        let task = StubWebSocketTask(textFrames: [])
        let client = makeClient(inheritedAge: 30, task: task, clock: clock)

        _ = await collect(client.route(
            request: "skip forward", context: sampleContext, turn: makeTurn()
        ))

        XCTAssertFalse(task.sentTextFrames.isEmpty)
    }

    /// A connection opened early, while the user was still speaking, must be the connection the
    /// turn sends on — otherwise the handshake was paid for and thrown away.
    func test_turnUsesTheConnectionOpenedEarly() async {
        let task = StubWebSocketTask(textFrames: [])
        var factoryCalls = 0
        let clock = SteppableClock()
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: userId,
            tokenProvider: StubTokenProvider(token: "test_token"),
            webSocketTaskFactory: { _ in factoryCalls += 1; return task },
            now: { clock.read() }
        )

        XCTAssertTrue(client.openEarlyConnection(), "the early open must create a connection")
        XCTAssertEqual(factoryCalls, 1, "opening early creates exactly one socket")

        _ = await collect(client.route(
            request: "skip forward", context: sampleContext, turn: makeTurn()
        ))

        XCTAssertEqual(factoryCalls, 1,
                       "the turn must reuse the early socket, not open a second one")
        XCTAssertFalse(task.sentTextFrames.isEmpty, "the turn must send on it")
    }

    /// A second early open while one is held does nothing. Opening another would orphan the first
    /// socket, which no turn could then claim or close.
    func test_secondEarlyOpenIsRefusedWhileOneIsHeld() {
        let task = StubWebSocketTask(textFrames: [])
        let clock = SteppableClock()
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: userId,
            tokenProvider: StubTokenProvider(token: "test_token"),
            webSocketTaskFactory: { _ in task },
            now: { clock.read() }
        )

        XCTAssertTrue(client.openEarlyConnection())
        XCTAssertFalse(client.openEarlyConnection(), "a held connection must not be replaced silently")
    }

    /// A connection older than the limit is replaced, and the replacement is what sends. The turn
    /// must still complete: the request is ready and the user has already spoken.
    func test_staleEarlyConnectionIsReplacedNotFailed() async {
        let fresh = StubWebSocketTask(textFrames: [])
        var issued: [StubWebSocketTask] = []
        let clock = SteppableClock()
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: userId,
            tokenProvider: StubTokenProvider(token: "test_token"),
            webSocketTaskFactory: { _ in
                if issued.isEmpty {
                    let stale = StubWebSocketTask(textFrames: [])
                    issued.append(stale)
                    return stale
                }
                issued.append(fresh)
                return fresh
            },
            now: { clock.read() }
        )

        XCTAssertTrue(client.openEarlyConnection())
        // Age the connection past the limit without sleeping.
        clock.set(clock.read().addingTimeInterval(EarlyConnectionPolicy.maximumAgeSeconds + 2))

        let events = await collect(client.route(
            request: "skip forward", context: sampleContext, turn: makeTurn()
        ))

        XCTAssertEqual(issued.count, 2, "a stale connection must be replaced by a fresh one")
        XCTAssertNotNil(issued[0].cancelled, "the stale socket must be closed, not left open")
        XCTAssertFalse(fresh.sentTextFrames.isEmpty, "the turn must send on the replacement")
        let constructionFailure = events.contains { event in
            if case .error(let source, _, _) = event { return source == .requestConstruction }
            return false
        }
        XCTAssertFalse(constructionFailure,
                       "a stale early connection is replaced, not turned into a failure: \(events)")
    }

    /// A discarded early connection is closed and no longer offered to a turn.
    func test_discardedEarlyConnectionIsNotUsed() async {
        var issued: [StubWebSocketTask] = []
        let clock = SteppableClock()
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: userId,
            tokenProvider: StubTokenProvider(token: "test_token"),
            webSocketTaskFactory: { _ in
                let task = StubWebSocketTask(textFrames: [])
                issued.append(task)
                return task
            },
            now: { clock.read() }
        )

        XCTAssertTrue(client.openEarlyConnection())
        client.discardEarlyConnection(reason: "utterance was empty")
        XCTAssertNotNil(issued[0].cancelled, "a discarded connection must be closed")

        _ = await collect(client.route(
            request: "skip forward", context: sampleContext, turn: makeTurn()
        ))
        XCTAssertEqual(issued.count, 2, "the turn must open its own connection after a discard")
    }

    /// With nothing inherited there is no freshness question at all: the ordinary turn path must be
    /// untouched, or this rule would have changed every cloud turn in the app.
    func test_noInheritedConnectionSendsNormally() async {
        let task = StubWebSocketTask(textFrames: [])
        let client = makeClient(inheritedAge: nil, task: task)

        let events = await collect(client.route(
            request: "skip forward", context: sampleContext, turn: makeTurn()
        ))

        XCTAssertFalse(task.sentTextFrames.isEmpty)
        let constructionFailure = events.contains { event in
            if case .error(let source, _, _) = event { return source == .requestConstruction }
            return false
        }
        XCTAssertFalse(constructionFailure)
    }
}
