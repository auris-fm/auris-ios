import XCTest
import AVFoundation
import Combine
@testable import podcasts

/// The listening cue marks the opening of a session the user started. A capture that resumes on
/// its own — another app released audio, a route change, a pipeline restart — is the same session
/// continuing, so it must stay silent. Continuous listening never cues at all.
///
/// These controls assert the cue count, not a state flag. The behaviour under test is how many
/// times a sound reaches the user, and a state assertion passes whether the cue played once or
/// twice, so it cannot fail for the reason this is testing.
final class ListeningCueRepetitionTests: XCTestCase {

    /// Starts the service, lets the gate admit capture, then closes and reopens the gate. The
    /// reopen is the automatic resume: nothing the user did caused it, they are still in the
    /// session they started.
    func test_anAutomaticResumeDoesNotCueAgain() throws {
        let (service, monitor) = try Self.armedService()
        var cues: [EarconId] = []
        service.earconObserverForTesting = { cues.append($0) }
        // Arm only after the observer is installed: the opening cue is one of the counts under
        // test, so it cannot be missed between arming and observing.
        service.startIfAllowed()

        // Open: the user-started session begins, so exactly one cue is correct here.
        monitor.context = .appInForeground
        try Self.waitFor { service.isListening }
        XCTAssertEqual(cues.filter { $0 == .listeningStart }.count, 1,
                       "a user-started session opens with one cue")

        // Close and reopen the gate with no user action in between.
        monitor.context = .none
        try Self.waitFor { !service.isListening }
        monitor.context = .appInForeground
        try Self.waitFor { service.isListening }

        XCTAssertEqual(cues.filter { $0 == .listeningStart }.count, 1,
                       "an automatic resume continues the session; it must not cue again")
    }

    /// The cue fires once across several interruptions, not once per interruption.
    func test_repeatedInterruptionsStillCueOnce() throws {
        let (service, monitor) = try Self.armedService()
        var cues: [EarconId] = []
        service.earconObserverForTesting = { cues.append($0) }
        // Arm only after the observer is installed: the opening cue is one of the counts under
        // test, so it cannot be missed between arming and observing.
        service.startIfAllowed()

        monitor.context = .appInForeground
        try Self.waitFor { service.isListening }

        for _ in 0..<3 {
            monitor.context = .none
            try Self.waitFor { !service.isListening }
            monitor.context = .appInForeground
            try Self.waitFor { service.isListening }
        }

        XCTAssertEqual(cues.filter { $0 == .listeningStart }.count, 1,
                       "three interruptions are still one session")
    }

    /// The real audio-session interruption callback, not a simulated gate change. The system taking
    /// audio away stops capture without the user ending anything, so the resume that follows is the
    /// same session and stays silent. This drives the notification the app actually receives,
    /// because the gate-change controls above take a different path into stop().
    func test_aSystemInterruptionDoesNotCueAgainOnResume() throws {
        let (service, monitor) = try Self.armedService()
        var cues: [EarconId] = []
        service.earconObserverForTesting = { cues.append($0) }
        service.startIfAllowed()

        monitor.context = .appInForeground
        try Self.waitFor { service.isListening }
        XCTAssertEqual(cues.filter { $0 == .listeningStart }.count, 1,
                       "the session opens with one cue")

        Self.postInterruption(.began)
        try Self.waitFor { !service.isListening }

        Self.postInterruption(.ended, shouldResume: true)
        try Self.waitFor { service.isListening }

        XCTAssertEqual(cues.filter { $0 == .listeningStart }.count, 1,
                       "an interruption the user did not cause keeps the session open")
    }

    /// A session that opens while grace is active has no cue — continuous never sounds — but the
    /// opportunity is spent. When grace ends and capture restarts in wake-word mode, that restart
    /// must not play the cue late.
    ///
    /// The gate admits as soon as it is armed in this harness, so the session is opened by disabling
    /// voice control first: that ends any session, and the re-enable below is the moment that opens
    /// a new one — with grace already active.
    func test_aSessionOpenedDuringGraceDoesNotCueLaterWhenGraceEnds() throws {
        let (service, monitor) = try Self.armedService()
        var cues: [EarconId] = []
        service.earconObserverForTesting = { cues.append($0) }
        service.startIfAllowed()

        // End the automatic session so the next open is one this control causes.
        monitor.updateUserEnabled(false)
        try Self.waitFor { !service.isListening }
        cues.removeAll()

        // Open a new session with grace already active, so it resolves to continuous.
        service.gracePeriodSignalForTesting.onCommandRecognized()
        monitor.updateUserEnabled(true)
        try Self.waitFor { service.isListening }
        try Self.waitFor { service.gateState.listeningMode == .continuous }
        XCTAssertEqual(cues.filter { $0 == .listeningStart }.count, 0,
                       "a session opened during grace never sounds the cue")

        // Grace expires and capture is interrupted, then comes back in wake-word mode. Without a
        // real stop-and-restart the mode label changes but start() never runs again, and the control
        // would pass whatever the cue logic does. The interruption is a conflict, which blocks the
        // gate regardless of context.
        service.gracePeriodSignalForTesting.deactivateForTesting(trigger: "timeout")
        try Self.waitFor { service.gateState.listeningMode == .wakeWord }
        monitor.conflicts = GateConflicts(
            notOnCall: .blocked(reason: "call_in_progress"),
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        try Self.waitFor { !service.isListening }
        monitor.conflicts = .noneBlocked
        try Self.waitFor { service.isListening }
        try Self.waitFor { service.gateState.listeningMode == .wakeWord }

        XCTAssertEqual(cues.filter { $0 == .listeningStart }.count, 0,
                       "a session that opened during grace already had its cue spent")
    }

    /// Turning voice control off ends the session just as an explicit stop does, so turning it back
    /// on is a user start and cues again. Without that, a deliberate off/on would be silent and the
    /// user would have no confirmation their session opened.
    func test_turningVoiceControlBackOnCuesAgain() throws {
        let (service, monitor) = try Self.armedService()
        var cues: [EarconId] = []
        service.earconObserverForTesting = { cues.append($0) }
        service.startIfAllowed()

        // Enable: a user start, so one cue.
        monitor.updateUserEnabled(true)
        monitor.context = .appInForeground
        try Self.waitFor { service.isListening }
        XCTAssertEqual(cues.filter { $0 == .listeningStart }.count, 1,
                       "turning voice control on opens a session")

        // Disable: the user ended the session.
        monitor.updateUserEnabled(false)
        try Self.waitFor { !service.isListening }

        // Enable again: this is a new user-started session, so a second cue.
        monitor.updateUserEnabled(true)
        try Self.waitFor { service.isListening }
        XCTAssertEqual(cues.filter { $0 == .listeningStart }.count, 2,
                       "turning voice control off and on again is a user start")

        // An automatic resume after that must still be silent.
        monitor.conflicts = GateConflicts(
            notOnCall: .blocked(reason: "call_in_progress"),
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        try Self.waitFor { !service.isListening }
        monitor.conflicts = .noneBlocked
        try Self.waitFor { service.isListening }
        XCTAssertEqual(cues.filter { $0 == .listeningStart }.count, 2,
                       "an automatic resume after a re-enable is still the same session")
    }

    /// Continuous listening — the grace period after a command — never cues, whatever the
    /// interruption history.
    ///
    /// This clause already held before the session flag: the cue was gated on wake-word mode, and a
    /// resume inside a grace window resolves to continuous, so it stayed silent on its own. The
    /// control is kept as the regression guard for that, not as evidence for the resume fix — it
    /// passes with the flag removed, which the other two controls do not.
    func test_continuousListeningNeverCues() throws {
        let (service, monitor) = try Self.armedService()
        var cues: [EarconId] = []
        service.earconObserverForTesting = { cues.append($0) }
        // Arm only after the observer is installed: the opening cue is one of the counts under
        // test, so it cannot be missed between arming and observing.
        service.startIfAllowed()

        // Open the session in wake-word mode. This cue is correct: the user started it.
        monitor.context = .appInForeground
        try Self.waitFor { service.isListening }
        XCTAssertEqual(cues.filter { $0 == .listeningStart }.count, 1,
                       "the user-started session opens with one cue")

        // A committed command opens the grace window, inside which the gate resolves the mode to
        // continuous rather than wake word.
        service.gracePeriodSignalForTesting.onCommandRecognized()
        try Self.waitFor { service.gateState.listeningMode == .continuous }
        let afterOpeningCue = cues.filter { $0 == .listeningStart }.count

        // Interrupt and resume inside the continuous window. Foreground loss alone will not stop
        // capture while a window is open, so the interruption is a conflict: it blocks the gate
        // regardless of context, and clearing it re-admits capture. A continuous capture never
        // cues, so the count must not move.
        monitor.conflicts = GateConflicts(
            notOnCall: .blocked(reason: "call_in_progress"),
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        try Self.waitFor { !service.isListening }
        monitor.conflicts = GateConflicts(
            notOnCall: .allowed,
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        try Self.waitFor { service.isListening }

        XCTAssertEqual(cues.filter { $0 == .listeningStart }.count, afterOpeningCue,
                       "continuous listening never cues, including when it resumes")
    }

    // MARK: - Harness

    /// A service whose gate admits capture and whose other conditions are all allowed, so the
    /// only thing that moves the gate is the foreground context this suite drives.
    private static func armedService() throws -> (VoiceControlService, LiveConditionMonitor) {
        let gracePeriodSignal = GracePeriodSignal()
        let monitor = LiveConditionMonitor(gracePeriodSignal: gracePeriodSignal)
        let assembly = VoiceControlAssembly()
        let service = try XCTUnwrap(
            assembly.buildVoiceControlService(conditionMonitor: monitor),
            "the assembly must build a service"
        )
        // A simulator has no headset, so the live route classifies as `.exposed` and the gate
        // refuses capture before the resume logic is ever reached. Pin it to the isolated state a
        // real headset produces, which is the only exposure the gate admits.
        service.routeMonitorForTesting.micExposure = MicExposure.isolated
        return (service, monitor)
    }

    /// Posts the interruption notification the app subscribes to, so the control exercises the real
    /// handler rather than a stand-in for it.
    private static func postInterruption(
        _ type: AVAudioSession.InterruptionType,
        shouldResume: Bool = false
    ) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if type == .ended {
            info[AVAudioSessionInterruptionOptionKey] =
                shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0
        }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: info
        )
    }

    /// Polls with a bounded budget. The gate is Combine-driven, so a state change lands on a
    /// later runloop turn; a fixed sleep would be both slow and flaky, and an unbounded wait
    /// would hang the suite instead of failing it.
    private static func waitFor(
        timeout: TimeInterval = 3,
        _ condition: @escaping () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        // A hard failure, not a skip: an unmet precondition means the control did not exercise
        // what it claims, and a skip would report green while proving nothing.
        throw NSError(
            domain: "ListeningCueRepetitionTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "condition not met within \(timeout)s"]
        )
    }
}
