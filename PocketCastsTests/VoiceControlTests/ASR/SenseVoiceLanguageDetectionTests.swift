import XCTest

@testable import podcasts

final class SenseVoiceLanguageDetectionTests: XCTestCase {

    func testPrefersStructuredLangOverTextTag() {
        XCTAssertEqual(
            SenseVoiceBackend.resolveDetectedLanguage(structuredLang: "zh", text: "<|ja|>こんにちは"),
            "zh"
        )
    }

    func testNormalizesTaggedStructuredLang() {
        XCTAssertEqual(
            SenseVoiceBackend.resolveDetectedLanguage(structuredLang: "<|zh|>", text: "你好"),
            "zh"
        )
        XCTAssertEqual(
            SenseVoiceBackend.resolveDetectedLanguage(structuredLang: "<|en|>", text: "hello"),
            "en"
        )
        XCTAssertEqual(
            SenseVoiceBackend.resolveDetectedLanguage(structuredLang: "<|zh/en|>", text: "hello"),
            "zh"
        )
    }

    func testFallsBackToTextTagWhenStructuredBlank() {
        XCTAssertEqual(
            SenseVoiceBackend.resolveDetectedLanguage(structuredLang: "  ", text: "<|zh|>你好"),
            "zh"
        )
        XCTAssertEqual(
            SenseVoiceBackend.resolveDetectedLanguage(structuredLang: nil, text: "<|ja|>こんにちは"),
            "ja"
        )
    }

    func testFallsBackToScriptWhenNoTagPresent() {
        // Script-based final fallback (LID-null resilience): Han → zh,
        // Hiragana/Katakana → ja, Hangul → ko. Latin/empty → nil.
        XCTAssertEqual(
            SenseVoiceBackend.resolveDetectedLanguage(structuredLang: nil, text: "这个嘉宾还在哪些节目上过"),
            "zh"
        )
        XCTAssertEqual(
            SenseVoiceBackend.resolveDetectedLanguage(structuredLang: nil, text: "こんにちは、このゲスト"),
            "ja"
        )
        XCTAssertEqual(
            SenseVoiceBackend.resolveDetectedLanguage(structuredLang: nil, text: "안녕하세요 이 게스트"),
            "ko"
        )
        XCTAssertNil(SenseVoiceBackend.resolveDetectedLanguage(structuredLang: nil, text: "hello there"))
        XCTAssertNil(SenseVoiceBackend.resolveDetectedLanguage(structuredLang: nil, text: ""))
    }

    func testScriptFallbackPrefersKanaAndHangulOverLeadingHan() {
        // Mixed-script Japanese leading with a Han kanji must resolve ja.
        XCTAssertEqual(
            SenseVoiceBackend.resolveDetectedLanguage(structuredLang: nil, text: "漢字のテスト"),
            "ja"
        )
        // Han-leading Korean (hanja + hangul) must resolve ko.
        XCTAssertEqual(
            SenseVoiceBackend.resolveDetectedLanguage(structuredLang: nil, text: "漢字 한글"),
            "ko"
        )
    }

    func testScriptFallbackDoesNotOverrideStructuredOrTag() {
        // Structured LID still wins even when it disagrees with the script.
        XCTAssertEqual(
            SenseVoiceBackend.resolveDetectedLanguage(structuredLang: "yue", text: "這個嘉賓"),
            "yue"
        )
        // Text tag still beats script.
        XCTAssertEqual(
            SenseVoiceBackend.resolveDetectedLanguage(structuredLang: nil, text: "<|yue|>這個嘉賓"),
            "yue"
        )
    }

    func testReturnsNilWhenNeitherPresent() {
        // Updated per LID-null resilience spec: bare Han text now resolves via
        // the script fallback (→ zh); latin text still yields nil.
        XCTAssertEqual(SenseVoiceBackend.resolveDetectedLanguage(structuredLang: "", text: "你好"), "zh")
        XCTAssertNil(SenseVoiceBackend.resolveDetectedLanguage(structuredLang: nil, text: "hello"))
        XCTAssertNil(SenseVoiceBackend.resolveDetectedLanguage(structuredLang: "<|NEUTRAL|>", text: "hello"))
    }

    func testNormalizeLanguageCode() {
        XCTAssertEqual(SenseVoiceBackend.normalizeLanguageCode("KO"), "ko")
        XCTAssertEqual(SenseVoiceBackend.normalizeLanguageCode("<|yue|>"), "yue")
        XCTAssertNil(SenseVoiceBackend.normalizeLanguageCode(""))
        XCTAssertNil(SenseVoiceBackend.normalizeLanguageCode(nil))
    }
}
