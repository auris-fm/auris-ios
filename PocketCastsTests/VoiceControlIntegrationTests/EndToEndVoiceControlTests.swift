import XCTest
@testable import podcasts

/// MAIN ACTOR (crash evidence t78k-3 DiagnosticReport): production builds the service on the
/// main thread, and `wireLiveOriginBinding`'s inline retirement sink asserts main isolation.
/// Building the service off-main in a test crashes on `MainActor.assumeIsolated` — that is a
/// test-fidelity bug, not a production one, so the suite runs on the main actor.
@MainActor
final class EndToEndVoiceControlTests: XCTestCase {

    func test_service_buildsWithoutCrash() {
        let assembly = VoiceControlAssembly()
        let service = assembly.buildVoiceControlService()
        XCTAssertNotNil(service)
    }

    func test_service_initialState_notListening() {
        let assembly = VoiceControlAssembly()
        let service = assembly.buildVoiceControlService()!
        XCTAssertFalse(service.isListening)
    }

    func test_service_initialMode_wakeWord() {
        let assembly = VoiceControlAssembly()
        let service = assembly.buildVoiceControlService()!
        XCTAssertEqual(service.listeningMode, .wakeWord)
    }

    func test_ambientSpeech_triggersNoCrash() async {
        let assembly = VoiceControlAssembly()
        let service = assembly.buildVoiceControlService()!
        // Ambient speech should not crash, even if no intent is found
        await service.handleTranscript("what a beautiful day", utteranceId: "u-300")
    }

    func test_executor_pauseIntent_builtFromAssembly() async {
        let assembly = VoiceControlAssembly()
        let service = assembly.buildVoiceControlService()!
        // Verifying the full chain doesn't crash
        await service.handleTranscript("pause", utteranceId: "u-300")
    }
}
