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
}
