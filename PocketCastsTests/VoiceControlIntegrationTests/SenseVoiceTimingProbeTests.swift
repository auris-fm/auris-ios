import XCTest
@testable import podcasts

/// Capability probe (@spec): does the bundled SenseVoice runtime expose token
/// times for the configured asset, and in what units?
///
/// Read-only: points at an existing model copy, loads it through the production
/// backend, and reports what the recognizer returns. It asserts only that the
/// probe ran; the finding is the logged/returned values, not a pass/fail rule.
final class SenseVoiceTimingProbeTests: XCTestCase {
    private let modelDir = "/Users/dev/Library/Developer/CoreSimulator/Devices/DEC0A136-C5D5-41B2-8D4C-D7D8CD3D3060/data/Containers/Data/Application/04E5D98A-88B6-4060-B4EE-E0184AFE3BC8/Library/Application Support/Auris/Models/sensevoice-model"

    /// Loads the real model and transcribes synthetic audio, so the probe covers
    /// "does the runtime accept this artifact" as well as the result shape.
    func test_probe_doesRuntimeLoadAndDoesItExposeTiming() async throws {
        let backend = SenseVoiceBackend(modelDir: modelDir)
        let ready = await backend.ensureReady()
        switch ready {
        case .success:
            print("PROBE load: SUCCESS")
        case .failure(let error):
            print("PROBE load: FAILED \(error)")
            return XCTFail("the bundled runtime must load the verified artifact: \(error)")
        }

        // Real speech, not a tone: "Auris. Skip forward thirty seconds." rendered
        // at 16 kHz mono. A tone returns empty text by design, which says nothing
        // about timings; a recognised utterance is what can carry tokens.
        guard let url = Bundle(for: type(of: self)).url(forResource: "probe16", withExtension: "wav"),
              let data = try? Data(contentsOf: url) else {
            return XCTFail("probe audio missing from the test bundle")
        }
        let samples = Self.pcm16ToFloat(Array(data.dropFirst(44)))
        let result = await backend.transcribe(samples: samples, sampleRateHz: 16000)
        print("PROBE text: '\(result.text)' lang=\(result.detectedLanguage ?? "nil")")
        print("PROBE tokens: \(result.tokens == nil ? "NIL" : "\(result.tokens!.count) entries")")
        if let tokens = result.tokens {
            print("PROBE first: \(tokens.first.map { "\($0.text) [\($0.startMs)-\($0.endMs)]" } ?? "-")")
            print("PROBE last:  \(tokens.last.map { "\($0.text) [\($0.startMs)-\($0.endMs)]" } ?? "-")")
        }
    }

    /// Little-endian 16-bit PCM → `[Float]` in [-1, 1], which is what the
    /// backend takes.
    private static func pcm16ToFloat(_ bytes: [UInt8]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let value = Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
            out.append(Float(value) / 32768.0)
            i += 2
        }
        return out
    }
}
