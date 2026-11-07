import XCTest
@testable import podcasts

final class VoiceSharingRetryPolicyTests: XCTestCase {
    private func policy(
        base: TimeInterval = 1,
        maximum: TimeInterval = 60,
        random: @escaping () -> Double = { 0 }
    ) -> VoiceSharingRetryPolicy {
        VoiceSharingRetryPolicy(retryBaseDelay: base, retryMaximumDelay: maximum, random: random)
    }

    // MARK: Local full-jitter component

    func test_fullJitterSpansZeroToCeiling() {
        // ceiling = min(60, 1 * 2^2) = 4 for attempt 3.
        XCTAssertEqual(policy(random: { 0 }).delay(afterAttempt: 3, serverRetryAfter: nil), 0,
                       "the distribution starts at zero — no positive floor")
        XCTAssertEqual(policy(random: { 1 }).delay(afterAttempt: 3, serverRetryAfter: nil), 4)
        XCTAssertEqual(policy(random: { 0.25 }).delay(afterAttempt: 3, serverRetryAfter: nil), 1,
                       "intermediate sample maps linearly")
    }

    func test_ceilingGrowsExponentiallyAndCapsAtMaximum() {
        XCTAssertEqual(policy(random: { 1 }).delay(afterAttempt: 1, serverRetryAfter: nil), 1)
        XCTAssertEqual(policy(random: { 1 }).delay(afterAttempt: 2, serverRetryAfter: nil), 2)
        XCTAssertEqual(policy(base: 1, maximum: 10, random: { 1 })
            .delay(afterAttempt: 10, serverRetryAfter: nil), 10,
            "the local ceiling never exceeds retry_max_s")
    }

    // MARK: Retry-After is a MINIMUM — never jittered down, never truncated

    func test_retryAfterIsHonoredAsMinimumEvenWhenBelowCeiling() {
        // jittered local = 0 (random 0); server asks 3 → delay is exactly 3.
        XCTAssertEqual(policy(random: { 0 }).delay(afterAttempt: 3, serverRetryAfter: 3), 3)
        // jittered local = 4, server asks 3 → the larger local sample stands.
        XCTAssertEqual(policy(random: { 1 }).delay(afterAttempt: 3, serverRetryAfter: 3), 4)
    }

    func test_retryAfterAboveLocalMaximumIsNotTruncated() {
        XCTAssertEqual(policy(base: 1, maximum: 10, random: { 0 })
            .delay(afterAttempt: 1, serverRetryAfter: 3600), 3600,
            "a server demand outlasting local bounds is the caller's deferral decision")
    }

    func test_jitterNeverUndercutsTheServerMinimum() {
        XCTAssertEqual(policy(random: { 0.01 }).delay(afterAttempt: 5, serverRetryAfter: 30), 30,
                       "multiplier sampling must not shorten a server demand")
    }

    func test_invalidServerValuesAreIgnored() {
        let p = policy(base: 1, random: { 0.5 })
        for invalid: TimeInterval in [0, -5, .nan, .infinity] {
            XCTAssertEqual(p.delay(afterAttempt: 1, serverRetryAfter: invalid), 0.5,
                           "invalid Retry-After (\(invalid)) is treated as absent")
        }
    }

    func test_attemptZeroOrNegativeIsRefused() {
        XCTAssertThrowsError(try policy().validatedDelay(afterAttempt: 0, serverRetryAfter: nil))
    }
}
