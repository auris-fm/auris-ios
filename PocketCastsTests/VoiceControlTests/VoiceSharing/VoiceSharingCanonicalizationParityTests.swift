import CryptoKit
import XCTest
@testable import podcasts

/// Parity controls for RFC 8785 canonicalization, driven by vectors produced by the SERVER's own
/// `canonicalizeJson` (`worker/src/contributions/canonical_json.ts`).
///
/// Why a separate suite: `record_sha256` is computed over canonical text, so a canonicalizer that
/// merely agrees with itself proves nothing about interoperability. Expected values here are
/// recorded VERBATIM from the server implementation (see `serverVectors` provenance) and from the
/// RFC 8785 §3.2.2 / Appendix B literals, so a divergence fails a test rather than sending records
/// the server would reject.
final class VoiceSharingCanonicalizationParityTests: XCTestCase {

    /// `(name, input, expected canonical text)`. Expected text is byte-identical to the server's
    /// `canonicalizeJson` output for the same input.
    private static let serverVectors: [(String, Any, String)] = [
        ("bool-false", ["truncated": false], #"{"truncated":false}"#),
        ("bool-true", ["truncated": true], #"{"truncated":true}"#),
        ("neg-zero", ["x": -0.0], #"{"x":0}"#),
        ("tiny", ["x": 1e-7], #"{"x":1e-7}"#),
        ("tiny-neg", ["x": -1e-7], #"{"x":-1e-7}"#),
        ("exponent", ["x": 1e21], #"{"x":1e+21}"#),
        ("fixed-large", ["x": 1e20], #"{"x":100000000000000000000}"#),
        ("just-below", ["x": 1e-6], #"{"x":0.000001}"#),
        ("int", ["x": 16000], #"{"x":16000}"#),
        ("float", ["x": 1.5], #"{"x":1.5}"#),
        ("tenth", ["x": 0.1], #"{"x":0.1}"#),
        ("sorted", ["b": 1, "a": 2, "A": 3], #"{"A":3,"a":2,"b":1}"#),
        ("empty", [String: Any](), "{}"),
    ]

    func test_matchesServerCanonicalizationVectors() throws {
        for (name, input, expected) in Self.serverVectors {
            let actual = try VoiceSharingRecordBinding.canonicalize(input)
            XCTAssertEqual(actual, expected, "server vector \(name)")
        }
    }

    /// Booleans are `NSNumber`-backed in Swift's JSON model, so a canonicalizer that matches on
    /// `NSNumber` first silently renders `false` as `0`. Every audio block contains `truncated`, so
    /// this is on the normal path, not an edge case.
    func test_booleansAreNotSerializedAsNumbers() throws {
        XCTAssertEqual(try VoiceSharingRecordBinding.canonicalize(["truncated": false]), #"{"truncated":false}"#)
        XCTAssertEqual(try VoiceSharingRecordBinding.canonicalize(["truncated": true]), #"{"truncated":true}"#)
        // The same bus is used when the value arrives from JSON parsing rather than a literal.
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(#"{"truncated":false}"#.utf8), options: [.fragmentsAllowed]) as? [String: Any])
        XCTAssertEqual(try VoiceSharingRecordBinding.canonicalize(parsed), #"{"truncated":false}"#)
    }

    /// RFC 8785 §3.2.2.3 and Appendix B number literals, independent of the server.
    func test_es6NumberRenderingMatchesRFC8785Literals() {
        let cases: [(Double, String)] = [
            (0.0, "0"),
            (-0.0, "0"),
            (1.0, "1"),
            (1.5, "1.5"),
            (16000.0, "16000"),
            (0.1, "0.1"),
            (1e-7, "1e-7"),
            (1e-6, "0.000001"),
            (1e-5, "0.00001"),
            (1e20, "100000000000000000000"),
            (1e21, "1e+21"),
            (1.23e-10, "1.23e-10"),
            (123456789012345678.0, "123456789012345680"),
            (5e-324, "5e-324"),
            (-1.5, "-1.5"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(ES6NumberFormat.canonical(value), expected, "RFC literal \(value)")
        }
        XCTAssertNil(ES6NumberFormat.canonical(.infinity), "non-finite must be refused")
        XCTAssertNil(ES6NumberFormat.canonical(.nan), "non-finite must be refused")
    }

    /// The exact record the REAL Worker intake accepted (helper-evidence/worker-parity/RESULT.txt),
    /// reproduced from the same inputs. The Worker computed `recordSha256` independently, so
    /// agreeing on this value is interoperability evidence rather than self-consistency.
    func test_recordDigestMatchesTheValueTheWorkerIntakeAccepted() throws {
        let audio = Self.clientWav(frames: 1600)
        let record = Self.workerAcceptedRecord(audio: audio)
        let canonical = try VoiceSharingRecordBinding.canonicalize(record)
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(digest, "c636d306e593ee32bebe89d82d84050828ff8b53fdd4a2fcf1277bf25a61648a",
                       "must equal the Worker's own recordSha256 for this record")
        XCTAssertEqual(SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined(),
                       "2976da01e205a110c9fa41d47659e238a5c6d3c3f3137582f2949853faa201dd",
                       "must equal the Worker's reported audio sha256")
    }

    /// The Worker's intake refused this record until a completed ASR stage carried its text. A
    /// completed stage with no text is an empty transcript presented as success.
    func test_completedAsrStageWithoutTextIsRejected() throws {
        let audio = Self.clientWav(frames: 1600)
        var record = Self.workerAcceptedRecord(audio: audio)
        var observations = try XCTUnwrap(record["observations"] as? [String: Any])
        observations["asr"] = ["state": "completed"]
        record["observations"] = observations

        let canonical = try VoiceSharingRecordBinding.canonicalize(record)
        let envelope: [String: Any] = [
            "record": record,
            "record_sha256": SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined(),
        ]
        let metadata = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        XCTAssertThrowsError(try VoiceSharingRecordBinding.bind(envelope: metadata, audio: audio)) { error in
            guard case VoiceSharingRecordBinding.BindingError.missingField = error else {
                return XCTFail("expected missingField for asr.text, got \(error)")
            }
        }
    }

    static func clientWav(frames: Int) -> Data {
        let dataBytes = frames * 2
        var data = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        data.append(Data(repeating: 0, count: dataBytes))
        return data
    }

    static func workerAcceptedRecord(audio: Data) -> [String: Any] {
        let audioDigest = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        return [
            "schema_version": 1,
            "capture_id": "11111111-2222-3333-4444-555555555555",
            "enrollment_epoch": "epoch-1",
            "platform": "ios", "app_version": "8.0", "build": "1",
            "capture_session_id": "session-1",
            "audio": [
                "sha256": audioDigest, "byte_count": audio.count, "encoding": "pcm_s16le",
                "sample_rate_hz": 16_000, "channels": 1, "retained_samples": 1600,
                "original_format": "pcm_s16le", "conversion_version": "1",
                "truncated": false, "dropped_spans": [],
            ],
            "models": [
                "vad": NSNull(), "wakeword": ["id": "porcupine", "version": "3.0"],
                "asr": ["id": "sensevoice", "version": "1"], "translation": NSNull(),
                "router": ["id": "lfm2", "version": "1"],
            ],
            "observations": [
                "wake": ["state": "completed"],
                "bleed": ["state": "not_run", "reason": "no_playback_reference"],
                "asr": ["state": "completed", "text": "play the next episode"],
                "translation": ["state": "not_run", "reason": "no_text"],
                "routing": ["state": "completed"],
                "execution": ["state": "not_run", "reason": "precondition_failed"],
            ],
        ]
    }

    /// RFC 8785 §3.2.3 sorts by UTF-16 code units, which is NOT locale-aware string ordering: an
    /// uppercase key precedes the lowercase one, and a prefix precedes its extension.
    func test_keysSortByUTF16CodeUnits() throws {
        let input: [String: Any] = ["b": 1, "a": 2, "A": 3, "ab": 4, "": 5]
        XCTAssertEqual(try VoiceSharingRecordBinding.canonicalize(input), #"{"":5,"A":3,"a":2,"ab":4,"b":1}"#)
    }

    /// An escaped member name is the SAME name: `"a"` and `"\u0061"` must collide, otherwise a
    /// payload can carry two values for one field past the duplicate scanner.
    func test_escapedDuplicateKeysAreDetected() {
        let duplicated = #"{"a":1,"\u0061":2}"#
        XCTAssertThrowsError(try VoiceSharingRecordBinding.parseRefusingDuplicates(Data(duplicated.utf8))) { error in
            guard case VoiceSharingRecordBinding.BindingError.duplicateKey = error else {
                return XCTFail("expected duplicateKey, got \(error)")
            }
        }
    }

    func test_distinctEscapedNamesAreNotCollapsed() throws {
        // "\n" is a different name from "n"; decoding must not over-count collisions.
        let distinct = #"{"n":1,"\n":2}"#
        XCTAssertNoThrow(try VoiceSharingRecordBinding.parseRefusingDuplicates(Data(distinct.utf8)))
    }
}