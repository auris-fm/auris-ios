import XCTest
@testable import podcasts

/// Controls for the `429 quota_exceeded` next-day retry floor (core spec `c74d7e30`):
/// the server meters ACTUAL accepted bytes per UTC day and names the quota in the body
/// (`code == "quota_exceeded"`). Both halves of the contract are pinned (cloud `dc264066` /
/// `7c65c7a4`):
///   (a) a day-scale hint consumes ONE attempt and lands after next UTC midnight;
///   (b) with NO hint, the quota code alone still schedules past next UTC midnight —
///       exponential backoff must not be the mechanism for a day-scale refusal.
final class VoiceSharingQuotaRetryFloorTests: XCTestCase {
    private func body(_ code: String?) -> Data {
        let object: [String: Any] = code == nil
            ? ["schema_version": 1]
            : ["schema_version": 1, "code": code!]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// 2026-11-04 23:30:00 UTC → next UTC midnight is 2026-11-05 00:00:00 (1800 s away).
    private let now = Date(timeIntervalSince1970: 1_793_835_000)

    func test_quotaCodeWithoutHintFloorsToNextUTCMidnight() {
        let effective = VoiceSharingUploader.effectiveRetryAfter(
            statusCode: 429, body: body("quota_exceeded"), hint: nil, now: now)
        XCTAssertEqual(effective, 1800, accuracy: 1)
    }

    func test_shortHintCannotOverruleTheQuotaFloor() {
        let effective = VoiceSharingUploader.effectiveRetryAfter(
            statusCode: 429, body: body("quota_exceeded"), hint: 30, now: now)
        XCTAssertEqual(effective, 1800, accuracy: 1)
    }

    func test_dayScaleHintIsPreservedNotShortened() {
        let effective = VoiceSharingUploader.effectiveRetryAfter(
            statusCode: 429, body: body("quota_exceeded"), hint: 90_000, now: now)
        XCTAssertEqual(effective, 90_000)
    }

    func test_nonQuota429KeepsExponentialBehavior() {
        XCTAssertNil(VoiceSharingUploader.effectiveRetryAfter(
            statusCode: 429, body: body("capture_conflict"), hint: nil, now: now))
        XCTAssertNil(VoiceSharingUploader.effectiveRetryAfter(
            statusCode: 429, body: body(nil), hint: nil, now: now))
    }

    func test_floorOnlyAppliesTo429() {
        // Same quota body under a non-429 status is NOT a quota refusal; no floor.
        XCTAssertNil(VoiceSharingUploader.effectiveRetryAfter(
            statusCode: 503, body: body("quota_exceeded"), hint: nil, now: now))
    }

    func test_midnightBoundaryComputesAcrossMonthEnd() {
        // 2026-11-30 23:00:00 UTC → 3600 s to 2026-12-01 00:00:00 UTC.
        let monthEnd = Date(timeIntervalSince1970: 1_796_079_600)
        let effective = VoiceSharingUploader.effectiveRetryAfter(
            statusCode: 429, body: body("quota_exceeded"), hint: nil, now: monthEnd)
        XCTAssertEqual(effective, 3600, accuracy: 1)
    }

    /// The composed value must actually be the floor the policy uses: a max-local-jitter
    /// draw (worst case 60 s) still schedules after next UTC midnight.
    func test_composedDelayLandsAfterMidnightEvenAtMaxJitter() {
        let floor = VoiceSharingUploader.effectiveRetryAfter(
            statusCode: 429, body: body("quota_exceeded"), hint: nil, now: now)!
        let policy = VoiceSharingRetryPolicy(
            retryBaseDelay: 2, retryMaximumDelay: 60, random: { 1.0 })
        let composed = policy.delay(afterAttempt: 1, serverRetryAfter: floor)
        XCTAssertGreaterThanOrEqual(composed, 1800 - 1)
    }
}
