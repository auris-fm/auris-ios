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
        // A path that cannot exist and cannot be created: `ensureReady`
        // downloads when the model file is absent, and `ModelDownloader` writes
        // into the path's *parent*, so a path in `/tmp` would fetch the real
        // model (~190 MB) and take seconds to do it — the network dependency
        // this test is supposed to have shed. Under `/dev/null` there is
        // nowhere to write, so the failure is immediate and local.
        let backend = WhisperCppBackend(modelPath: "/dev/null/auris-missing-\(UUID().uuidString)/model.bin")
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
