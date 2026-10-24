import AVFoundation
import XCTest
@testable import podcasts

/// A physical reconnect must be able to re-arm **one** acquisition for a route the
/// service has already attempted and failed.
///
/// Observed on device (iPad, AirPods): at `09:50:06` the headset disconnected
/// (reason 4, `oldDeviceUnavailable`) → capture stopped, the session was restored to
/// `.playback`; at `09:53:41` it reconnected (reason 1, `newDeviceAvailable`) → the
/// route monitor re-read the route, but no acquisition followed, and the exposure
/// stayed `noMic`/`exposed` — the headset's HFP input was never re-selected, so
/// capture never came back.
///
/// The service re-enters `considerAcquisition` on every gate re-evaluation, so the
/// stop is downstream of it: `acquisitionAttemptedRoute` is the physical route
/// identity last attempted, and failure completions deliberately do **not** clear it
/// (that is what stops a failed route from being retried in a loop). The route
/// identity is `output + outputUID + input + inputUID`, and a reconnect that leaves
/// the session in `.playback` presents exactly the identity already attempted — A2DP
/// output, the same port UIDs, and `input: nil`, because an inactive `.playback`
/// session selects no input. So the dedup suppresses the retry and the headset is
/// never re-acquired.
///
/// The contract (spec 5d418579): **one attempt per received physical route-change
/// notification** is sufficient. Distinct notifications need not be inferred to be
/// one physical event, and the epoch counter cannot establish that — so it is
/// deliberately per-notification. What must never happen is a loop: repeated handling
/// of the *same* notification, unchanged/non-physical observations, and a failed
/// attempt's own completion/cleanup must all fail to re-arm. These cases pin both
/// halves.
final class ReconnectReacquisitionTests: XCTestCase {

    private func port(_ type: AVAudioSession.Port, uid: String) -> AudioPort {
        AudioPort(portType: type, uid: uid)
    }

    /// The `FakeAudioSessionControlling` models exactly the device sequence: the
    /// post-acquisition teardown restores `.playback`, and a `.playback` session
    /// reports **no** inputs and **no** `availableInputs` even though the headset is
    /// still connected, so the live route identity reverts to the type-level shape.
    private func makeService(
        _ session: FakeAudioSessionControlling,
        capture: NativeAudioCapture
    ) -> VoiceControlService {
        VoiceControlAssembly().buildVoiceControlService(audioSession: session, capture: capture)!
    }

    /// The defect: after a **failed** acquisition for a route, a physical reconnect
    /// that presents the same route identity must still re-arm one attempt.
    ///
    /// Without the fix the second `configureCount` never arrives and capture stays
    /// off for a headset that is connected and could be acquired.
    @MainActor
    func test_physicalReconnect_rearmAcquisition_forSameRouteIdentityAfterFailure() async {
        let session = FakeAudioSessionControlling()
        // Headset connected: external output, but the session is `.playback`, so no
        // input is selected and no candidate is discoverable.
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        // First attempt finds no external candidate → failure, and the identity is
        // remembered.
        session.availableAfterConfigure = []

        let service = makeService(session, capture: SucceedingCapture())
        service.startIfAllowed()

        await waitUntil(timeout: 5) { session.configureCount >= 1 }
        XCTAssertEqual(session.configureCount, 1, "the eligible route gets one acquisition attempt")
        XCTAssertNotEqual(service.micExposure, .isolated,
                          "the headset was not acquired, so capture must not be allowed yet")

        // The headset disconnects and reconnects: two physical device changes. The
        // second one presents the same route identity with the headset present and a
        // candidate now discoverable.
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true
        postRouteChange(reason: .oldDeviceUnavailable)
        postRouteChange(reason: .newDeviceAvailable)

        await waitUntil(timeout: 5) { session.configureCount >= 2 }
        XCTAssertEqual(session.configureCount, 2,
                       """
                       a physical reconnect left the same route identity already attempted and \
                       failed, so the retry was deduped out and the connected headset was never \
                       re-acquired: capture silently never returns
                       """)
        XCTAssertEqual(service.micExposure, .isolated,
                       "the reconnected headset's HFP input is re-selected and classification is Isolated")
        XCTAssertEqual(session.selectedUIDs, ["bt-mic"], "the reconnect re-selects the physical device")
    }

    /// The reviewer's finding, pinned: a **failed** attempt must not re-arm itself
    /// across its own completion/cleanup, and then a later physical route-change
    /// notification must grant **exactly one** more attempt.
    ///
    /// This is the case the old duplicate-notification control failed to exercise —
    /// it started from a successful acquisition, so it never touched failed-route
    /// dedup at all.
    @MainActor
    func test_failedAttempt_doesNotSelfRearm_thenOnePhysicalNotificationGrantsOneAttempt() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = []  // no candidate → the attempt fails

        let service = makeService(session, capture: SucceedingCapture())
        service.startIfAllowed()

        await waitUntil(timeout: 5) { session.configureCount >= 1 }
        XCTAssertEqual(session.configureCount, 1, "the eligible route gets one attempt")

        // Nothing further happens: completion and cleanup must not re-arm by
        // themselves, however long we wait.
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(session.configureCount, 1,
                       "a failed attempt must not re-arm across its own completion/cleanup")

        // One physical notification: exactly one more attempt, not more.
        postRouteChange(reason: .newDeviceAvailable)
        await waitUntil(timeout: 5) { session.configureCount >= 2 }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.configureCount, 2,
                       "a physical notification grants exactly one further attempt")
    }

    /// Each received physical route-change notification grants one attempt (spec
    /// 5d418579). This is deliberately per-notification: distinct notifications are
    /// not inferred to be one physical event, and the counter cannot establish that.
    @MainActor
    func test_eachPhysicalNotification_grantsOneAttempt() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = []  // fails each time

        let service = makeService(session, capture: SucceedingCapture())
        service.startIfAllowed()

        await waitUntil(timeout: 5) { session.configureCount >= 1 }
        XCTAssertEqual(session.configureCount, 1, "the eligible route gets one attempt")

        postRouteChange(reason: .newDeviceAvailable)
        await waitUntil(timeout: 5) { session.configureCount >= 2 }
        var settled = session.configureCount
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.configureCount, settled,
                       "the notification's attempt settles; it is not repeated")

        postRouteChange(reason: .newDeviceAvailable)
        await waitUntil(timeout: 5) { session.configureCount >= 3 }
        settled = session.configureCount
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.configureCount, 3,
                       "a second physical notification grants exactly one more attempt")
        XCTAssertEqual(session.configureCount, settled,
                       "and that attempt settles rather than looping")
    }

    /// Control: unchanged, repeated observations must **not** create an
    /// acquire→fail→release loop. Several non-physical route notifications with the
    /// same identity as the failed attempt must stay at exactly one attempt.
    @MainActor
    func test_repeatedUnchangedObservations_doNotReArmFailedRoute() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = []  // no candidate → fails

        let service = makeService(session, capture: SucceedingCapture())
        service.startIfAllowed()

        await waitUntil(timeout: 5) { session.configureCount >= 1 }
        XCTAssertEqual(session.configureCount, 1)

        // Repeated re-evaluations that are NOT physical device changes.
        for _ in 0..<5 {
            postRouteChange(reason: .categoryChange)
        }
        postRouteChange(reason: .routeConfigurationChange)
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(session.configureCount, 1,
                       "an unchanged repeated observation must not retry a route that already failed")
    }

    /// Control: two physical changes in a row for the **same** still-unacquirable
    /// route must attempt at most once per physical change — never a loop, and never
    /// zero. Together with the case above this pins "re-arm once per physical change".
    @MainActor
    func test_physicalChange_withoutCandidate_attemptsOnRequestButNotInALoop() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = []  // still no candidate

        let service = makeService(session, capture: SucceedingCapture())
        service.startIfAllowed()

        await waitUntil(timeout: 5) { session.configureCount >= 1 }

        postRouteChange(reason: .newDeviceAvailable)
        try? await Task.sleep(for: .milliseconds(150))
        let afterFirstChange = session.configureCount
        XCTAssertEqual(afterFirstChange, 2, "one physical notification grants one fresh attempt")

        // Nothing further changes: settle must stop at that attempt.
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.configureCount, afterFirstChange,
                       "with no further physical notification, the fresh attempt is not repeated")
    }

    /// The re-arm must not weaken the failed-capture-start suppression when nothing
    /// physical happened: a capture that failed to start keeps its suppression through
    /// non-physical route notifications.
    @MainActor
    func test_captureStartFailure_suppressionHoldsAcrossNonPhysicalRouting() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true
        session.inputsOnClear = [port(.builtInMic, uid: "built-in")]

        let service = makeService(session, capture: FailingCapture())
        service.startIfAllowed()

        await waitUntil(timeout: 5) { session.clearCount >= 1 }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.configureCount, 1, "the failed device is not retried")

        postRouteChange(reason: .categoryChange)
        postRouteChange(reason: .routeConfigurationChange)
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(service.isListening, "a failed capture start must not report listening")
        XCTAssertEqual(session.configureCount, 1,
                       "non-physical routing must not re-arm a capture-start failure for the same device")
    }

    /// A physical reconnect must also clear a failed-capture-start suppression: after the
    /// headset disconnects and reconnects, the device is genuinely re-presented, so
    /// acquisition for it is allowed again.
    @MainActor
    func test_physicalReconnect_clearsCaptureStartFailureSuppression() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-A-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "mic-A")]
        session.selectionTakesEffect = true
        session.inputsOnClear = [port(.builtInMic, uid: "built-in")]

        let service = makeService(session, capture: FailingCapture())
        service.startIfAllowed()

        await waitUntil(timeout: 5) { session.clearCount >= 1 }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.configureCount, 1, "the failed device is not retried while unchanged")

        // The same headset physically disconnects and reconnects.
        postRouteChange(reason: .oldDeviceUnavailable)
        postRouteChange(reason: .newDeviceAvailable)

        await waitUntil(timeout: 5) { session.configureCount >= 2 }
        XCTAssertEqual(session.configureCount, 2,
                       "a genuine physical reconnect re-presents the device and must re-arm acquisition for it")
    }

    private func postRouteChange(reason: AVAudioSession.RouteChangeReason) {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
        )
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}