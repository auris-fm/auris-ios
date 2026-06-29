import XCTest
@testable import podcasts

final class AsrBackendSelectorTests: XCTestCase {

    func test_select_default_returnsWhisperCpp() {
        let selector = AsrBackendSelector()
        let backend = selector.select(locale: Locale(identifier: "en_US"), hasNPU: false, senseVoiceShipped: false)
        XCTAssertTrue(backend is WhisperCppBackend)
    }

    func test_select_withNPU_returnsWhisperCpp() {
        let selector = AsrBackendSelector()
        let backend = selector.select(locale: Locale(identifier: "en_US"), hasNPU: true, senseVoiceShipped: true)
        XCTAssertTrue(backend is WhisperCppBackend)
    }

    func test_select_senseVoiceLocale_returnsWhisperCpp() {
        let selector = AsrBackendSelector()
        // All supported locales initially route to WhisperCpp until SenseVoice is shipped
        for localeCode in ["zh", "en", "ja", "ko"] {
            let backend = selector.select(locale: Locale(identifier: localeCode), hasNPU: false, senseVoiceShipped: true)
            XCTAssertTrue(backend is WhisperCppBackend, "Locale \(localeCode) should fall back to WhisperCpp")
        }
    }
}
