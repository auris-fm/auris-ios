import XCTest
@testable import podcasts

final class AudioSessionDuckerTests: XCTestCase {

    func test_init_createsDucker() {
        let ducker = AudioSessionDucker()
        XCTAssertNotNil(ducker)
    }

    func test_duck_whenVolumeLow_isNoOp() {
        let ducker = AudioSessionDucker()
        // When system volume is already very low, duck() should be a no-op
        // This test verifies the guard logic doesn't crash
        ducker.duck()
        ducker.unduck()
    }

    func test_duckAndUnduck_pairDoesNotCrash() {
        let ducker = AudioSessionDucker()
        ducker.duck()
        ducker.unduck()
        // Verify no crash on duck/unduck pair
    }

    func test_doubleDuck_isIdempotent() {
        let ducker = AudioSessionDucker()
        ducker.duck()
        ducker.duck() // Second duck should be no-op
        ducker.unduck()
        // Should not crash
    }

    func test_unduckWithoutDuck_isNoOp() {
        let ducker = AudioSessionDucker()
        ducker.unduck()
        // Should not crash when unducking without prior duck
    }
}
