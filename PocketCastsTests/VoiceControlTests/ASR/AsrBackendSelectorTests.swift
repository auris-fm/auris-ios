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
        for localeCode in ["zh", "ja", "ko", "yue", "zh_CN"] {
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

    func test_select_unsupportedLocale_returnsNil() {
        let selector = AsrBackendSelector()
        for localeCode in ["ar", "ru", "pt"] {
            let backend = selector.select(locale: Locale(identifier: localeCode))
            XCTAssertNil(backend, "Locale \(localeCode) should surface unsupported (no Whisper product route)")
        }
    }

    func test_select_doesNotProductRouteToWhisper() {
        let selector = AsrBackendSelector()
        for localeCode in ["en_US", "zh_CN", "de", "ar", "ru"] {
            let backend = selector.select(locale: Locale(identifier: localeCode))
            if let backend {
                XCTAssertFalse(backend is WhisperCppBackend, "Locale \(localeCode) must not select Whisper")
            }
        }
    }

    func test_assembly_resolveAsrBackend_unsupportedFailsClosed() {
        let assembly = VoiceControlAssembly()
        XCTAssertNil(assembly.resolveAsrBackend(locale: Locale(identifier: "ar")))
        XCTAssertNil(assembly.resolveAsrBackend(locale: Locale(identifier: "ru")))
        XCTAssertTrue(assembly.resolveAsrBackend(locale: Locale(identifier: "en_US")) is SenseVoiceBackend)
        XCTAssertTrue(assembly.resolveAsrBackend(locale: Locale(identifier: "de")) is CanaryFlashBackend)
    }
}
