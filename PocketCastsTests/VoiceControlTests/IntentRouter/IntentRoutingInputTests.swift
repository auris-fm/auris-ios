import XCTest
@testable import podcasts

final class IntentRoutingInputTests: XCTestCase {

    func test_translateSuccess_zh_preservesSourceAndPlatformKind() async throws {
        let backend = StubAsrBackend(
            result: AsrResult(text: "倒回去3分钟。", detectedLanguage: "zh"),
            canTranslate: false
        )
        let translation = StubTranslationStage(
            ensureReady: .success(()),
            translateResult: "Go back to 3 minutes."
        )
        let engine = makeEngine(backend: backend, translation: translation)

        var inputs: [IntentRoutingInput] = []
        var errors = 0
        engine.onRoutingInput = { inputs.append($0) }
        engine.onWakeOnly = { errors += 1 }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertEqual(errors, 0)
        XCTAssertEqual(inputs.count, 1)
        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(input.sourceTranscript, "倒回去3分钟。")
        XCTAssertEqual(input.sourceLanguage, "zh")
        XCTAssertEqual(input.routerTranscript, "Go back to 3 minutes.")
        XCTAssertEqual(input.translationKind, .platform)
    }

    func test_english_sameSourceAndRouter_noneKind() async throws {
        let backend = StubAsrBackend(
            result: AsrResult(text: "pause", detectedLanguage: "en"),
            canTranslate: false
        )
        let translation = StubTranslationStage(ensureReady: .success(()), translateResult: "unused")
        let engine = makeEngine(backend: backend, translation: translation)

        var inputs: [IntentRoutingInput] = []
        engine.onRoutingInput = { inputs.append($0) }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertEqual(inputs.count, 1)
        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(input.sourceTranscript, "pause")
        XCTAssertEqual(input.sourceLanguage, "en")
        XCTAssertEqual(input.routerTranscript, "pause")
        XCTAssertEqual(input.translationKind, .none)
        XCTAssertEqual(translation.ensureReadyCalls, 0)
    }

    func test_backendTranslation_recordsBackendKind() async throws {
        // Canary semantics: English router text, configured source language, no native source text.
        let backend = StubAsrBackend(
            result: AsrResult(text: "skip forward", detectedLanguage: "de"),
            canTranslate: true
        )
        let translation = StubTranslationStage(ensureReady: .success(()), translateResult: "unused")
        let engine = makeEngine(backend: backend, translation: translation)

        var inputs: [IntentRoutingInput] = []
        engine.onRoutingInput = { inputs.append($0) }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertEqual(inputs.count, 1)
        let input = try XCTUnwrap(inputs.first)
        XCTAssertNil(input.sourceTranscript, "Canary exposes English only — source text absent")
        XCTAssertEqual(input.sourceLanguage, "de", "configured source language must survive")
        XCTAssertEqual(input.routerTranscript, "skip forward")
        XCTAssertEqual(input.translationKind, .backend)
        XCTAssertEqual(translation.ensureReadyCalls, 0)
    }

    func test_translateFail_dropsAndNeverForwardsRoutingInput() async {
        let backend = StubAsrBackend(
            result: AsrResult(text: "你好", detectedLanguage: "zh"),
            canTranslate: false
        )
        let translation = StubTranslationStage(
            ensureReady: .failure(NSError(domain: "t", code: 1)),
            translateResult: "unused"
        )
        let engine = makeEngine(backend: backend, translation: translation)

        var inputs: [IntentRoutingInput] = []
        var errors = 0
        engine.onRoutingInput = { inputs.append($0) }
        engine.onWakeOnly = { errors += 1 }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertTrue(inputs.isEmpty)
        XCTAssertEqual(errors, 1)
    }

    private func makeEngine(backend: AsrBackend, translation: TranslationStage) -> VoiceAsrEngine {
        let grace = GracePeriodSignal()
        grace.onCommandRecognized()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: ContinuousWakeStub(),
            gracePeriodSignal: grace,
            translationStage: translation
        )
        engine.listeningMode = .continuous
        return engine
    }
}

// MARK: - Stubs (shared with TranslateDropTests shape)

private final class ContinuousWakeStub: WakeWordDetectorProtocol {
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
        .notDetected(confidence: 0.1)
    }

    func release() {}
}

private final class StubAsrBackend: AsrBackend {
    let result: AsrResult
    let canTranslate: Bool

    init(result: AsrResult, canTranslate: Bool) {
        self.result = result
        self.canTranslate = canTranslate
    }

    var requiredModel: ModelSpec {
        ModelSpec(id: "stub", files: [], targetDir: "stub")
    }

    var capabilities: AsrCapabilities {
        AsrCapabilities(languages: ["zh", "en", "de"], canTranslateToEnglish: canTranslate, requiresHardwareAccel: false)
    }

    func ensureReady() async -> Result<Void, Error> { .success(()) }

    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult { result }

    func release() {}
}

private final class StubTranslationStage: TranslationStage {
    let ensureReadyResult: Result<Void, Error>
    let translateResult: String
    private(set) var ensureReadyCalls = 0

    init(ensureReady: Result<Void, Error>, translateResult: String) {
        self.ensureReadyResult = ensureReady
        self.translateResult = translateResult
    }

    func ensureReady(sourceLanguage: String) async -> Result<Void, Error> {
        ensureReadyCalls += 1
        return ensureReadyResult
    }

    func translate(text: String, sourceLanguage: String) async -> String {
        translateResult
    }
}
