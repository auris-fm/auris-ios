import XCTest
@testable import podcasts

final class VoiceDialogManagerTests: XCTestCase {

    func test_begin_bookmarkRename_emitsNoIntent() {
        let manager = VoiceDialogManager()
        let result = manager.handle(.begin(targetTool: "bookmark", targetAction: "rename"))
        XCTAssertNil(result.intent)
        XCTAssertNotNil(manager.pendingDialog)
        XCTAssertEqual(manager.pendingDialog?.targetTool, "bookmark")
        XCTAssertEqual(manager.pendingDialog?.targetAction, "rename")
    }

    func test_provideSlot_fillsMissingSlot_thenEmitsIntent() {
        let manager = VoiceDialogManager()
        _ = manager.handle(.begin(targetTool: "bookmark", targetAction: "rename"))
        _ = manager.handle(.provideSlot(targetTool: "bookmark", targetAction: "rename", slot: "ref", value: "3"))
        let result = manager.handle(.provideSlot(targetTool: "bookmark", targetAction: "rename", slot: "title", value: "Great quote"))
        XCTAssertNotNil(result.intent)
        guard let bookmarkIntent = result.intent as? BookmarkIntent else { XCTFail(); return }
        XCTAssertEqual(bookmarkIntent, .rename(ref: "3", title: "Great quote"))
    }

    func test_deny_confirmation_emitsNoIntent() {
        let manager = VoiceDialogManager()
        // Setting pendingAction via internal state
        _ = manager.handle(.begin(targetTool: "queue", targetAction: "clear"))
        let result = manager.handle(.deny)
        XCTAssertNil(result.intent)
    }

    func test_cancel_clearsPendingDialog() {
        let manager = VoiceDialogManager()
        _ = manager.handle(.begin(targetTool: "bookmark", targetAction: "rename"))
        XCTAssertNotNil(manager.pendingDialog)
        let result = manager.handle(.cancel)
        XCTAssertNil(result.intent)
        XCTAssertNil(manager.pendingDialog)
    }

    func test_newCommand_clearsAndReturnsValue() {
        let manager = VoiceDialogManager()
        _ = manager.handle(.begin(targetTool: "queue", targetAction: "add_top"))
        let result = manager.handle(.newCommand(value: "pause"))
        XCTAssertNil(manager.pendingDialog)
        XCTAssertEqual(result.question, "pause")
    }

    func test_missingSlot_generatesQuestion() {
        let manager = VoiceDialogManager()
        let result = manager.handle(.begin(targetTool: "bookmark", targetAction: "rename"))
        XCTAssertNotNil(result.question)
        XCTAssertFalse(result.question?.isEmpty ?? true)
    }
}
