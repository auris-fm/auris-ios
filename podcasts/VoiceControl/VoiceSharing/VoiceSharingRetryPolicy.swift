import Foundation

/// Pure retry/backoff scheduling for the downstream uploader (spec "Client queue and
/// scheduling"). The upload QUEUE deliberately stays free of network policy; this type is the
/// decision the uploader will call between attempts, kept independent so it can be pinned by
/// controls before it is wired.
///
/// Contract (spec-required full jitter, reviewer 97f76aa9):
///   * Local component: FULL JITTER — uniform sample from 0 to
///     `min(retryMaximumDelay, retryBaseDelay * 2^(attempt-1))`, `attempt` 1-based. There is no
///     positive floor: the distribution starts at zero.
///   * A valid server `Retry-After` (finite, > 0) is a MINIMUM delay: it is never jittered
///     downward and never truncated by local bounds — `max(jitteredLocal, retryAfter)`. If a
///     server demand outlasts queue age or execution constraints, deferral/termination is the
///     CALLER's decision through its existing bounds; shortening the demand here would retry too
///     early. Invalid values (zero, negative, NaN, infinite) are treated as absent — a malformed
///     header must not manufacture an immediate retry.
///   * Numeric values are compiled bounds, NOT owner-approved activation values.
struct VoiceSharingRetryPolicy {
    /// `retry_initial_s` (spec). Base of the exponential ceiling growth.
    let retryBaseDelay: TimeInterval
    /// `retry_max_s` (spec). Ceiling of the local jittered component only — never applied to a
    /// server `Retry-After`.
    let retryMaximumDelay: TimeInterval
    /// Random source in [0, 1]; injected so controls are deterministic.
    let random: () -> Double

    func delay(afterAttempt attempt: Int, serverRetryAfter: TimeInterval?) -> TimeInterval {
        precondition(attempt >= 1, "attempt is 1-based: the first failure is attempt 1")
        let exponentialCeiling = retryBaseDelay * pow(2, Double(attempt - 1))
        let ceiling = min(retryMaximumDelay, exponentialCeiling)
        // Full jitter: uniform in [0, ceiling].
        let unit = min(max(random(), 0), 1)
        var delay = ceiling * unit
        if let server = serverRetryAfter, server.isFinite, server > 0 {
            delay = max(delay, server)
        }
        return delay
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
