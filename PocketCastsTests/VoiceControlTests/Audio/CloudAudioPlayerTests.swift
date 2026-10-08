import XCTest
@testable import podcasts

/// The player had no test at all, which is how a defect that made every cloud
/// answer silent survived review: `enqueue` cleared the flag the runner waits
/// on, so frames buffered forever and nothing played.
final class CloudAudioPlayerTests: XCTestCase {

    /// Frames handed to `enqueue` must be consumed by the runner once enough
    /// have accumulated to play, not buffered forever. Before the fix this
    /// looped until timeout: `enqueue` *cleared* the flag the runner waits on,
    /// so the wait was never satisfied and every turn was silent.
    ///
    /// The player deliberately buffers below its resume threshold, so the
    /// assertion is on the runner taking a playable batch, not on a single
    /// frame — and on the runner's work, since simulator audio hardware is not
    /// guaranteed here.
    func testEnqueuedFramesAreConsumedByTheRunner() async {
        let player = CloudAudioPlayer()
        for _ in 0..<8 {
            player.enqueue(CloudAudioFrame(data: Data(repeating: 0x11, count: 480)))
        }

        let consumed = await waitFor(timeout: 3.0) { player.bufferedFrameCountForTesting == 0 }
        XCTAssertTrue(consumed, "the runner must take a playable batch; buffered frames mean nothing plays")
    }

    /// The runner returns to its wait and is woken again for a later enqueue,
    /// rather than only for the first batch.
    func testRunnerWakesAgainForALaterBatch() async {
        let player = CloudAudioPlayer()
        for _ in 0..<8 {
            player.enqueue(CloudAudioFrame(data: Data(repeating: 0x22, count: 480)))
        }
        _ = await waitFor(timeout: 3.0) { player.bufferedFrameCountForTesting == 0 }

        for _ in 0..<8 {
            player.enqueue(CloudAudioFrame(data: Data(repeating: 0x44, count: 480)))
        }
        let secondDrained = await waitFor(timeout: 3.0) { player.bufferedFrameCountForTesting == 0 }
        XCTAssertTrue(secondDrained, "a later batch wakes the runner again")
    }

    /// `cancel()` empties the buffer and must not trap, even if the runner is
    /// mid-drain (the empty-dequeue case that crashed the app).
    func testCancelWhileDrainingDoesNotTrap() async {
        let player = CloudAudioPlayer()
        for _ in 0..<10 {
            player.enqueue(CloudAudioFrame(data: Data(repeating: 0x33, count: 480)))
        }
        player.cancel()
        // No crash is the assertion; give the runner time to act on the cancel.
        _ = await waitFor(timeout: 2.0) { player.bufferedFrameCountForTesting == 0 }
        XCTAssertEqual(player.bufferedFrameCountForTesting, 0, "a cancelled turn holds no frames")
    }

    /// A second turn must play. The player is built once for the app session,
    /// so a runner that returns at the first drain makes every later answer
    /// silent and never releases that turn's hold. This is the case the
    /// follow-up review caught after the wake fix.
    func testASecondTurnStillPlaysAfterTheFirstDrains() async {
        let player = CloudAudioPlayer()

        for _ in 0..<8 {
            player.enqueue(CloudAudioFrame(data: Data(repeating: 0x55, count: 480)))
        }
        player.finish() // ends turn one
        _ = await waitFor(timeout: 3.0) { player.bufferedFrameCountForTesting == 0 }

        for _ in 0..<8 {
            player.enqueue(CloudAudioFrame(data: Data(repeating: 0x66, count: 480)))
        }
        let secondTurnDrained = await waitFor(timeout: 3.0) { player.bufferedFrameCountForTesting == 0 }
        XCTAssertTrue(secondTurnDrained, "the runner must survive a finish() and serve the next turn")
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
