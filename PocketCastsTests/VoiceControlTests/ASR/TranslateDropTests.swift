import XCTest
@testable import podcasts

final class TranslateDropTests: XCTestCase {

    // MARK: - Note classification (Android isNonEnglishTranslateFailure parity)

    func test_isNonEnglishTranslateFailure_failBlankNoop() {
        XCTAssertTrue(VoiceAsrEngine.isNonEnglishTranslateFailure("translate=fail(zh)"))
        XCTAssertTrue(VoiceAsrEngine.isNonEnglishTranslateFailure("translate=blank(zh)"))
        XCTAssertTrue(VoiceAsrEngine.isNonEnglishTranslateFailure("translate=noop(zh)"))
    }

    func test_isNonEnglishTranslateFailure_successAndSkips() {
        XCTAssertFalse(VoiceAsrEngine.isNonEnglishTranslateFailure(nil))
        XCTAssertFalse(VoiceAsrEngine.isNonEnglishTranslateFailure("translate=zh→en 'pause'"))
        XCTAssertFalse(VoiceAsrEngine.isNonEnglishTranslateFailure("translate=skip(no lang)"))
        XCTAssertFalse(VoiceAsrEngine.isNonEnglishTranslateFailure("translate=skip(backend)"))
        // Missing translation stage is a hard failure (ERROR+drop), not a safe skip.
        XCTAssertTrue(VoiceAsrEngine.isNonEnglishTranslateFailure("translate=skip(no stage)"))
    }

    // MARK: - Engine: drop + ERROR earcon, no transcript forward

    func test_translateFail_dropsAndPlaysErrorEarcon() async {
        await assertTranslateCaseDrops(
            ensureReady: .failure(NSError(domain: "t", code: 1)),
            translateResult: nil
        )
    }

    func test_translateBlank_dropsAndPlaysErrorEarcon() async {
        await assertTranslateCaseDrops(
            ensureReady: .success(()),
            translateResult: ""
        )
    }

    func test_translateNoop_dropsAndPlaysErrorEarcon() async {
        await assertTranslateCaseDrops(
            ensureReady: .success(()),
            translateResult: "你好"
        )
    }

    func test_missingTranslationStage_dropsNonEnglishWithoutRouting() async {
        let backend = StubAsrBackend(
            result: AsrResult(text: "你好", detectedLanguage: "zh"),
            canTranslate: false
        )
        let grace = GracePeriodSignal()
        grace.onCommandRecognized()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: ContinuousWakeStub(),
            gracePeriodSignal: grace,
            translationStage: nil
        )
        engine.listeningMode = .continuous

        var routed = 0
        var errors = 0
        engine.onRoutingInput = { _ in routed += 1 }
        engine.onWakeOnly = { errors += 1 }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertEqual(routed, 0, "must not forward native CJK when translation stage is missing")
        XCTAssertEqual(errors, 1, "must play ERROR earcon via onWakeOnly")
    }

    func test_englishBypassesTranslation_forwardsTranscript() async {
        let backend = StubAsrBackend(
            result: AsrResult(text: "pause", detectedLanguage: "en"),
            canTranslate: false
        )
        let translation = StubTranslationStage(ensureReady: .success(()), translateResult: "should-not-run")
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

        var transcripts: [String] = []
        var errors = 0
        engine.onRoutingInput = { transcripts.append($0.routerTranscript) }
        engine.onWakeOnly = { errors += 1 }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertEqual(transcripts, ["pause"])
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(translation.ensureReadyCalls, 0)
    }

    func test_translateSuccess_forwardsEnglishTranscript() async {
        let backend = StubAsrBackend(
            result: AsrResult(text: "你好", detectedLanguage: "zh"),
            canTranslate: false
        )
        let translation = StubTranslationStage(ensureReady: .success(()), translateResult: "pause")
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

        var transcripts: [String] = []
        var errors = 0
        engine.onRoutingInput = { transcripts.append($0.routerTranscript) }
        engine.onWakeOnly = { errors += 1 }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertEqual(transcripts, ["pause"])
        XCTAssertEqual(errors, 0)
    }

    private func assertTranslateCaseDrops(
        ensureReady: Result<Void, Error>,
        translateResult: String?
    ) async {
        let backend = StubAsrBackend(
            result: AsrResult(text: "你好", detectedLanguage: "zh"),
            canTranslate: false
        )
        let translation = StubTranslationStage(
            ensureReady: ensureReady,
            translateResult: translateResult ?? "unused"
        )
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

        var transcripts: [String] = []
        var errors = 0
        engine.onRoutingInput = { transcripts.append($0.routerTranscript) }
        engine.onWakeOnly = { errors += 1 }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertTrue(transcripts.isEmpty, "must not forward native CJK to LFM")
        XCTAssertEqual(errors, 1, "must play ERROR earcon via onWakeOnly")
    }
}

// MARK: - Stubs

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
        AsrCapabilities(languages: ["zh", "en"], canTranslateToEnglish: canTranslate, requiresHardwareAccel: false)
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
