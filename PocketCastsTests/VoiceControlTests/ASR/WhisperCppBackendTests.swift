import XCTest
@testable import podcasts

final class WhisperCppBackendTests: XCTestCase {

    func test_capabilities_noRequireHardwareAccel() {
        let backend = WhisperCppBackend(modelPath: "/tmp/test")
        XCTAssertFalse(backend.capabilities.requiresHardwareAccel)
    }

    func test_capabilities_canTranslateToEnglish() {
        let backend = WhisperCppBackend(modelPath: "/tmp/test")
        XCTAssertTrue(backend.capabilities.canTranslateToEnglish)
    }

    func test_ensureReady_returnsSuccess() async {
        let backend = WhisperCppBackend(modelPath: "/tmp/test")
        let result = await backend.ensureReady()
        if case .success = result {
            // Expected stub behavior
        } else {
            XCTFail("Expected success")
        }
    }

    func test_requiredModel_id() {
        let backend = WhisperCppBackend(modelPath: "/tmp/test")
        XCTAssertEqual(backend.requiredModel.id, "whisper")
        XCTAssertEqual(backend.requiredModel.targetDir, "whisper-model")
    }
}
