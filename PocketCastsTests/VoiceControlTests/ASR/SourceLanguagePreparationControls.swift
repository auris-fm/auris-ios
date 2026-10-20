import XCTest
@testable import podcasts

/// PRODUCTION-PREPARATION controls (reviewer 4af8d2d5 gap): AsrResult + ACTUAL backend
/// capability through the engine's real `maybeTranslate` → `makeRoutingInput` preparation, with
/// the produced `IntentRoutingInput` captured via the production `onRoutingInput` seam. No case
/// constructs the input directly.
///
/// Named mutants each fail named controls:
///   - reverting the unknown-LID `?? "en"` default → `testUnknownLidStaysNilNotEn` RED.
///   - reverting backend-provenance order (LID check before capability) →
///     `testBackendTranslateOmitsSourceEvenWhenLidUnknown` RED (unknown-LID backend-translate
///     output would be mislabeled as original source text).
final class SourceLanguagePreparationControls: XCTestCase {
    // MARK: - Harness (real engine, real preparation path)

    private final class StubAsrBackend: AsrBackend {
        let result: AsrResult
        let canTranslate: Bool

        init(result: AsrResult, canTranslate: Bool) {
            self.result = result
            self.canTranslate = canTranslate
        }

        var requiredModel: ModelSpec { ModelSpec(id: "stub", files: [], targetDir: "stub") }
        var capabilities: AsrCapabilities {
            AsrCapabilities(languages: ["zh", "en", "yue"], canTranslateToEnglish: canTranslate, requiresHardwareAccel: false)
        }
        func ensureReady() async -> Result<Void, Error> { .success(()) }
        func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult { result }
        func release() {}
    }

    private final class StubTranslationStage: TranslationStage {
        let ensureReadyResult: Result<Void, Error>
        let translateResult: String
        init(ensureReady: Result<Void, Error>, translateResult: String) {
            self.ensureReadyResult = ensureReady
            self.translateResult = translateResult
        }
        func ensureReady(sourceLanguage: String) async -> Result<Void, Error> { ensureReadyResult }
        func translate(text: String, sourceLanguage: String) async -> String { translateResult }
    }

    private final class NeverWakeStub: WakeWordDetectorProtocol {
        func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
            .notDetected(confidence: 0.1)
        }
        func release() {}
    }

    @MainActor
    private func makeEngine(
        result: AsrResult,
        canTranslate: Bool,
        translated: String? = "play something upbeat"
    ) -> VoiceAsrEngine {
        let backend = StubAsrBackend(result: result, canTranslate: canTranslate)
        let translation = StubTranslationStage(ensureReady: .success(()), translateResult: translated ?? "")
        let grace = GracePeriodSignal()
        grace.onCommandRecognized()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: NeverWakeStub(),
            gracePeriodSignal: grace,
            translationStage: translation
        )
        engine.listeningMode = .wakeWord
        return engine
    }

    private final class InputBox: @unchecked Sendable {
        var inputs: [IntentRoutingInput] = []
    }

    private func preparedInput(
        text: String, language: String?, canTranslate: Bool
    ) async -> IntentRoutingInput {
        let engine = await makeEngine(
            result: AsrResult(text: text, detectedLanguage: language),
            canTranslate: canTranslate
        )
        let box = InputBox()
        await MainActor.run { engine.onRoutingInput = { box.inputs.append($0) } }
        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))
        return await MainActor.run { box.inputs.first }
            ?? { XCTFail("the production preparation produced no routing input"); return .english(transcript: "unreachable", utteranceId: "u-200") }()
    }

    // MARK: - Platform translate: source preserved, actual LID carried

    func testPlatformTranslationPreservesYueSource() async {
        let input = await preparedInput(text: "嚟啲歡快嘅", language: "yue", canTranslate: false)
        XCTAssertEqual(input.sourceTranscript, "嚟啲歡快嘅")
        XCTAssertEqual(input.sourceLanguage, "yue", "the ACTUAL ASR LID rides unchanged (yue ≠ zh)")
        XCTAssertEqual(input.routerTranscript, "play something upbeat")
        XCTAssertEqual(input.translationKind, .platform)
    }

    func testPlatformTranslationPreservesZhSource() async {
        let input = await preparedInput(text: "来点欢快的", language: "zh", canTranslate: false)
        XCTAssertEqual(input.sourceTranscript, "来点欢快的")
        XCTAssertEqual(input.sourceLanguage, "zh")
        XCTAssertEqual(input.translationKind, .platform)
    }

    /// Named control for the `?? "en"` mutant: an unknown LID must stay nil.
    func testUnknownLidStaysNilNotEn() async {
        let input = await preparedInput(text: "来点欢快的", language: nil, canTranslate: false)
        XCTAssertEqual(input.sourceTranscript, "来点欢快的")
        XCTAssertNil(
            input.sourceLanguage,
            "an unknown LID is preserved as nil — defaulting to \"en\" fabricates a language"
        )
        // No translation ran (unknown LID skips), so the utterance IS the routing text and the
        // kind is .none — the wire fact that matters is the nil language, not the kind.
    }

    // MARK: - Backend translate: provenance first, English-only output labeled backend

    /// Named control for the provenance-order mutant: with a translating backend and an unknown
    /// LID, the output is TRANSLATED-ONLY (no source text) — asking for the LID first mislabels
    /// it as original.
    func testBackendTranslateOmitsSourceEvenWhenLidUnknown() async {
        let input = await preparedInput(text: "来点欢快的", language: nil, canTranslate: true)
        XCTAssertNil(
            input.sourceTranscript,
            "backend translate exposes English only — the original must not be claimed as source"
        )
        XCTAssertNil(input.sourceLanguage)
        XCTAssertEqual(input.translationKind, .backend)
    }

    func testBackendTranslateKeepsKnownLid() async {
        let input = await preparedInput(text: "来点欢快的", language: "zh", canTranslate: true)
        XCTAssertNil(input.sourceTranscript)
        XCTAssertEqual(input.sourceLanguage, "zh", "backend translate still reports the actual LID")
        XCTAssertEqual(input.translationKind, .backend)
    }

    // MARK: - Local English

    func testLocalEnglishKeepsEnAndSource() async {
        let input = await preparedInput(text: "pause playback", language: "en", canTranslate: false)
        XCTAssertEqual(input.sourceTranscript, "pause playback")
        XCTAssertEqual(input.sourceLanguage, "en")
        XCTAssertEqual(input.routerTranscript, "pause playback")
        XCTAssertEqual(input.translationKind, .none)
    }
}
