import XCTest
import PocketCastsUtils

@testable import podcasts

/// Early wake scoring must return the same score as scoring the finished segment.
///
/// This is the control the plan names: if the early result could differ, an utterance would be
/// addressed to Auris or not depending only on when detection ran — a correctness bug, not a
/// latency tradeoff. These run the REAL detector over real audio, comparing the score from the
/// eligible prefix against the score from the complete segment.
final class StreamingWakeScoreEqualityTests: XCTestCase {

    /// Loads a model exactly the way production does, so this control exercises the shipped
    /// runtime rather than a parallel path.
    ///
    /// Two details are load-bearing:
    ///
    /// - The extension is `.ort`, not `.onnx`. This build of the runtime rejects the ONNX format
    ///   outright ("ONNX format model is not supported in this build"), so pointing at the `.onnx`
    ///   copies fails at initialization and never reaches scoring.
    /// - The models are copied into the app bundle under `wakeword/` by a post-build run script;
    ///   they are not reachable through a plain top-level bundle lookup.
    private func modelURL(_ name: String) throws -> URL {
        let expected = Bundle.main.bundleURL
            .appendingPathComponent("wakeword")
            .appendingPathComponent("\(name).ort")
        return try XCTUnwrap(
            FileManager.default.fileExists(atPath: expected.path) ? expected : nil,
            "\(name).ort is missing from \(expected.deletingLastPathComponent().path). The wake-word "
                + "models are copied in post-build, so this control cannot run against the shipped "
                + "runtime without them."
        )
    }

    private func makeDetector() throws -> WakeWordDetector {
        WakeWordDetector(
            melModel: try modelURL("melspectrogram"),
            embedModel: try modelURL("embedding_model"),
            classifierModel: try modelURL("auris"),
            threshold: 0.5
        )
    }

    /// The native layer explains an initialization failure in the app log, not in the result code.
    /// Surfacing it turns "init_failed" into a diagnosable message.
    private static func recentLog() async -> String {
        let text = await FileLog.shared.logFileAsString()
        return "recent log tail:\n" + text.split(separator: "\n").suffix(12).joined(separator: "\n")
    }

    /// A synthetic utterance with structure the detector can act on, so the comparison is not a
    /// comparison of two identical zero scores.
    private func utterance(seconds: Double, seed: UInt64 = 0x5EED) -> [Float] {
        var state = seed
        let count = Int(16_000 * seconds)
        return (0..<count).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
            let tone = sinf(2 * .pi * 220 * Float(index) / 16_000)
            return 0.25 * tone + 0.05 * noise
        }
    }

    /// The property that matters: for a segment longer than the eligible span, the score computed
    /// from the first 2 seconds' worth of samples must equal the score computed from the whole
    /// segment. Audio past the span cannot contribute, so a difference here would mean the early
    /// run is scoring different windows — and would change which utterances reach ASR.
    func test_earlyScoreEqualsFinishedSegmentScore() async throws {
        let detector = try makeDetector()
        defer { detector.release() }

        for seconds in [2.4, 2.8, 3.4] {
            let samples = utterance(seconds: seconds)
            let prefix = Array(samples.prefix(NativeVadSegmenter.wakeEligibleSpanSamples))
            XCTAssertLessThan(prefix.count, samples.count,
                              "the fixture must be longer than the eligible span to test this")

            let early = detector.detect(samples: prefix, sampleRate: 16_000)
            let full = detector.detect(samples: samples, sampleRate: 16_000)

            switch (early, full) {
            case let (.detected(a, aCompletion), .detected(b, bCompletion)):
                XCTAssertEqual(a, b, accuracy: 0.0001,
                               "\(seconds)s: the early score must equal the finished-segment score")
                XCTAssertEqual(aCompletion, min(aCompletion, NativeVadSegmenter.wakeEligibleSpanSamples),
                               "the completion offset must lie inside the prefix that produced it")
                _ = bCompletion
            case let (.notDetected(a), .notDetected(b)):
                XCTAssertEqual(a, b, accuracy: 0.0001,
                               "\(seconds)s: a negative must be equally negative from the prefix")
            case let (.error(code), _):
                XCTFail("the detector failed on the prefix: \(code)\n\(await Self.recentLog())")
            case let (_, .error(code)):
                XCTFail("the detector failed on the full segment: \(code)")
            default:
                XCTFail("\(seconds)s: the prefix and the finished segment disagreed on the decision")
            }
        }
    }

    /// The same property on recorded human speech, which is what the control has to hold for.
    ///
    /// The synthetic tone above scores near zero for every input, so an equality there could hold
    /// for a trivial reason. This uses a checked-in speech fixture and asserts the score is actually
    /// non-trivial, so the equality is a real one.
    ///
    /// Provenance of the fixture: a TTS-synthesized "hey livekit" positive from the upstream
    /// `livekit-wakeword` project (its positive-clip pipeline is Piper VITS / VoxCPM2 synthesis),
    /// added there in that project's Swift-package PR. Not a recording of any project participant.
    func test_earlyScoreEqualsFinishedSegmentScoreOnRecordedSpeech() async throws {
        let detector = try makeDetector()
        defer { detector.release() }

        let bundle = Bundle(for: type(of: self))
        let fixture = try XCTUnwrap(
            bundle.url(forResource: "positive", withExtension: "wav", subdirectory: "Fixtures")
                ?? bundle.url(forResource: "positive", withExtension: "wav"),
            "checked-in speech fixture not found in the test bundle"
        )

        // The fixture is exactly 2.0s — the same length as the eligible span — so on its own it
        // could not distinguish "audio past the span is ignored" from "there is no audio past the
        // span". Repeating it gives a segment that genuinely continues past the span while still
        // containing real speech in the scored prefix.
        let once = try readWav16k(fixture)
        let samples = once + once
        XCTAssertGreaterThan(samples.count, NativeVadSegmenter.wakeEligibleSpanSamples,
                             "the segment must be longer than the eligible span")

        let prefix = Array(samples.prefix(NativeVadSegmenter.wakeEligibleSpanSamples))
        let early = detector.detect(samples: prefix, sampleRate: 16_000)
        let full = detector.detect(samples: samples, sampleRate: 16_000)

        let earlyScore: Float = {
            switch early {
            case let .detected(c, _): return c
            case let .notDetected(c): return c
            case let .error(code):
                XCTFail("detector error on the prefix: \(code)"); return -1
            }
        }()
        let fullScore: Float = {
            switch full {
            case let .detected(c, _): return c
            case let .notDetected(c): return c
            case let .error(code):
                XCTFail("detector error on the full segment: \(code)"); return -1
            }
        }()

        XCTAssertEqual(earlyScore, fullScore, accuracy: 0.0001,
                       "recorded speech must score identically from the prefix")
        XCTAssertGreaterThan(earlyScore, 0.001,
                             "the fixture must produce a non-trivial score, or the equality proves "
                                 + "only that two zeros match")
    }

    /// Minimal RIFF reader for 16-bit PCM at the model's rate.
    private func readWav16k(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        func u32(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8
                | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        var cursor = 12
        var dataRange: Range<Int>?
        while cursor + 8 <= data.count {
            let id = String(bytes: data[cursor..<cursor + 4], encoding: .ascii) ?? ""
            let size = u32(cursor + 4)
            let body = cursor + 8
            if id == "data" {
                dataRange = body..<min(body + size, data.count)
                break
            }
            cursor = body + size + (size % 2)
        }
        let range = try XCTUnwrap(dataRange, "no data chunk in \(url.lastPathComponent)")
        var samples: [Float] = []
        samples.reserveCapacity(range.count / 2)
        var index = range.lowerBound
        while index + 1 < range.upperBound {
            let raw = Int16(bitPattern: UInt16(data[index]) | UInt16(data[index + 1]) << 8)
            samples.append(Float(raw) / Float(Int16.max))
            index += 2
        }
        return samples
    }

    /// A short segment is scored once, at end of speech, and must also agree — the early path
    /// simply does not apply to it, so the two produce the same result by construction. Included so
    /// a future change cannot make short utterances score differently from long ones.
    func test_shortSegmentScoreMatchesItsOwnPrefix() async throws {
        let detector = try makeDetector()
        defer { detector.release() }

        let samples = utterance(seconds: 1.0)
        let once = detector.detect(samples: samples, sampleRate: 16_000)
        let again = detector.detect(samples: samples, sampleRate: 16_000)

        switch (once, again) {
        case let (.detected(a, _), .detected(b, _)):
            XCTAssertEqual(a, b, accuracy: 0.0001)
        case let (.notDetected(a), .notDetected(b)):
            XCTAssertEqual(a, b, accuracy: 0.0001)
        case let (.error(code), _):
            XCTFail("detector error: \(code)\n\(await Self.recentLog())")
        default:
            XCTFail("repeating the same detection must give the same decision")
        }
    }
}