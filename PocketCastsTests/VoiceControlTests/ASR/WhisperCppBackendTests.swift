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

    /// `ensureReady` for a model path that does not exist must report a failure.
    ///
    /// This test previously asserted success, which was only ever true of a build
    /// without whisper linked (the `#else` stub branch) — with whisper linked the
    /// linked path has always failed for a missing model. It also attempted a
    /// real model download, making a unit test network-dependent. The contract
    /// asserted here is the one the shipped configuration has.
    func test_ensureReady_missingModelPathFails() async {
        let backend = WhisperCppBackend(modelPath: "/tmp/auris-does-not-exist-\(UUID().uuidString)")
        let result = await backend.ensureReady()
        switch result {
        case .success:
            XCTFail("a missing model path must not report success")
        case .failure:
            break // the contract: fail, visibly, rather than pretend to be ready
        }
    }

    func test_requiredModel_id() {
        let backend = WhisperCppBackend(modelPath: "/tmp/test")
        XCTAssertEqual(backend.requiredModel.id, "whisper")
        XCTAssertEqual(backend.requiredModel.targetDir, "whisper-model")
    }
}
