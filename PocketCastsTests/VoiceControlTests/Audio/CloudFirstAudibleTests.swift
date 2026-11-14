import XCTest

@testable import podcasts

/// The cloud turn must report first AUDIBLE audio, measured on the client's own clock.
///
/// `cloud-assistant.md` (L33) requires it, and the latency work needs the same number from iOS and
/// Android. The value that used to stand in for it — the instant the first buffer was handed to the
/// output node — is scheduling, not audibility: `scheduleBuffer` only enqueues, and the node may
/// still be rendering audio queued before it, so that instant can precede what the user hears by an
/// arbitrary amount. These controls pin the first instant at which the output node has actually
/// rendered frames.
///
/// How they reach a real render: `CloudRouteSinkTests` already drives this player's REAL engine and
/// node in offline manual-rendering mode (`renderOffline`). These controls reuse exactly that hook
/// rather than inventing another one, so the node they assert against is the node production
/// schedules into.
final class CloudFirstAudibleTests: XCTestCase {
    /// A rendered position is what makes the mark exist, and the mark carries the instant the
    /// first RENDERED block began — not the instant the block was scheduled.
    ///
    /// Driven through the player's own observation (`observeFirstAudible`) rather than through an
    /// offline render: a manual-rendering node reports host time 0 with both validity flags false,
    /// so it can never produce a host instant and proving the arithmetic on it would prove nothing
    /// about a real output node. What is pinned here is the decision and the arithmetic; the node
    /// wiring that reaches this function is pinned below.
    func test_firstAudibleUsesTheRenderedInstantNotTheSchedulingInstant() {
        let player = CloudAudioPlayer()
        XCTAssertNil(player.firstAudibleHostSecondsForTesting,
                     "scheduling alone is not audibility: nothing has rendered yet")

        // The node rendered 4 096 frames and its `lastRenderTime` was 1.250 s; that block began
        // 4096/24000 s earlier. The mark must be the block's start, which is when the FIRST of
        // those frames became audible.
        let anchor = PlaybackRenderAnchor(renderedFrames: 4_096, sourceSampleRate: 24_000, hostTime: 1.250)
        let blockStart = anchor.hostTime - anchor.renderedFrames / anchor.sourceSampleRate
        player.observeFirstAudibleForTesting(atHostSeconds: blockStart)

        let mark = try? XCTUnwrap(player.firstAudibleHostSecondsForTesting)
        XCTAssertEqual(try XCTUnwrap(mark), 1.250 - 4_096.0 / 24_000.0, accuracy: 0.0001)
        XCTAssertGreaterThan(try XCTUnwrap(mark), 0.0, "the mark must be a real host instant")
        XCTAssertLessThan(try XCTUnwrap(mark), 1.250,
                          "the mark cannot be the render read; it must be the start of the first block")
    }

    /// The mark is the FIRST rendered instant of the turn and does not move: later renders and a
    /// mid-turn node rebuild (underrun) leave it alone. A mark that drifted to the latest instant
    /// would report a latency figure that improves the longer the answer plays.
    func test_firstAudibleIsTheFirstRenderedInstantOnly() {
        let player = CloudAudioPlayer()
        player.observeFirstAudibleForTesting(atHostSeconds: 2000)
        XCTAssertEqual(try XCTUnwrap(player.firstAudibleHostSecondsForTesting), 2000, accuracy: 0.0001)

        player.rearmSchedulingBoundaryForTesting()
        player.observeFirstAudibleForTesting(atHostSeconds: 4000)
        XCTAssertEqual(try XCTUnwrap(player.firstAudibleHostSecondsForTesting), 2000, accuracy: 0.0001,
                       "a mid-turn node rebuild must not re-mark first audio")
    }

    /// A new turn starts unmarked. Carrying the previous turn's instant would report a turn that
    /// played nothing as having played immediately.
    func test_aNewTurnStartsUnmarked() async {
        let player = CloudAudioPlayer()
        player.observeFirstAudibleForTesting(atHostSeconds: 5000)
        XCTAssertNotNil(player.firstAudibleHostSecondsForTesting)

        _ = player.finish()
        let rearmed = await waitFor(timeout: 3.0) { player.firstAudibleHostSecondsForTesting == nil }
        XCTAssertTrue(rearmed, "the next turn must start with no first-audible mark")
    }

    // MARK: - Harness

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
