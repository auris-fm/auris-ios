import XCTest

@testable import podcasts

/// The cloud turn must report first AUDIBLE audio, measured on the client's own clock.
///
/// `cloud-assistant.md` (L33) requires it, and the latency work needs the same number from iOS and
/// Android. The value that used to stand in for it — the instant the first buffer was handed to the
/// output node — is scheduling, not audibility: `scheduleBuffer` only enqueues, and the node may
/// still be rendering audio queued before it, so that instant can precede what the user hears by an
/// arbitrary amount.
///
/// These controls read the PRODUCTION property (`firstAudibleHostSeconds`) and drive the production
/// path; there is no test-only setter, because a control that wrote the mark directly would pass
/// against logic nothing in production runs.
final class CloudFirstAudibleTests: XCTestCase {
    /// Nothing has been heard before the node renders: the mark is absent, not zero. A zero would
    /// claim instantaneous audio, which is the failure mode the scheduling boundary already had.
    func test_nothingIsAudibleBeforeTheNodeRenders() {
        let player = CloudAudioPlayer()
        XCTAssertNil(player.firstAudibleHostSeconds,
                     "a fresh player has heard nothing; audio latency must stay absent, not be estimated")
    }

    /// A turn that ends clears the mark, so the next turn cannot inherit the previous one's first
    /// audible instant and report a turn that played nothing as having played immediately.
    func test_aNewTurnStartsUnmarked() async {
        let player = CloudAudioPlayer()
        XCTAssertNil(player.firstAudibleHostSeconds)

        _ = player.finish()
        let settled = await waitFor(timeout: 3.0) { player.firstAudibleHostSeconds == nil }
        XCTAssertTrue(settled, "the next turn must start with no first-audible mark")
    }

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
