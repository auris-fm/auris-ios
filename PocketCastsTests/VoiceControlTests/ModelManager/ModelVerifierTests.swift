import XCTest
@testable import podcasts

final class ModelVerifierTests: XCTestCase {

    func test_verify_nonexistentFile_returnsFalse() {
        let path = URL(fileURLWithPath: "/tmp/auris_test_nonexistent.bin")
        XCTAssertFalse(ModelVerifier.verify(fileAt: path, expectedSHA256: "abc"))
    }

    func test_verifyAll_emptyList_returnsTrue() {
        XCTAssertTrue(ModelVerifier.verifyAll(models: []))
    }
}
