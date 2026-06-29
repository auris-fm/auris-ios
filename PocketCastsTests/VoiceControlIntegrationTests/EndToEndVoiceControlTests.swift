import XCTest
@testable import podcasts

final class EndToEndVoiceControlTests: XCTestCase {

    func test_service_buildsWithoutCrash() {
        let assembly = VoiceControlAssembly()
        let service = assembly.buildVoiceControlService()
        XCTAssertNotNil(service)
    }

    func test_service_initialState_notListening() {
        let assembly = VoiceControlAssembly()
        let service = assembly.buildVoiceControlService()
        XCTAssertFalse(service.isListening)
    }

    func test_service_initialMode_wakeWord() {
        let assembly = VoiceControlAssembly()
        let service = assembly.buildVoiceControlService()
        XCTAssertEqual(service.listeningMode, .wakeWord)
    }

    func test_ambientSpeech_triggersNoCrash() async {
        let assembly = VoiceControlAssembly()
        let service = assembly.buildVoiceControlService()
        // Ambient speech should not crash, even if no intent is found
        await service.handleTranscript("what a beautiful day")
    }

    func test_executor_pauseIntent_builtFromAssembly() async {
        let assembly = VoiceControlAssembly()
        let service = assembly.buildVoiceControlService()
        // Verifying the full chain doesn't crash
        await service.handleTranscript("pause")
    }
}
