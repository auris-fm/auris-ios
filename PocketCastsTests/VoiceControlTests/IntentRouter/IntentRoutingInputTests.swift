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
        var unroutable = 0
        engine.onRoutingInput = { inputs.append($0) }
        engine.onUnroutable = { unroutable += 1 }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertEqual(unroutable, 0)
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
        var unroutable = 0
        engine.onRoutingInput = { inputs.append($0) }
        engine.onUnroutable = { unroutable += 1 }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertTrue(inputs.isEmpty)
        XCTAssertEqual(unroutable, 1)
    }

    /// ONE IDENTITY FROM ADMISSION (spec delta3b1def9). The id is minted at utterance admission
    /// and carried on EVERY routing input the engine emits; two independent utterances carry
    /// different identities. (The trim itself is exercised elsewhere; what this pins is that the
    /// admitted identity, not a freshly minted one, is what the input carries.)
    func test_admittedUtteranceIdSurvivesTrimAndDiffersAcrossUtterances() async throws {
        let backend = StubAsrBackend(
            result: AsrResult(text: "hey auris pause", detectedLanguage: "en"),
            canTranslate: false
        )
        let translation = StubTranslationStage(ensureReady: .success(()), translateResult: "unused")
        let engine = makeEngine(backend: backend, translation: translation, wake: DetectingWakeStub())
        // Known admission ids, so the control can prove the input carries the ADMITTED id.
        var minted = ["adm-1", "adm-2"]
        engine.utteranceIdGeneratorForTesting = { minted.removeFirst() }

        var inputs: [IntentRoutingInput] = []
        engine.onRoutingInput = { inputs.append($0) }
        engine.onWakeOnly = { XCTFail("the command remainder is routable, not wake-only") }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))
        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertEqual(inputs.count, 2, "both utterances reached routing")
        XCTAssertFalse(inputs[0].utteranceId.isEmpty, "the admitted id is carried on the input")
        XCTAssertFalse(inputs[1].utteranceId.isEmpty, "the admitted id is carried on the input")
        XCTAssertEqual(
            inputs[0].translationKind, inputs[1].translationKind,
            "both utterances went the same preparation path"
        )
        XCTAssertEqual(
            inputs[0].utteranceId, "adm-1",
            "the routing input carries the id MINTED AT ADMISSION, not one rebuilt downstream"
        )
        XCTAssertEqual(
            inputs[1].utteranceId, "adm-2",
            "two independent utterances carry their own admitted identities"
        )
    }

    // MARK: - Task #78: NON-CONTENT ASR OUTPUT

    /// PRODUCTION-ENTRY REJECTION (task #78, spec 77eacc9b). A transcript with no Unicode letter or
    /// number is discarded SILENTLY after wake trim and before ANY downstream work — no routing
    /// input, no translation, no unroutable feedback, no wake-only callback. The rule is
    /// content-based, NOT length-based: short meaningful utterances still route.
    func test_nonContentTranscriptIsSilentlyDiscardedBeforeAnyDownstreamWork() async throws {
        let backend = QueueingAsrBackend(results: [
            AsrResult(text: ".", detectedLanguage: "en"),
            AsrResult(text: "   ", detectedLanguage: "en"),
            AsrResult(text: "。！？", detectedLanguage: "zh"),
            AsrResult(text: "…", detectedLanguage: "en"),
            // Then a MEANINGFUL utterance on the SAME engine: it must still work.
            AsrResult(text: "pause", detectedLanguage: "en"),
        ])
        let translation = StubTranslationStage(ensureReady: .success(()), translateResult: "unused")
        let engine = makeEngine(backend: backend, translation: translation)

        var inputs: [IntentRoutingInput] = []
        var unroutable = 0
        var wakeOnly = 0
        engine.onRoutingInput = { inputs.append($0) }
        engine.onUnroutable = { unroutable += 1 }
        engine.onWakeOnly = { wakeOnly += 1 }

        for _ in 0..<5 {
            await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))
        }

        XCTAssertEqual(
            inputs.count, 1,
            "only the meaningful utterance reached routing; non-content was discarded BEFORE routing"
        )
        XCTAssertEqual(inputs.first?.routerTranscript, "pause")
        XCTAssertEqual(
            unroutable, 0,
            "non-content is SILENT — it must not produce unroutable/error feedback"
        )
        XCTAssertEqual(wakeOnly, 0, "non-content is not a wake confirmation either")
        XCTAssertEqual(
            backend.transcribeCalls, 5,
            "premise: every capture WAS recognised (the discards happened after ASR, not before)"
        )
    }

    /// The rejection rule is CONTENT, not LENGTH: short meaningful utterances in several scripts
    /// and any digit survive, while punctuation/whitespace alone do not.
    func test_contentRulePreservesShortMeaningfulUtterancesAcrossScripts() {
        for meaningful in ["yes", "停", "嗯", "3", "ok", "No.", "3分", "بلى", "네"] {
            XCTAssertFalse(
                VoiceAsrEngine.isNonContent(meaningful),
                "\(meaningful.debugDescription) has Unicode content and must NOT be discarded"
            )
        }
        for nonContent in ["", " ", "\n", ".", "...", "。", "？！", "…", "  ,  ", "-"] {
            XCTAssertTrue(
                VoiceAsrEngine.isNonContent(nonContent),
                "\(nonContent.debugDescription) has no letter or number and must be discarded"
            )
        }
    }

    private func makeEngine(
        backend: AsrBackend,
        translation: TranslationStage,
        wake: WakeWordDetectorProtocol? = nil
    ) -> VoiceAsrEngine {
        let grace = GracePeriodSignal()
        grace.onCommandRecognized()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: wake ?? ContinuousWakeStub(),
            gracePeriodSignal: grace,
            translationStage: translation
        )
        engine.listeningMode = .continuous
        return engine
    }
}

// MARK: - Stubs (shared with TranslateDropTests shape)

/// Detects the wake so the wake-word TRIM runs on the command remainder.
private final class DetectingWakeStub: WakeWordDetectorProtocol {
    let completionSample: Int
    init(completionSample: Int = 250 * 16) { self.completionSample = completionSample }
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
        AsrCapabilities(languages: ["zh", "en", "de"], canTranslateToEnglish: canTranslate, requiresHardwareAccel: false)
    }

    func ensureReady() async -> Result<Void, Error> { .success(()) }

    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult { result }

    func release() {}
}

/// A backend that returns a DIFFERENT recognised result per call, so a control can prove both the
/// discard and that the NEXT meaningful utterance still works on the same engine.
private final class QueueingAsrBackend: AsrBackend {
    private var results: [AsrResult]
    private(set) var transcribeCalls = 0

    init(results: [AsrResult]) { self.results = results }

    var requiredModel: ModelSpec { ModelSpec(id: "queueing", files: [], targetDir: "queueing") }

    var capabilities: AsrCapabilities {
        AsrCapabilities(languages: ["zh", "en"], canTranslateToEnglish: false, requiresHardwareAccel: false)
    }

    func ensureReady() async -> Result<Void, Error> { .success(()) }

    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        transcribeCalls += 1
        if results.isEmpty { return AsrResult(text: "", detectedLanguage: nil) }
        return results.removeFirst()
    }

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
