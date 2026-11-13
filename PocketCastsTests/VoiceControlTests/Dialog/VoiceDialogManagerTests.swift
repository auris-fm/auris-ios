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

    /// Deny always emits nothing. It must also NOT close an in-progress slot dialog: the
    /// slot flow completes at the last filled slot, so a deny mid-dialog leaves the dialog
    /// answerable (the old pendingAction machinery made deny dead code with an unreachable
    /// guard; both outcomes here are pinned).
    func test_deny_emitsNoIntent_andLeavesTheDialogAnswerable() {
        let manager = VoiceDialogManager()
        _ = manager.handle(.begin(targetTool: "queue", targetAction: "clear"))
        let denied = manager.handle(.deny)
        XCTAssertNil(denied.intent)
        XCTAssertNil(denied.question)

        // The dialog survives the deny: the missing-slot question still comes back.
        _ = manager.handle(.begin(targetTool: "bookmark", targetAction: "play"))
        _ = manager.handle(.deny)
        let answered = manager.handle(.provideSlot(targetTool: "bookmark", targetAction: "play", slot: "ref", value: "7"))
        XCTAssertNotNil(answered.intent)
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
        // new_command re-processes the value as a fresh transcript (spec 0443b70) — it does not
        // render the value as a spoken question.
        XCTAssertNil(result.question)
        XCTAssertEqual(result.reprocessValue, "pause")
    }

    func test_newCommand_withNoPendingDialogDoesNotReprocess() {
        // A new_command with nothing pending is a cancel of nothing — re-processing its value
        // anyway would loop forever (each re-processed transcript that classifies as new_command
        // would schedule itself again).
        let manager = VoiceDialogManager()
        let result = manager.handle(.newCommand(value: "pause"))
        XCTAssertNil(result.intent)
        XCTAssertNil(result.question)
        XCTAssertNil(result.reprocessValue)
    }

    func test_missingSlot_generatesQuestion() {
        let manager = VoiceDialogManager()
        let result = manager.handle(.begin(targetTool: "bookmark", targetAction: "rename"))
        XCTAssertNotNil(result.question)
        XCTAssertFalse(result.question?.isEmpty ?? true)
    }
}
