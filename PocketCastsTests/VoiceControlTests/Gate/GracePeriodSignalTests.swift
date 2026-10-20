import Combine
import XCTest
@testable import podcasts

final class GracePeriodSignalTests: XCTestCase {

    func test_gracePeriodSignal_startsInactive() {
        let signal = GracePeriodSignal()
        XCTAssertFalse(signal.isActive)
    }

    func test_gracePeriodSignal_commandRecognized_setsActive() {
        let signal = GracePeriodSignal()
        signal.onCommandRecognized()
        XCTAssertTrue(signal.isActive)
    }

    func test_gracePeriodSignal_wakeWordDetected_setsActive() {
        let signal = GracePeriodSignal()
        signal.onWakeWordDetected()
        XCTAssertTrue(signal.isActive)
    }

    func test_gracePeriodSignal_routeChange_breaksGracePeriod() {
        let signal = GracePeriodSignal()
        signal.onCommandRecognized()
        XCTAssertTrue(signal.isActive)
        signal.onAudioRouteChanged()
        XCTAssertFalse(signal.isActive)
    }

    func test_gracePeriodSignal_appBackgrounded_breaksGracePeriod() {
        let signal = GracePeriodSignal()
        signal.onCommandRecognized()
        XCTAssertTrue(signal.isActive)
        signal.onAppBackgrounded()
        XCTAssertFalse(signal.isActive)
    }

    func test_gracePeriodSignal_secondCommand_resetsTimer() {
        let signal = GracePeriodSignal()
        signal.onCommandRecognized()
        signal.onCommandRecognized()
        XCTAssertTrue(signal.isActive)
    }

    func test_gracePeriodSignal_wakeWordResetsTimer() {
        let signal = GracePeriodSignal()
        signal.onWakeWordDetected()
        signal.onWakeWordDetected()
        XCTAssertTrue(signal.isActive)
    }

    func test_gracePeriodSignal_expiresAfterTimeout() {
        let signal = GracePeriodSignal(timeout: 0.05)
        let expired = expectation(description: "grace expired")
        var cancellable: AnyCancellable?
        cancellable = signal.$isActive
            .dropFirst()
            .sink { active in
                if !active { expired.fulfill() }
            }

        // Simulate the production path: wake callback off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            signal.onWakeWordDetected()
        }

        wait(for: [expired], timeout: 2.0)
        XCTAssertFalse(signal.isActive)
        cancellable?.cancel()
    }

    /// RETIREMENT AT THE SIGNAL: a generation that a privacy close RETIRED must be REFUSED by
    /// `recognizeCommandIfCurrentWindow`, so a caller holding a stale generation cannot reset the
    /// allowance while a successor window is live.
    ///
    /// SCOPE, stated so it is not mistaken for more: this is a GracePeriodSignal UNIT control. It
    /// calls `recognizeCommandIfCurrentWindow` directly and constructs NO service, NO engine callback,
    /// and NO `CloudRouteIntent` — so it shows the SIGNAL refuses a retired generation, not that any
    /// installed path passes the right generation to it. That carriage is a separate subject.
    /// OWNER DELTA 8fe04cd/0aa4480, CORRECTED (spec 3893cd55 / reviewer 724db1e8): a hold alone
    /// does NOT preserve the window through foreground loss — preservation requires an
    /// INDEPENDENT playback context (an eligible episode). Grace must not self-sustain.
    @MainActor
    func testForegroundLossWithRealPlaybackContextPreservesTheWindow() async throws {
        let signal = GracePeriodSignal()
        let episodeLoaded = { true }
        signal.playbackContextAvailable = episodeLoaded
        signal.onWakeWordDetected()
        let generation = signal.currentGeneration()
        _ = signal.beginPlaybackHold(forGeneration: generation)

        signal.onAppBackgrounded()
        XCTAssertTrue(signal.isActive, "backgrounding with a real playback context preserves the window")
        XCTAssertTrue(signal.recognizeCommandIfCurrentWindow(generation), "the generation is still current")

        // LOSING the last genuine context: clear the episode, then background. Fails closed.
        signal.playbackContextAvailable = { false }
        signal.onAppBackgrounded()
        XCTAssertFalse(signal.isActive, "backgrounding with NO real context ends the window")
        XCTAssertNotEqual(signal.currentGeneration(), generation, "the ended window's generation is retired")
    }

    /// A hold with NO independent playback context: backgrounding still ends the window
    /// (grace-as-context defect). The turn's own completion is judged on its retired generation.
    @MainActor
    func testForegroundLossWithOnlyAHoldEndsTheWindow() async throws {
        let signal = GracePeriodSignal()
        signal.playbackContextAvailable = { false }
        signal.onWakeWordDetected()
        let generation = signal.currentGeneration()
        let hold = signal.beginPlaybackHold(forGeneration: generation)
        XCTAssertNotNil(hold, "the live window accepts a hold")

        signal.onAppBackgrounded()
        XCTAssertFalse(signal.isActive, "a hold alone must not preserve the window")
        XCTAssertFalse(
            signal.recognizeCommandIfCurrentWindow(generation),
            "a completion under the retired generation is not applied to anything"
        )
    }

    /// No hold at all: backgrounding ends the window (fail closed, unchanged).
    @MainActor
    func testBackgroundingWithoutAHoldStillInvalidatesTheWindow() async throws {
        let signal = GracePeriodSignal()
        signal.playbackContextAvailable = { false }
        signal.onWakeWordDetected()
        let generation = signal.currentGeneration()
        XCTAssertTrue(signal.isActive)

        signal.onAppBackgrounded()
        XCTAssertFalse(signal.isActive, "no context: backgrounding must end the window")
        XCTAssertNotEqual(signal.currentGeneration(), generation)
    }

    @MainActor
    func testAGenerationRetiredByAPrivacyCloseIsRefused() async throws {
        let signal = GracePeriodSignal()

        // A window opens and a turn stamps its generation.
        signal.onWakeWordDetected()
        let stamped = signal.currentGeneration()
        XCTAssertTrue(signal.isActive, "the window must be open when the turn stamps it")

        // PRIVACY CLOSE: backgrounding retires everything stamped under that window.
        signal.onAppBackgrounded()
        XCTAssertFalse(signal.isActive, "backgrounding must end the window")
        let afterRetirement = signal.currentGeneration()
        XCTAssertNotEqual(
            stamped, afterRetirement,
            "a privacy close must retire the generation, or the refusal below could not tell them apart"
        )

        // A NEW window is OPEN when the stale callback arrives. This is what isolates the generation
        // check: with the signal ACTIVE, `isActive` alone cannot refuse, so a refusal can only come
        // from the generation equality. (Refusing while INACTIVE would pass for the wrong reason —
        // verified: dropping the generation check still refused, because isActive was false.)
        signal.onWakeWordDetected()
        let live = signal.currentGeneration()
        XCTAssertTrue(signal.isActive, "the new window must be OPEN so isActive cannot be the refuser")
        XCTAssertNotEqual(stamped, live, "the new window's generation must differ from the retired one")

        // THE ASSERTIONS: the retired generation is refused WHILE a window is live; the live one is
        // accepted. Both directions, or the refusal would pass even if the gate refused everything.
        XCTAssertFalse(
            signal.recognizeCommandIfCurrentWindow(stamped),
            "a turn stamped before the privacy close must not reset the ACTIVE successor's allowance"
        )
        XCTAssertTrue(
            signal.recognizeCommandIfCurrentWindow(live),
            "positive control: the LIVE generation must be accepted, or refusal proves nothing"
        )
    }
}
