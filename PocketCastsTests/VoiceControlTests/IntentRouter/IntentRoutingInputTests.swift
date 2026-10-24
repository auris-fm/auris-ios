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
        engine.onRoutingInput = { inputs.append($0); return true }
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
        engine.onRoutingInput = { inputs.append($0); return true }

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
        engine.onRoutingInput = { inputs.append($0); return true }

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
        engine.onRoutingInput = { inputs.append($0); return true }
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
        engine.onRoutingInput = { inputs.append($0); return true }
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
        engine.onRoutingInput = { inputs.append($0); return true }
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

    /// PRODUCTION-ENTRY WAKE TRIM × NON-CONTENT (task #78 reviewer round): a WAKE-POSITIVE
    /// capture whose permitted trim leaves a non-content remainder is discarded SILENTLY —
    /// the wake phrase never leaks to routing, and CLEANUP means no translation-stage work,
    /// no unroutable feedback, and no wake-only confirmation for the junk remainder.
    func test_wakePositiveTrimLeavingNonContentRemainderIsSilentlyDiscardedWithNoTranslationWork() async throws {
        let backend = QueueingAsrBackend(results: [
            AsrResult(
                text: "hey auris !!!",
                detectedLanguage: "en",
                tokens: [
                    AsrToken(text: "hey auris", startMs: 0, endMs: 300),   // inside the 370 ms band
                    AsrToken(text: "!!!", startMs: 400, endMs: 700),       // the remainder
                ]
            ),
            // The NEXT capture on the SAME running engine must work normally: the discard
            // left no wedged pipeline state (reviewer f03b9cf1).
            AsrResult(
                text: "hey auris pause",
                detectedLanguage: "en",
                tokens: [
                    AsrToken(text: "hey auris", startMs: 0, endMs: 300),
                    AsrToken(text: " pause", startMs: 400, endMs: 700),
                ]
            ),
        ])
        let translation = StubTranslationStage(ensureReady: .success(()), translateResult: "unused")
        let engine = makeEngine(backend: backend, translation: translation, wake: DetectingWakeStub())
        var minted = ["adm-trim-1", "adm-trim-2"]
        engine.utteranceIdGeneratorForTesting = { minted.removeFirst() }

        var inputs: [IntentRoutingInput] = []
        var unroutable = 0
        var wakeOnly = 0
        engine.onRoutingInput = { inputs.append($0); return true }
        engine.onUnroutable = { unroutable += 1 }
        engine.onWakeOnly = { wakeOnly += 1 }

        let generationBefore = engine.gracePeriodSignalForTesting.currentGeneration()
        let fireDateBefore = engine.gracePeriodSignalForTesting.timerFireDateForTesting
        XCTAssertNotNil(fireDateBefore, "premise: a live window with a scheduled expiry")
        await engine.processUtterance(Array(repeating: Float(0.01), count: 16000))
        // Main-async hop: startOrReset schedules its timer reset off the caller thread, so give
        // any (forbidden) renewal a chance to land before asserting it did not.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(inputs.isEmpty, "the non-content remainder never reaches routing")
        XCTAssertEqual(unroutable, 0, "silently discarded — no error feedback")
        XCTAssertEqual(wakeOnly, 0, "junk after the wake is not a wake confirmation")
        XCTAssertEqual(
            translation.ensureReadyCalls, 0,
            "CLEANUP: the discarded utterance performs NO translation-stage work"
        )
        XCTAssertEqual(
            engine.gracePeriodSignalForTesting.currentGeneration(), generationBefore,
            "CLEANUP: the discard did not OPEN a new window — generation unchanged"
        )
        XCTAssertEqual(
            engine.gracePeriodSignalForTesting.timerFireDateForTesting, fireDateBefore,
            "CLEANUP: the discard did not RENEW the same window — the scheduled expiry is untouched"
        )

        // CLEANUP, part 2: the engine is STILL HEALTHY — the next meaningful capture routes
        // normally on the same instance, with its own admitted identity.
        await engine.processUtterance(Array(repeating: Float(0.01), count: 16000))

        XCTAssertEqual(inputs.count, 1, "the next capture routes after the discard")
        XCTAssertEqual(inputs.first?.routerTranscript, "pause", "only the command remainder routes")
        XCTAssertEqual(inputs.first?.utteranceId, "adm-trim-2", "the next capture has its own admitted identity")
        XCTAssertEqual(wakeOnly, 0, "the follow-up is routable, not wake-only")
    }

    /// PERMITTED WAKE RESET vs EXTRA TEXT-DRIVEN RENEWAL (reviewer eaf401cf): the SERVICE-composed
    /// wake callback (`onWakeWordDetected` → `gracePeriodSignal.onWakeWordDetected()`) is the ONLY
    /// legitimate renewal path around a discarded capture. A wake-positive junk capture fires it
    /// EXACTLY ONCE (new window, one reset); a subsequent WAKE-NEGATIVE junk capture fires nothing
    /// and must leave generation AND the scheduled expiry untouched — the discard itself performs
    /// no renewal. A forbidden in-generation reset (`onCommandRecognized`-style) in the discard
    /// path moves the fire date and is caught by the last assertion.
    func test_aPermittedWakeResetFiresOncePerWakeAndTheDiscardAddsNoFurtherRenewal() async throws {
        final class SwitchableWakeStub: WakeWordDetectorProtocol {
            var detectWake = true
            func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
                detectWake ? .detected(confidence: 0.9, completionSample: 250 * 16)
                           : .notDetected(confidence: 0.1)
            }
            func release() {}
        }
        let wakeStub = SwitchableWakeStub()
        let backend = QueueingAsrBackend(results: [
            // Capture 1: WAKE-POSITIVE, trim leaves a non-content remainder → discarded.
            AsrResult(
                text: "hey auris !!!",
                detectedLanguage: "en",
                tokens: [
                    AsrToken(text: "hey auris", startMs: 0, endMs: 300),
                    AsrToken(text: "!!!", startMs: 400, endMs: 700),
                ]
            ),
            // Capture 2: WAKE-NEGATIVE follow-up with a non-content remainder → discarded too.
            AsrResult(
                text: "!!!",
                detectedLanguage: "en",
                tokens: [AsrToken(text: "!!!", startMs: 0, endMs: 300)]
            ),
        ])
        let translation = StubTranslationStage(ensureReady: .success(()), translateResult: "unused")
        let engine = makeEngine(backend: backend, translation: translation, wake: wakeStub)

        // THE PERMITTED COMPOSITION: exactly what VoiceControlService wires in production.
        var wakeCallbacks = 0
        engine.onWakeWordDetected = { [weak engine] in
            wakeCallbacks += 1
            engine?.gracePeriodSignalForTesting.onWakeWordDetected()
        }
        engine.onRoutingInput = { _ in XCTFail("both captures are non-content and never route"); return true }

        let generationBefore = engine.gracePeriodSignalForTesting.currentGeneration()
        let fireDateBefore = engine.gracePeriodSignalForTesting.timerFireDateForTesting

        wakeStub.detectWake = true
        await engine.processUtterance(Array(repeating: Float(0.01), count: 16000))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let generationAfterWake = engine.gracePeriodSignalForTesting.currentGeneration()
        let fireDateAfterWake = engine.gracePeriodSignalForTesting.timerFireDateForTesting

        XCTAssertEqual(wakeCallbacks, 1, "the wake-positive capture fired the permitted reset EXACTLY ONCE")
        XCTAssertEqual(
            generationAfterWake, generationBefore + 1,
            "the permitted wake reset opens exactly ONE new generation"
        )
        XCTAssertNotNil(fireDateAfterWake)
        XCTAssertGreaterThan(
            fireDateAfterWake!, fireDateBefore!,
            "the permitted wake reset renewed the scheduled expiry"
        )

        // Capture 2: NO wake detection → no permitted callback → NOTHING may renew.
        wakeStub.detectWake = false
        await engine.processUtterance(Array(repeating: Float(0.01), count: 16000))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            wakeCallbacks, 1,
            "a wake-negative capture fires no wake callback"
        )
        XCTAssertEqual(
            engine.gracePeriodSignalForTesting.currentGeneration(), generationAfterWake,
            "the discarded follow-up opened no new window"
        )
        XCTAssertEqual(
            engine.gracePeriodSignalForTesting.timerFireDateForTesting, fireDateAfterWake,
            "EXTRA-RENEWAL GUARD: the discard itself performed no in-generation reset — the scheduled expiry is untouched"
        )
    }

    /// WAKE-POSITIVE trim leaving NOTHING is the wake-only path: the capture confirms the wake
    /// and performs no downstream work at all.
    func test_wakePositiveTrimLeavingNothingIsWakeOnlyWithNoDownstreamWork() async throws {
        let backend = StubAsrBackend(
            result: AsrResult(
                text: "hey auris",
                detectedLanguage: "en",
                tokens: [
                    AsrToken(text: "hey", startMs: 0, endMs: 140),
                    AsrToken(text: " auris", startMs: 150, endMs: 300),
                ]
            ),
            canTranslate: false
        )
        let translation = StubTranslationStage(ensureReady: .success(()), translateResult: "unused")
        let engine = makeEngine(backend: backend, translation: translation, wake: DetectingWakeStub())

        var inputs: [IntentRoutingInput] = []
        var unroutable = 0
        var wakeOnly = 0
        engine.onRoutingInput = { inputs.append($0); return true }
        engine.onUnroutable = { unroutable += 1 }
        engine.onWakeOnly = { wakeOnly += 1 }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 16000))

        XCTAssertEqual(wakeOnly, 1, "an all-in-band wake capture is exactly one wake confirmation")
        XCTAssertTrue(inputs.isEmpty, "no routing input without a command remainder")
        XCTAssertEqual(unroutable, 0)
        XCTAssertEqual(translation.ensureReadyCalls, 0, "no translation work for a wake-only capture")
    }

    /// WAKE-POSITIVE trim reaching routing carries ONLY the command remainder, under the
    /// admitted utterance's identity.
    func test_wakePositiveTrimRoutesOnlyTheCommandRemainderUnderTheAdmittedIdentity() async throws {
        let backend = StubAsrBackend(
            result: AsrResult(
                text: "hey auris pause",
                detectedLanguage: "en",
                tokens: [
                    AsrToken(text: "hey auris", startMs: 0, endMs: 300),
                    AsrToken(text: " pause", startMs: 400, endMs: 700),
                ]
            ),
            canTranslate: false
        )
        let translation = StubTranslationStage(ensureReady: .success(()), translateResult: "unused")
        let engine = makeEngine(backend: backend, translation: translation, wake: DetectingWakeStub())
        engine.utteranceIdGeneratorForTesting = { "adm-trim-3" }

        var inputs: [IntentRoutingInput] = []
        engine.onRoutingInput = { inputs.append($0); return true }
        engine.onWakeOnly = { XCTFail("the command remainder is routable") }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 16000))

        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.routerTranscript, "pause", "only the post-wake remainder routes")
        XCTAssertEqual(inputs.first?.utteranceId, "adm-trim-3", "the admitted identity travels with the trimmed input")
    }

    /// The rejection rule is CONTENT, not LENGTH: short meaningful utterances in several scripts
    /// and any digit survive, while punctuation/whitespace alone do not.
    func test_contentRulePreservesShortMeaningfulUtterancesAcrossScripts() {
        // Includes NUMBERS in the non-decimal categories: "²" (No), "½" (No) and "Ⅻ" (Nl) are
        // Unicode N and must NOT be discarded — only Nd would have been, had the predicate used
        // `CharacterSet.decimalDigits` (reviewer 68afef6f).
        for meaningful in ["yes", "停", "嗯", "3", "ok", "No.", "3分", "بلى", "네", "²", "½", "Ⅻ", "٣", "⑩"] {
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
