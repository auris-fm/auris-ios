import XCTest
import PocketCastsUtils

@testable import podcasts

/// The freshness rule must actually gate the connection the turn uses, and getting it wrong must
/// not cost the user their turn.
///
/// `EarlyConnectionPolicyTests` proves the arithmetic. These tests prove the transport consults it,
/// because a rule that is written but never reached would pass every unit test of the policy while
/// a stale connection still carried a turn.
final class CloudRouteStaleConnectionTests: XCTestCase {
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
            tokenProvider: StubTokenProvider(token: "test_token"),
            webSocketTaskFactory: { _ in task },
            now: { clock.read() },
            inheritedConnectionAge: inheritedAge.map { age in { age } }
        )
    }

    private func makeTurn() -> CloudTurnEnvelope {
        CloudTurnEnvelope.make(
            capabilities: [], routeHint: nil,
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

    /// A socket that DIED inside the age limit is still young, so the age rule cannot see it. The
    /// turn must complete anyway: the user already spoke, and a server close or a network change
    /// within nine seconds is ordinary on a phone.
    ///
    /// The break this catches: the inherited socket is used because it is fresh, its first send
    /// fails, and the turn ends in `connection_lost` — the answer is lost with no second attempt.
    /// Age is knowable before the send; death is not, so a pre-send freshness check can never
    /// cover this case however carefully it is placed.
    func test_aDeadInheritedConnectionStillCompletesItsTurn() async {
        let dead = StubWebSocketTask(textFrames: [])
        // The socket is DEAD, which is what the take-time liveness read must notice. Its send also
        // fails, so a client that ignores liveness still cannot complete the turn on it.
        dead.reportsAlive = false
        dead.throwsBeforeRecording = true
        // `connected` precedes the terminal on a real turn: codec negotiation happens before
        // admission, so a script that starts at `done` is one no server produces.
        let fresh = StubWebSocketTask(textFrames: [
            #"{"type":"connected","codec":"pcm_s16le@24k"}"#,
            #"{"type":"done","outcome":"completed","usage":{"input_tokens":1,"output_tokens":0}}"#
        ])
        var issued: [StubWebSocketTask] = []
        let clock = SteppableClock()
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            tokenProvider: StubTokenProvider(token: "test_token"),
            webSocketTaskFactory: { _ in
                let task = issued.isEmpty ? dead : fresh
                issued.append(task)
                return task
            },
            now: { clock.read() }
        )

        XCTAssertTrue(client.openEarlyConnection(), "premise: the turn must inherit a connection")
        // Well inside the limit, so staleness cannot be what triggers a replacement — the case
        // would otherwise pass for a reason unrelated to the socket being dead.
        clock.set(clock.read().addingTimeInterval(1))

        let turn = makeTurn()
        let events = await collect(client.route(
            request: "skip forward", context: sampleContext, turn: turn
        ))

        XCTAssertTrue(dead.sent.isEmpty,
                      "premise: the first send must fail before the frame leaves, or a retry could duplicate the turn")
        // The dead socket must be refused BEFORE any send is attempted on it. Asserting only that
        // the turn completes is also satisfied by the retry path, and asserting the refusal LOG LINE
        // is satisfied by other tests in the same run — the log is shared. So assert the absence of
        // a send attempt on THIS socket, which only the take-time check can prevent.
        let attemptLog = await FileLog.shared.logFileAsString()
        XCTAssertFalse(attemptLog.split(separator: "\n").contains {
            $0.contains("inherited connection failed before the turn was sent") && $0.contains(turn.requestId)
        }, "a dead socket must be refused at take time, not discovered by a failed send")
        XCTAssertEqual(issued.count, 2, "a dead inherited socket must be replaced by a fresh one")
        XCTAssertFalse(fresh.sentTextFrames.isEmpty, "the turn must send on the replacement")
        let completed = events.contains { event in
            if case .done(_, let outcome) = event { return outcome == .completed }
            return false
        }
        XCTAssertTrue(completed,
                      "the turn must COMPLETE, not end in connection_lost: \(events)")
        let transportLoss = events.contains { event in
            if case .error(_, let code, _) = event { return code == "connection_lost" }
            return false
        }
        XCTAssertFalse(transportLoss, "a recoverable first send must not surface as a lost turn: \(events)")
    }

    /// A send that fails on an INHERITED connection is retried once on a fresh socket, carrying the
    /// SAME request id — the turn is the same logical turn, and a new id would make the server run
    /// two turns for one utterance.
    ///
    /// The break this catches: the failure is surfaced immediately, so an utterance whose socket
    /// died between the liveness check and the send loses its answer with no second attempt.
    func test_aFailedSendOnAnInheritedConnectionIsRetriedOnceWithTheSameRequestId() async {
        let first = StubWebSocketTask(textFrames: [])
        // ALIVE when taken, so the liveness read passes and the turn commits to this socket. It
        // then fails before the frame leaves — the window no pre-send check can close.
        first.throwsBeforeRecording = true
        let second = StubWebSocketTask(textFrames: [
            #"{"type":"connected","codec":"pcm_s16le@24k"}"#,
            #"{"type":"done","outcome":"completed","usage":{"input_tokens":1,"output_tokens":0}}"#
        ])
        var issued: [StubWebSocketTask] = []
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            tokenProvider: StubTokenProvider(token: "test_token"),
            webSocketTaskFactory: { _ in
                let task = issued.isEmpty ? first : second
                issued.append(task)
                return task
            }
        )

        XCTAssertTrue(client.openEarlyConnection(), "premise: the turn must inherit a connection")

        let events = await collect(client.route(
            request: "skip forward", context: sampleContext, turn: makeTurn()
        ))

        XCTAssertEqual(issued.count, 2, "exactly one retry, not a loop")
        XCTAssertFalse(second.sentTextFrames.isEmpty, "the retry must actually send")
        let firstId = first.sentAuthFrame?["request_id"] as? String
        let secondId = second.sentAuthFrame?["request_id"] as? String
        XCTAssertNil(firstId, "premise: the first frame never left, so it carries no id on the wire")
        XCTAssertNotNil(secondId, "the retry must carry a request id")
        let completed = events.contains { event in
            if case .done(_, let outcome) = event { return outcome == .completed }
            return false
        }
        XCTAssertTrue(completed, "the retried turn must complete: \(events)")
    }

    /// A retry answered `duplicate_request` means the FIRST frame did start a turn whose answer was
    /// going to a dead socket. The user must hear the ordinary connection-loss feedback, never a
    /// refusal that reads as "you may not do that" — the turn is running, not forbidden.
    ///
    /// The break this catches: the server's code is passed through verbatim, so a recoverable
    /// transport loss is spoken as a request refusal.
    func test_aRetryAnsweredDuplicateRequestIsReportedAsConnectionLost() async {
        let first = StubWebSocketTask(textFrames: [])
        first.transmitsThenThrows = true
        // A refused retry gets `error` as its FIRST and ONLY frame, then the socket closes:
        // `connected` carries the reservation and is sent only once a turn is ADMITTED, which a
        // duplicate never is. Scripting a `connected` here would wait for a frame that never comes.
        let second = StubWebSocketTask(textFrames: [
            #"{"type":"error","code":"duplicate_request","message":"already admitted"}"#
        ])
        var issued: [StubWebSocketTask] = []
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            tokenProvider: StubTokenProvider(token: "test_token"),
            webSocketTaskFactory: { _ in
                let task = issued.isEmpty ? first : second
                issued.append(task)
                return task
            }
        )

        XCTAssertTrue(client.openEarlyConnection(), "premise: the turn must inherit a connection")

        let events = await collect(client.route(
            request: "skip forward", context: sampleContext, turn: makeTurn()
        ))

        XCTAssertEqual(first.sent.count, 1,
                       "premise: the first frame must have been transmitted, or this is not the ambiguous case")
        XCTAssertEqual(issued.count, 2, "the retry must have happened for its answer to be classified")
        // Without this the code assertion below is satisfied by the FIRST failure alone: a client
        // that never retries also reports `connection_lost`, so the mapping would never be exercised.
        // The retry must have sent, and the server's `duplicate_request` must have come back on it.
        XCTAssertFalse(second.sentTextFrames.isEmpty,
                       "premise: the retry must reach the server, or no duplicate was ever answered")
        let log = await FileLog.shared.logFileAsString()
        XCTAssertTrue(log.split(separator: "\n").contains { $0.contains("server error code=duplicate_request") },
                      "premise: the duplicate must actually arrive, or the code below is the first failure's")
        let codes = events.compactMap { event -> String? in
            if case .error(_, let code, _) = event { return code }
            return nil
        }
        XCTAssertEqual(codes, ["connection_lost"],
                       "a duplicate after a transmitted first frame is a lost answer, not a refusal: \(events)")
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
