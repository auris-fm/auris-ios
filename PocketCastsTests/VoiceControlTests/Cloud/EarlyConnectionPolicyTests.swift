import XCTest

@testable import podcasts

/// An early-opened cloud connection must not be reused once it is old enough that the server may
/// already have closed it. The client cannot tell why a connection closed, so this rule rests on
/// its own clock measured from the upgrade request — not on a close handler.
///
/// Getting the boundary wrong in the permissive direction sends a turn into a connection that is
/// gone: the user waits for an utterance that was never admitted, and the request has to be redone
/// from scratch. That is the failure these tests are written against, so the boundary is asserted
/// explicitly rather than left to whichever comparison the implementation happened to use.
final class EarlyConnectionPolicyTests: XCTestCase {

    /// A fresh connection is reusable — the rule must not reject the case it exists to enable.
    func test_freshConnectionMaySend() {
        XCTAssertTrue(EarlyConnectionPolicy.canSend(connectionAge: 0.5))
    }

    /// The server's idle limit is 10 seconds. At the client limit of 9 the margin is exactly what
    /// makes reuse safe, so a connection that has reached it is not reused.
    func test_connectionAtTheLimitIsNotReused() {
        XCTAssertFalse(EarlyConnectionPolicy.canSend(connectionAge: 9))
    }

    /// Just under the limit is still reusable: refusing earlier would throw away usable handshakes
    /// without protecting anything.
    func test_justUnderTheLimitIsReused() {
        XCTAssertTrue(EarlyConnectionPolicy.canSend(connectionAge: 8.99))
    }

    /// Past the limit, and past the server's own 10 second close, is certainly not reusable.
    func test_connectionPastTheLimitIsNotReused() {
        XCTAssertFalse(EarlyConnectionPolicy.canSend(connectionAge: 9.01))
        XCTAssertFalse(EarlyConnectionPolicy.canSend(connectionAge: 30))
    }

    /// The limit must sit strictly below the server's 10 second idle close, or the margin is gone
    /// and a send can arrive after admission has already been abandoned.
    func test_limitLeavesMarginUnderTheServerIdleClose() {
        XCTAssertLessThan(EarlyConnectionPolicy.maximumAgeSeconds, 10)
    }

    /// A reader must be able to tell from the log which decision was taken and on what age. Without
    /// the age, an abandoned connection looks like an ordinary fresh one.
    func test_decisionIsDescribedWithTheAge() {
        // Values chosen so no rounding rule can make the expectation ambiguous: `1.25` formats to
        // `1.2` under round-half-to-even, which is a correct format and a wrong thing to assert on.
        XCTAssertTrue(EarlyConnectionPolicy.describe(connectionAge: 1.4).contains("1.4"))
        XCTAssertTrue(EarlyConnectionPolicy.describe(connectionAge: 12.0).contains("12.0"))
    }
}