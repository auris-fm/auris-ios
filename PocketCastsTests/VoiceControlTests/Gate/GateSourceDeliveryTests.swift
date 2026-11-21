import XCTest
import AVFoundation
import Combine
@testable import podcasts

/// Every producer that feeds the gate chain must publish on the main thread, because
/// the chain's consumer is plain synchronous main-actor code. These controls post the
/// system notification from a background thread — exactly as the system does — and
/// observe the thread on which the resulting value is *emitted*, not merely its final
/// value. Without `.receive(on:)` at that source the emission happens on the posting
/// thread and the control fails.
@MainActor
final class GateSourceDeliveryTests: XCTestCase {

    /// Route monitor: `refreshRoute()` writes `micExposure`, which the gate reads.
    func test_routeMonitor_publishesMicExposureOnMain_whenNotificationPostedOffMain() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = [port(.builtInMic, uid: "built-in")]
        let monitor = IOSAudioRouteMonitor(gracePeriodSignal: GracePeriodSignal(),
                                          audioSession: session)

        let emitted = expectation(description: "micExposure emitted")
        let threads = ThreadRecord()
        // Skip the current value; observe the emission the notification causes.
        let subscription = monitor.$micExposure
            .dropFirst()
            .sink { _ in
                threads.record(Thread.isMainThread)
                emitted.fulfill()
            }

        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        await postOffMain(AVAudioSession.routeChangeNotification,
                          reason: .newDeviceAvailable)

        await fulfillment(of: [emitted], timeout: 5)
        subscription.cancel()
        XCTAssertTrue(threads.allOnMain,
                      "micExposure must be written on main; the route source needs the hop")
    }

    /// Casting: subscribes to the SAME route notification and feeds `$conflicts`.
    func test_castingSource_publishesOnMain_whenNotificationPostedOffMain() async {
        let source = CastingConditionSource()
        let emitted = expectation(description: "casting condition emitted")
        let threads = ThreadRecord()
        let subscription = source.publisher.sink { _ in
            threads.record(Thread.isMainThread)
            emitted.fulfill()
        }

        await postOffMain(AVAudioSession.routeChangeNotification,
                          reason: .categoryChange)

        await fulfillment(of: [emitted], timeout: 5)
        subscription.cancel()
        XCTAssertTrue(threads.allOnMain,
                      "the casting source feeds $conflicts and must publish on main")
    }

    /// Battery: forwards a power-state notification into `$conflicts`.
    func test_batterySource_publishesOnMain_whenNotificationPostedOffMain() async {
        let source = BatteryConditionSource()
        let emitted = expectation(description: "battery condition emitted")
        let threads = ThreadRecord()
        let subscription = source.publisher.sink { _ in
            threads.record(Thread.isMainThread)
            emitted.fulfill()
        }

        let posted = expectation(description: "power state posted off main")
        DispatchQueue.global(qos: .userInitiated).async {
            NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            posted.fulfill()
        }
        await fulfillment(of: [posted, emitted], timeout: 5)
        subscription.cancel()
        XCTAssertTrue(threads.allOnMain,
                      "the battery source feeds $conflicts and must publish on main")
    }

    /// Interruption: observe the `$isInterrupted` transition itself. Asserting only the
    /// final value would also pass when the write happens off-main and just the callback
    /// hops, which is the design this replaces.
    func test_interruption_publishesIsInterruptedOnMain_forBegan() async {
        let handler = AudioSessionInterruptionHandler()
        let emitted = expectation(description: "isInterrupted true emitted")
        let threads = ThreadRecord()
        let subscription = handler.$isInterrupted
            .filter { $0 }
            .sink { _ in
                threads.record(Thread.isMainThread)
                emitted.fulfill()
            }

        await postInterruptionOffMain(type: .began, options: nil)

        await fulfillment(of: [emitted], timeout: 5)
        subscription.cancel()
        XCTAssertTrue(threads.allOnMain,
                      "the isInterrupted write must happen on main, not just the callback")
    }

    func test_interruption_publishesIsInterruptedOnMain_forEndedWithResume() async {
        let handler = AudioSessionInterruptionHandler()
        handler.isInterrupted = true
        let emitted = expectation(description: "isInterrupted false emitted")
        let threads = ThreadRecord()
        let subscription = handler.$isInterrupted
            .filter { !$0 }
            .sink { _ in
                threads.record(Thread.isMainThread)
                emitted.fulfill()
            }

        await postInterruptionOffMain(type: .ended, options: .shouldResume)

        await fulfillment(of: [emitted], timeout: 5)
        subscription.cancel()
        XCTAssertTrue(threads.allOnMain,
                      "the isInterrupted clear must happen on main, not just the callback")
    }

    /// Ended without shouldResume clears the state but must NOT call back. Both the
    /// write's thread and the callback's silence are asserted.
    func test_interruption_endedWithoutResume_clearsStateOnMainAndStaysSilent() async {
        let handler = AudioSessionInterruptionHandler()
        handler.isInterrupted = true
        let notCalled = expectation(description: "onInterruptionEnded not called")
        notCalled.isInverted = true
        handler.onInterruptionEnded = { notCalled.fulfill() }

        let emitted = expectation(description: "isInterrupted false emitted")
        let threads = ThreadRecord()
        let subscription = handler.$isInterrupted
            .filter { !$0 }
            .sink { _ in
                threads.record(Thread.isMainThread)
                emitted.fulfill()
            }

        await postInterruptionOffMain(type: .ended, options: nil)

        await fulfillment(of: [emitted], timeout: 5)
        subscription.cancel()
        XCTAssertTrue(threads.allOnMain,
                      "ended without shouldResume still clears the state, and on main")
        await fulfillment(of: [notCalled], timeout: 1)
    }

    // MARK: - Helpers

    private func postOffMain(_ name: Notification.Name,
                             reason: AVAudioSession.RouteChangeReason) async {
        let posted = expectation(description: "route change posted off main")
        DispatchQueue.global(qos: .userInitiated).async {
            NotificationCenter.default.post(
                name: name,
                object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
            )
            posted.fulfill()
        }
        await fulfillment(of: [posted], timeout: 5)
    }

    private func postInterruptionOffMain(type: AVAudioSession.InterruptionType,
                                         options: AVAudioSession.InterruptionOptions?) async {
        let posted = expectation(description: "interruption posted off main")
        DispatchQueue.global(qos: .userInitiated).async {
            var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
            if let options {
                info[AVAudioSessionInterruptionOptionKey] = options.rawValue
            }
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: nil,
                userInfo: info
            )
            posted.fulfill()
        }
        await fulfillment(of: [posted], timeout: 5)
    }

    private func port(_ type: AVAudioSession.Port, uid: String) -> AudioPort {
        AudioPort(portType: type, uid: uid)
    }
}

/// Collects the thread each emission was observed on.
private final class ThreadRecord {
    private let lock = NSLock()
    private var values: [Bool] = []

    func record(_ onMain: Bool) {
        lock.lock()
        values.append(onMain)
        lock.unlock()
    }

    var allOnMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !values.isEmpty && values.allSatisfy { $0 }
    }
}
