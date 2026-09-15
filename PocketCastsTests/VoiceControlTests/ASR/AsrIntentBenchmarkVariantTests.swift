import XCTest
@testable import podcasts

/// Pins the D/E variant input shapes (Item 21): D = english_v1 router sees
/// English only; E = dual_v1 router renders from native + English transcript.
/// Mirrors the Android harness `buildInput` so both lanes measure the same
/// protocol on the shared text contract.
final class AsrIntentBenchmarkVariantTests: XCTestCase {
    private let zhCase = RepresentationBenchmarkCase(
        caseID: "zh_case_1",
        language: "zh",
        nativeText: "暂停",
        englishText: "pause playback"
    )

    func test_variantDRouterSeesEnglishOnly() {
        let input = AsrIntentBenchmarkRunner.makeInput(
            variant: AsrIntentBenchmarkRunner.variantD,
            benchmarkCase: zhCase
        )
        XCTAssertEqual(input.routerTranscript, "pause playback")
        XCTAssertEqual(input.translationKind, .platform)
        XCTAssertEqual(input.sourceLanguage, "zh")
    }

    func test_variantEKeepsNativeAndEnglish() {
        let input = AsrIntentBenchmarkRunner.makeInput(
            variant: AsrIntentBenchmarkRunner.variantE,
            benchmarkCase: zhCase
        )
        XCTAssertEqual(input.sourceTranscript, "暂停")
        XCTAssertEqual(input.routerTranscript, "pause playback")
        XCTAssertEqual(input.translationKind, .platform)
    }

    func test_englishCasesUseNoneTranslationKind() {
        let enCase = RepresentationBenchmarkCase(
            caseID: "en_1", language: "en", nativeText: "pause", englishText: "pause"
        )
        for variant in [AsrIntentBenchmarkRunner.variantD, AsrIntentBenchmarkRunner.variantE] {
            let input = AsrIntentBenchmarkRunner.makeInput(variant: variant, benchmarkCase: enCase)
            XCTAssertEqual(input.translationKind, .none)
        }
    }

    func test_unknownVariantIsRejected() {
        XCTAssertThrowsError(
            try AsrIntentBenchmarkRunner.makeInputOrThrow(variant: "C", benchmarkCase: zhCase)
        )
    }
}
