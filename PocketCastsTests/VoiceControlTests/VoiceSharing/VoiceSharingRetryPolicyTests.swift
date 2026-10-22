import XCTest
@testable import podcasts

final class VoiceSharingRetryPolicyTests: XCTestCase {
    /// Jitter disabled (1x) unless a test is about jitter.
    private func policy(
        minimumDelay: TimeInterval = 0,
        baseDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 60,
        jitter: ClosedRange<Double> = 1.0...1.0,
        random: @escaping () -> Double = { 0.5 }
    ) -> VoiceSharingRetryPolicy {
        VoiceSharingRetryPolicy(
            minimumDelay: minimumDelay, baseDelay: baseDelay,
            maximumDelay: maximumDelay, jitterMultiplierRange: jitter, random: random)
    }

    func test_delayGrowsExponentiallyWithAttemptIndex() {
        let p = policy(baseDelay: 1)
        XCTAssertEqual(p.delay(afterAttempt: 1, serverRetryAfter: nil), 1)
        XCTAssertEqual(p.delay(afterAttempt: 2, serverRetryAfter: nil), 2)
        XCTAssertEqual(p.delay(afterAttempt: 3, serverRetryAfter: nil), 4)
        XCTAssertEqual(p.delay(afterAttempt: 4, serverRetryAfter: nil), 8)
    }

    func test_delayIsCappedAtMaximum() {
        let p = policy(baseDelay: 1, maximumDelay: 10)
        XCTAssertEqual(p.delay(afterAttempt: 10, serverRetryAfter: nil), 10)
    }

    func test_validServerRetryAfterOverridesExponentialWhenLarger() {
        let p = policy(baseDelay: 1)
        XCTAssertEqual(p.delay(afterAttempt: 1, serverRetryAfter: 30), 30,
                       "a larger server demand is honored over the local exponential")
        XCTAssertEqual(p.delay(afterAttempt: 6, serverRetryAfter: 3), 32,
                       "a smaller server demand does not shrink the exponential")
    }

    func test_serverValueIsCappedAtMaximum() {
        let p = policy(baseDelay: 1, maximumDelay: 10)
        XCTAssertEqual(p.delay(afterAttempt: 1, serverRetryAfter: 3600), 10,
                       "a compiled ceiling bounds server demands too")
    }

    func test_invalidServerValuesAreIgnored() {
        let p = policy(baseDelay: 1)
        for invalid: TimeInterval in [0, -5, .nan, .infinity] {
            XCTAssertEqual(p.delay(afterAttempt: 1, serverRetryAfter: invalid), 1,
                           "invalid Retry-After (\(invalid)) is treated as absent")
        }
    }

    func test_floorAppliesEvenWhenBothSourcesAreSmaller() {
        let p = policy(minimumDelay: 5, baseDelay: 1)
        XCTAssertEqual(p.delay(afterAttempt: 1, serverRetryAfter: 0.5), 5,
                       "neither a small exponential nor a small server value may retry sooner than the floor")
    }

    func test_floorDoesNotShrinkLargerDelays() {
        let p = policy(minimumDelay: 5, baseDelay: 1)
        XCTAssertEqual(p.delay(afterAttempt: 4, serverRetryAfter: nil), 8)
    }

    func test_jitterScalesTheComputedDelayWithinBounds() {
        // random bounds map onto [lo, hi] multiplicatively: 0 → lo, 1 → hi.
        let lo = policy(jitter: 0.8...1.2, random: { 0 }).delay(afterAttempt: 3, serverRetryAfter: nil)
        let hi = policy(jitter: 0.8...1.2, random: { 1 }).delay(afterAttempt: 3, serverRetryAfter: nil)
        XCTAssertEqual(lo, 3.2, accuracy: 1e-9) // 4 * 0.8
        XCTAssertEqual(hi, 4.8, accuracy: 1e-9) // 4 * 1.2
    }

    func test_jitterNeverViolatesFloorOrCap() {
        let p = policy(minimumDelay: 5, baseDelay: 1, maximumDelay: 6, jitter: 0.1...10, random: { 1 })
        XCTAssertEqual(p.delay(afterAttempt: 1, serverRetryAfter: 0.5), 6,
                       "jittered floor*10 is clamped back to the cap")
        let floored = policy(minimumDelay: 5, baseDelay: 1, jitter: 0.1...10, random: { 0.01 })
            .delay(afterAttempt: 1, serverRetryAfter: 0.5)
        XCTAssertEqual(floored, 5, accuracy: 1e-9,
                       "jittered 0.5*0.1 is raised back to the floor")
    }

    func test_attemptZeroOrNegativeIsRefused() {
        let p = policy(baseDelay: 1)
        XCTAssertThrowsError(try p.validatedDelay(afterAttempt: 0, serverRetryAfter: nil))
    }
}
