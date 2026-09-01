import XCTest
@testable import podcasts

final class AsrBackendSelectorTests: XCTestCase {

    func test_select_english_returnsSenseVoice() {
        let selector = AsrBackendSelector()
        let backend = selector.select(locale: Locale(identifier: "en_US"))
        XCTAssertTrue(backend is SenseVoiceBackend)
    }

    func test_select_cjkLocales_returnSenseVoice() {
        let selector = AsrBackendSelector()
        for localeCode in ["zh", "ja", "ko", "zh_CN"] {
            let backend = selector.select(locale: Locale(identifier: localeCode))
            XCTAssertTrue(backend is SenseVoiceBackend, "Locale \(localeCode) should route to SenseVoice")
        }
    }

    func test_select_deEsFr_returnCanaryFlash() {
        let selector = AsrBackendSelector()
        for localeCode in ["de", "es", "fr"] {
            let backend = selector.select(locale: Locale(identifier: localeCode))
            XCTAssertTrue(backend is CanaryFlashBackend, "Locale \(localeCode) should route to CanaryFlash")
            let canary = backend as? CanaryFlashBackend
            XCTAssertEqual(canary?.srcLang, localeCode, "Canary srcLang should be the locale")
        }
    }

    func test_select_unsupportedLocale_returnsWhisper() {
        let selector = AsrBackendSelector()
        for localeCode in ["ar", "ru", "pt"] {
            let backend = selector.select(locale: Locale(identifier: localeCode))
            XCTAssertTrue(backend is WhisperCppBackend, "Locale \(localeCode) should fall back to Whisper")
        }
    }
}
