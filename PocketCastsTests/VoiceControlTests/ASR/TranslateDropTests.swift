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

    // MARK: - Engine: a wake-only capture is silent (no ERROR earcon)

    /// The governing rule, from the recognition pipeline's own acceptance list:
    /// *"a wake-only capture is silent, so no `ERROR` follows it."* Two producers
    /// feed the same observable — a trimmer result of `""` (the wake was heard and
    /// nothing else was said) and the engine's own drop — so the assertion is on
    /// the observable the user hears: the error path must not fire, on either.
    func test_wakeOnlyCapture_isSilent_doesNotRenderError() async {
        let backend = StubAsrBackend(
            result: AsrResult(text: "Oace.", detectedLanguage: "en"),
            canTranslate: false
        )
        let grace = GracePeriodSignal()
        grace.onCommandRecognized()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: DetectingWakeStub(),
            gracePeriodSignal: grace,
            translationStage: nil
        )
        engine.listeningMode = .continuous

        var routed = 0
        var unroutable = 0
        var wakeOnly = 0
        engine.onRoutingInput = { _ in routed += 1 }
        engine.onUnroutable = { unroutable += 1 }
        engine.onWakeOnly = { wakeOnly += 1 }

        // The real shape of a bare wake: 250 ms of speech (the wake itself)
        // followed by the segmenter's trailing silence. A short capture with no
        // hangover is *not* the case this rule is about — it must not be used to
        // assert it, or the test passes for the wrong reason.
        var samples = [Float](repeating: 0.05, count: 250 * 16)
        samples += [Float](repeating: 0.0001, count: 500 * 16)
        await engine.processUtterance(samples)

        XCTAssertEqual(routed, 0, "a wake-only capture carries no request")
        XCTAssertEqual(unroutable, 0, "a bare wake is not an unroutable question — nothing may render ERROR")
        XCTAssertEqual(wakeOnly, 1, "the wake-only signal is the silent one")
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
        var unroutable = 0
        engine.onRoutingInput = { _ in routed += 1 }
        engine.onUnroutable = { unroutable += 1 }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertEqual(routed, 0, "must not forward native CJK when translation stage is missing")
        XCTAssertEqual(unroutable, 1, "an unroutable capture is what renders the ERROR earcon")
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
        var unroutable = 0
        engine.onRoutingInput = { transcripts.append($0.routerTranscript) }
        engine.onUnroutable = { unroutable += 1 }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertEqual(transcripts, ["pause"])
        XCTAssertEqual(unroutable, 0)
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
        var unroutable = 0
        engine.onRoutingInput = { transcripts.append($0.routerTranscript) }
        engine.onUnroutable = { unroutable += 1 }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertEqual(transcripts, ["pause"])
        XCTAssertEqual(unroutable, 0)
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
        var unroutable = 0
        engine.onRoutingInput = { transcripts.append($0.routerTranscript) }
        engine.onUnroutable = { unroutable += 1 }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertTrue(transcripts.isEmpty, "must not forward native CJK to LFM")
        XCTAssertEqual(unroutable, 1, "an unroutable capture is what renders the ERROR earcon")
    }
}

// MARK: - Stubs

/// Detects the wake, so the wake-only path is exercised rather than the
/// grace/continuous path. `completionSample` is where the detector says the wake
/// *ended* — near the end of the speech in the capture, not at its start, which
/// is what makes the wake band meaningful.
private final class DetectingWakeStub: WakeWordDetectorProtocol {
    let completionSample: Int

    init(completionSample: Int = 250 * 16) {   // 250 ms at 16 kHz
        self.completionSample = completionSample
    }

    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
        .detected(confidence: 0.9, completionSample: completionSample)
    }

    func release() {}
}

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
