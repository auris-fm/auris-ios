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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = ModelManager(storageDir: dir)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
                      "init must create the storage directory")
        XCTAssertTrue(isDirectory.boolValue)
    }
}
