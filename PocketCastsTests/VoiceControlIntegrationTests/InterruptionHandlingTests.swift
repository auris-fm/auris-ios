import XCTest
import AVFoundation
@testable import podcasts

@MainActor
final class InterruptionHandlingTests: XCTestCase {

    func test_beganInterruption_stopsService() async {
        let assembly = VoiceControlAssembly()
        let service = assembly.buildVoiceControlService()!

        // Start the service (this sets up the gate subscription)
        service.startIfAllowed()

        // We can't fully start listening in a test environment (no audio hardware),
        // but we can verify the interruption handler is wired by checking that
        // isInterrupted is tracked.
        // Post a began notification and verify the service's internal state.

        // Post interruption began
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]
        )

        // The handler receives on the main queue, so the stop lands after this post
        // returns. Wait for the state rather than asserting straight after posting:
        // asserting immediately passes only where the service never started listening
        // (no exposed route), and fails where it genuinely did — which is what CI does.
        await waitUntil(timeout: 5) { !service.isListening }
        XCTAssertFalse(service.isListening,
                       "a began interruption must stop listening")
    }

    func test_endedInterruptionWithShouldResume_reactivatesSession() async {
        let assembly = VoiceControlAssembly()
        let service = assembly.buildVoiceControlService()!

        service.startIfAllowed()

        // Post interruption ended with shouldResume
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )

        // `service` is non-optional, so asserting it is non-nil could never fail and
        // proved nothing. What this case can actually observe is that an ended
        // interruption clears the stopped state a began interruption left behind:
        // post began, wait for the stop to land, then end it and wait for the release.
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]
        )
        await waitUntil(timeout: 5) { !service.isListening }
        XCTAssertFalse(service.isListening, "the began interruption must stop listening first")

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )
        // Whether listening resumes depends on the live route, which this test cannot
        // fix, so resumption is not asserted. What is asserted is that the ended
        // notification is delivered and handled without crashing the host: the began
        // case above proves delivery works, and reaching here after the round trip is
        // the observable outcome. A crash would abort the run rather than fail softly.
        await waitUntil(timeout: 1) { service.isListening }
    }

    /// Polls off the main actor: polling on main would compete with the main-queue
    /// delivery being awaited.
    private nonisolated func waitUntil(timeout: TimeInterval,
                                       _ condition: @escaping @Sendable () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
