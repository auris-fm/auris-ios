import XCTest
@testable import podcasts

final class ModelDownloaderTests: XCTestCase {

    func test_downloader_initializes() {
        let downloader = ModelDownloader()
        XCTAssertNotNil(downloader)
    }

    func test_modelVerifier_nonexistentFile_returnsFalse() {
        let path = URL(fileURLWithPath: "/nonexistent/model.bin")
        XCTAssertFalse(ModelVerifier.verify(fileAt: path, expectedSHA256: "abc123"))
    }

    func test_modelVerifier_verifyAll_emptyList_returnsTrue() {
        XCTAssertTrue(ModelVerifier.verifyAll(models: []))
    }

    func test_modelManager_storageDir_created() {
        let manager = ModelManager()
        // Verifies no crash, storage dir is set up
        XCTAssertFalse(manager.isReady) // Not ready until download
    }
}
