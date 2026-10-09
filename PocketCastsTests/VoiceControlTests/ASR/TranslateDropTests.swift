import XCTest
@testable import podcasts

final class TranslateDropTests: XCTestCase {
    /// The index the segmenter would report for this capture: its last frame at
    /// or above the wired level. Direct callers of `processUtterance` must supply
    /// it, since the engine no longer re-derives it from energy.
    private func producerSpeechEnd(of samples: [Float], level: Float = 0.020) -> Int {
        var last = -1
        for (index, value) in samples.enumerated() where value >= level { last = index }
        return last
    }



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
        await engine.processUtterance(samples, lastSpeechSample: producerSpeechEnd(of: samples))

        XCTAssertEqual(routed, 0, "a wake-only capture carries no request")
        XCTAssertEqual(unroutable, 0, "a bare wake is not an unroutable question — nothing may render ERROR")
        XCTAssertEqual(wakeOnly, 1, "the wake-only signal is the silent one")
    }

    /// The trimmer reasons at the **producing segmenter's** level, not a default.
    ///
    /// Both directions of the disagreement are audible, and only the wired level
    /// prevents them. The app builds this segmenter at 0.020 (`VoiceControlAssembly`),
    /// ten times `NativeVadSegmenter.defaultThreshold`, so a trimmer using the
    /// default would sit *below* the producer: room ambience in the segmenter's
    /// 500 ms hangover would read as speech, the capture would look like a
    /// question, and a phonetic rendering of the wake would escalate and spend the
    /// window's single dispatch. This asserts on the engine's own wiring, which is
    /// where the level is chosen — a unit test of the trimmer cannot see it.
    func test_trimmerUsesTheProducingSegmentersLevel_notADefault() async {
        let backend = StubAsrBackend(
            result: AsrResult(text: "Oace.", detectedLanguage: "en"),
            canTranslate: false
        )
        let grace = GracePeriodSignal()
        grace.onCommandRecognized()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            // The wired level, not the default: this is the value under test.
            segmenter: NativeVadSegmenter(threshold: 0.020),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: DetectingWakeStub(),
            gracePeriodSignal: grace,
            translationStage: nil
        )
        engine.listeningMode = .continuous

        var unroutable = 0
        var wakeOnly = 0
        engine.onRoutingInput = { _ in }
        engine.onUnroutable = { unroutable += 1 }
        engine.onWakeOnly = { wakeOnly += 1 }

        // A bare wake followed by the segmenter's hangover at a level a real
        // microphone produces (≈ -44 dBFS) — below the producer's 0.020, which is
        // why it was appended as silence, and above the old default of 0.002.
        var samples = [Float](repeating: 0.05, count: 250 * 16)
        samples += [Float](repeating: 0.006, count: 500 * 16)
        await engine.processUtterance(samples, lastSpeechSample: producerSpeechEnd(of: samples))

        XCTAssertEqual(unroutable, 0, "ambience below the producer's level is not a question")
        XCTAssertEqual(wakeOnly, 1, "the silence after a bare wake stays a bare wake")
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
