@testable import podcasts
import XCTest

/// CONTROLS FOR THE PRESENT-BUT-UNLOADABLE MODEL CASE (PR55 Claude review, SpeechFrameClassifier).
///
/// WHY. `SileroSpeechFrameClassifier.make(modelPath:)` checked only that the model FILE exists.
/// Existence is not loadability: a truncated, corrupted, or wrong-architecture `.onnx` passes the
/// check and then reaches `SherpaOnnxCreateVoiceActivityDetector`, whose wrapper `fatalError`s on
/// a NULL result. That killed the app AT LAUNCH — the worst possible moment for a voice feature
/// to crash — instead of reporting classifier unavailability, which the segmenter already knows
/// how to surface (`reportClassifierUnavailable`).
///
/// These controls pin the contract: a model that exists but cannot load yields `nil`, exactly
/// like a missing model, so the one production unavailable-state path handles both.
final class SileroModelLoadFailureControl: XCTestCase {
    /// Writes junk bytes where a valid Silero ONNX model should be and requires `make` to report
    /// unavailability (nil) rather than crash. Before the fix this test did not fail — it
    /// TERMINATED the test runner, which is the launch crash in miniature.
    func testAPresentButUnloadableModelReturnsNilInsteadOfCrashing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vad-unloadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("silero_vad.onnx").path
        // Passes `FileManager.fileExists`, fails every ONNX load: not a zip container, no
        // protobuf headers — exactly what a truncated or stale bundled file looks like.
        try Data("definitely not an onnx protobuf model".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertNil(
            SileroSpeechFrameClassifier.make(modelPath: path),
            "a model that exists but cannot load must report unavailability (nil), not crash the process"
        )
    }

    /// The missing-file case must keep its existing nil contract — the fix must not narrow what
    /// already degrades safely, because the assembly turns a nil classifier into the surfaced
    /// unavailable state (`VoiceControlAssembly` → `reportClassifierUnavailable`).
    func testAMissingModelFileStillReturnsNil() throws {
        XCTAssertNil(
            SileroSpeechFrameClassifier.make(modelPath: "/nonexistent/silero_vad.onnx"),
            "a missing model must keep reporting unavailability (nil)"
        )
    }
}
