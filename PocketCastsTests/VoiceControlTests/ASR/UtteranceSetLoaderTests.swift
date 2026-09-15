import XCTest
@testable import podcasts

/// Tests for the shared utterance-set JSONL loader (Item 21 text contract:
/// `case_id`, `language`, `text`, `is_rejection`; frozen sha `20a68433…`).
final class UtteranceSetLoaderTests: XCTestCase {
    private func line(
        id: String = "zh_case_1",
        language: String = "zh",
        text: String = "暂停",
        isRejection: Bool = false
    ) -> String {
        let payload: [String: Any] = [
            "case_id": id,
            "language": language,
            "text": text,
            "is_rejection": isRejection,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    func test_parsesContractFields() throws {
        let jsonl = "\(line())\n\(line(id: "en_case_2", language: "en", text: "pause"))\n"
        let cases = try UtteranceSetLoader.load(jsonl: jsonl)
        XCTAssertEqual(cases.count, 2)
        XCTAssertEqual(cases[0].caseID, "zh_case_1")
        XCTAssertEqual(cases[0].language, "zh")
        XCTAssertEqual(cases[0].nativeText, "暂停")
        XCTAssertFalse(cases[0].isRejection)
        XCTAssertEqual(cases[1].caseID, "en_case_2")
    }

    func test_skipsBlankLinesAndPreservesOrder() throws {
        let jsonl = "\n\(line(id: "a"))\n\n\(line(id: "b"))\n"
        let cases = try UtteranceSetLoader.load(jsonl: jsonl)
        XCTAssertEqual(cases.map(\.caseID), ["a", "b"])
    }

    func test_englishSidecarJoinsByID() throws {
        let jsonl = line(id: "zh_case_1")
        let sidecar = ["zh_case_1": "pause playback"]
        let cases = try UtteranceSetLoader.load(jsonl: jsonl, translations: sidecar)
        XCTAssertEqual(cases[0].englishText, "pause playback")
    }

    func test_missingTranslationFallsBackToNativeTextByDefault() throws {
        let cases = try UtteranceSetLoader.load(jsonl: line(id: "zh_x"), translations: [:])
        XCTAssertEqual(cases[0].englishText, "暂停")
    }

    func test_failClosedModeThrowsOnMissingNonEnglishTranslation() {
        XCTAssertThrowsError(
            try UtteranceSetLoader.load(
                jsonl: line(id: "zh_x"),
                translations: [:],
                failClosedOnMissingTranslations: true
            )
        )
    }

    func test_failClosedModeAllowsEnglishCasesWithoutSidecar() throws {
        let cases = try UtteranceSetLoader.load(
            jsonl: line(id: "en_x", language: "en", text: "pause"),
            translations: [:],
            failClosedOnMissingTranslations: true
        )
        XCTAssertEqual(cases[0].englishText, "pause")
    }

    func test_rejectionFlagSurvives() throws {
        let cases = try UtteranceSetLoader.load(
            jsonl: line(id: "reject_1", language: "en", text: "", isRejection: true)
        )
        XCTAssertTrue(cases[0].isRejection)
    }

    func test_throwsOnMissingRequiredFields() {
        XCTAssertThrowsError(try UtteranceSetLoader.load(jsonl: "{\"case_id\":\"x\"}"))
    }
}
