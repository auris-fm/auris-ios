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

    func testReturnsNilWhenNeitherPresent() {
        XCTAssertNil(SenseVoiceBackend.resolveDetectedLanguage(structuredLang: "", text: "你好"))
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
