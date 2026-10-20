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
    /// OWNER DELTA 8fe04cd/0aa4480 (spec): foreground loss WITHOUT an active cloud/answer hold
    /// invalidates the window; WITH one, it PRESERVES it so a background answer can finish.
    ///
    /// This control is the SIGNAL unit seam: it drives the signal directly (no service, no gate,
    /// no engine). The production carriage — that the gate keeps capture open through the hold
    /// while the app is backgrounded — is a separate subject asserted elsewhere.
    @MainActor
    func testBackgroundingPreservesAWindowHeldByActiveWork() async throws {
        let signal = GracePeriodSignal()
        signal.onWakeWordDetected()
        let generation = signal.currentGeneration()
        // A cloud/answer turn admits: it holds this window's expiry open.
        let hold = signal.beginPlaybackHold(forGeneration: generation)
        XCTAssertNotNil(hold, "the live window accepts a hold")
        XCTAssertTrue(signal.isActive, "the window is open and held")

        // FOREGROUND LOSS while the hold is live: the window must SURVIVE.
        signal.onAppBackgrounded()
        XCTAssertTrue(
            signal.isActive,
            "backgrounding with an active cloud/answer hold must preserve the window"
        )

        // The held window still belongs to the turn that owns it.
        XCTAssertTrue(
            signal.recognizeCommandIfCurrentWindow(generation),
            "the same generation remains current after a hold-preserved backgrounding"
        )

        // Releasing the hold settles normally (no crash, window still live pre-timeout).
        signal.endPlaybackHold(hold)
        XCTAssertTrue(signal.isActive, "releasing the hold does not close the preserved window")
    }

    /// The SAME backgrounding event still invalidates when NO hold is live (fail closed).
    @MainActor
    func testBackgroundingWithoutAHoldStillInvalidatesTheWindow() async throws {
        let signal = GracePeriodSignal()
        signal.onWakeWordDetected()
        let generation = signal.currentGeneration()
        XCTAssertTrue(signal.isActive)

        signal.onAppBackgrounded()
        XCTAssertFalse(signal.isActive, "no active hold: backgrounding must end the window")
        XCTAssertNotEqual(
            signal.currentGeneration(), generation,
            "the retired generation must not remain current"
        )
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
