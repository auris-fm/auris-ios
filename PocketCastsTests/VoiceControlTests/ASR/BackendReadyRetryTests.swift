import XCTest
@testable import podcasts

/// A failed first preload must not be cached forever: after the backend
/// recovers, a later engine `start()` (gate restart) must re-attempt
/// `ensureReady()` and the next utterance must transcribe.
final class BackendReadyRetryTests: XCTestCase {
    private final class FlakyAsrBackend: AsrBackend {
        var failuresRemaining: Int
        private(set) var ensureReadyCalls = 0
        private let result: AsrResult

        init(failuresRemaining: Int) {
            self.failuresRemaining = failuresRemaining
            self.result = AsrResult(text: "pause", detectedLanguage: "en")
        }

        var requiredModel: ModelSpec {
            ModelSpec(id: "flaky", files: [], targetDir: "flaky")
        }

        var capabilities: AsrCapabilities {
            AsrCapabilities(languages: ["en"], canTranslateToEnglish: false, requiresHardwareAccel: false)
        }

        func ensureReady() async -> Result<Void, Error> {
            ensureReadyCalls += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                return .failure(NSError(domain: "flaky", code: 1))
            }
            return .success(())
        }

        func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult { result }

        func release() {}
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testFailedPreloadIsRetriedOnLaterStart() async {
        let backend = FlakyAsrBackend(failuresRemaining: 1)
        let grace = GracePeriodSignal()
        grace.onCommandRecognized()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: ContinuousWakeStub(),
            gracePeriodSignal: grace
        )
        engine.listeningMode = .continuous

        // First start: preload fails (transient, e.g. download error).
        engine.start()
        await self.waitUntil { backend.ensureReadyCalls >= 1 }

        // Backend recovers; a later gate restart (stop → start) must re-attempt ensureReady.
        engine.stop()
        engine.start()
        await self.waitUntil { backend.ensureReadyCalls >= 2 }

        XCTAssertEqual(backend.ensureReadyCalls, 2, "failed preload must be retried, not cached")
    }

    func testRecoveredBackendTranscribesAfterFailedFirstPreload() async {
        let backend = FlakyAsrBackend(failuresRemaining: 1)
        let grace = GracePeriodSignal()
        grace.onCommandRecognized()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: ContinuousWakeStub(),
            gracePeriodSignal: grace
        )
        engine.listeningMode = .continuous

        engine.start()
        await self.waitUntil { backend.ensureReadyCalls >= 1 }
        engine.stop()
        engine.start()
        await self.waitUntil { backend.ensureReadyCalls >= 2 }

        var transcripts: [String] = []
        engine.onRoutingInput = { transcripts.append($0.routerTranscript) }
        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        XCTAssertEqual(transcripts, ["pause"], "utterance must transcribe once the backend recovered")
    }
}

private final class ContinuousWakeStub: WakeWordDetectorProtocol {
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
        .notDetected(confidence: 0.1)
    }

    func release() {}
}
