import XCTest

@testable import podcasts

/// The age limit must actually gate the send, not merely exist as a function.
///
/// This is the difference between a control and a decoration: `EarlyConnectionPolicyTests` proves
/// the arithmetic is right, and these tests prove the transport calls it. A guard that is written
/// but never reached would pass every unit test of the policy and still let a stale connection
/// carry a turn.
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

    /// A clock whose value the test advances. The limit is nine seconds; a real clock would make
    /// these controls either sleep for nine seconds or assert nothing.
    private final class SteppableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_760_000_000)
        private var readings = 0

        func read() -> Date {
            lock.lock()
            defer { lock.unlock() }
            readings += 1
            return current
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
    }

    /// Ages the connection between the upgrade request and the send, which is exactly the window
    /// the rule governs. The clock is advanced once the upgrade has been stamped, so the turn
    /// genuinely observes an old connection rather than a fabricated one.
    private func makeClient(
        ageBy: TimeInterval,
        task: StubWebSocketTask
    ) -> (CloudRouteClient, SteppableClock) {
        let clock = SteppableClock()
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: userId,
            tokenProvider: StubTokenProvider(token: "test_token"),
            webSocketTaskFactory: { _ in
                // The factory is called immediately after the upgrade stamp, so advancing here
                // makes the connection `ageBy` seconds old by the time the send is reached.
                clock.advance(ageBy)
                return task
            },
            now: { clock.read() }
        )
        return (client, clock)
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

    /// Past the limit the turn must not be submitted: no auth frame leaves, and the caller gets a
    /// terminal error instead of silence. Silence would leave the user waiting on a turn that was
    /// never admitted.
    func test_connectionPastTheLimitIsNotSubmitted() async {
        let task = StubWebSocketTask(textFrames: [])
        let (client, _) = makeClient(ageBy: EarlyConnectionPolicy.maximumAgeSeconds + 0.5, task: task)

        let events = await collect(client.route(
            request: "skip forward",
            context: sampleContext,
            turn: makeTurn()
        ))

        XCTAssertTrue(task.sentTextFrames.isEmpty,
                      "no frame may be sent on a connection past the limit: \(task.sentTextFrames)")
        let isStaleError = events.contains { event in
            if case .error(_, let code, _) = event { return code == "connection_stale" }
            return false
        }
        XCTAssertTrue(isStaleError, "the caller must learn the connection was too old: \(events)")
    }

    /// A fresh connection still sends normally. Without this, an implementation that refuses every
    /// turn would pass the test above.
    func test_freshConnectionIsSubmitted() async {
        let task = StubWebSocketTask(textFrames: [])
        let (client, _) = makeClient(ageBy: 0, task: task)

        _ = await collect(client.route(
            request: "skip forward",
            context: sampleContext,
            turn: makeTurn()
        ))

        XCTAssertFalse(task.sentTextFrames.isEmpty,
                       "a fresh connection must carry its auth frame")
    }
}