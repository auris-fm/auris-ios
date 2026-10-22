import Foundation

/// Pure retry/backoff scheduling for the downstream uploader (spec "Client queue and
/// scheduling"). The upload QUEUE deliberately stays free of network policy; this type is the
/// decision the uploader will call between attempts, kept independent so it can be pinned by
/// controls before it is wired.
///
/// Semantics (each pinned by a control):
///   * Exponential growth: `baseDelay * 2^(attempt-1)`, `attempt` 1-based (first failure = 1).
///   * A valid server `Retry-After` (finite, > 0) overrides the exponential when LARGER and never
///     shrinks it. Invalid values (zero, negative, NaN, infinite) are treated as absent — a
///     malformed header must not manufacture an immediate retry.
///   * `minimumDelay` is a FLOOR for every computed delay: neither a small exponential nor a small
///     (or invalid) server value may retry sooner. It never shrinks a larger delay.
///   * `maximumDelay` is a compiled CEILING bounding local growth, server demands, and jittered
///     results alike. Like every numeric limit in this feature it is an implementation bound,
///     NOT an owner-approved activation value.
///   * Jitter multiplies the computed delay by a factor sampled from `jitterMultiplierRange`
///     (`random()` 0 → lower bound, 1 → upper bound), then the floor/cap are re-applied so jitter
///     can violate neither.
struct VoiceSharingRetryPolicy {
    let minimumDelay: TimeInterval
    let baseDelay: TimeInterval
    let maximumDelay: TimeInterval
    let jitterMultiplierRange: ClosedRange<Double>
    let random: () -> Double

    func delay(afterAttempt attempt: Int, serverRetryAfter: TimeInterval?) -> TimeInterval {
        precondition(attempt >= 1, "attempt is 1-based: the first failure is attempt 1")
        let exponential = min(baseDelay * pow(2, Double(attempt - 1)), maximumDelay)
        var raw = exponential
        if let server = serverRetryAfter, server.isFinite, server > 0 {
            raw = max(raw, server) // capping (server demands included) is the FINAL clamp's job
        }
        // (No floor here: the final clamp below is the single floor/cap authority.)
        let unit = min(max(random(), 0), 1)
        let jittered = raw * (jitterMultiplierRange.lowerBound
            + unit * (jitterMultiplierRange.upperBound - jitterMultiplierRange.lowerBound))
        // THE floor/cap authority: every delay — exponential, server, jittered — passes here.
        return min(max(jittered, minimumDelay), maximumDelay)
    }

    /// Validating variant for callers that treat a bad attempt index as a caller bug worth
    /// surfacing instead of a precondition crash.
    func validatedDelay(afterAttempt attempt: Int, serverRetryAfter: TimeInterval?) throws -> TimeInterval {
        guard attempt >= 1 else {
            throw NSError(domain: "VoiceSharingRetryPolicy", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "attempt index must be >= 1"])
        }
        return delay(afterAttempt: attempt, serverRetryAfter: serverRetryAfter)
    }
}
