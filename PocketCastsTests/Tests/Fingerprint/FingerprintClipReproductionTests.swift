import CryptoKit
import XCTest

import Fingerprint

@testable import podcasts

/// Proof that the library bundled in this app produces the values the server's generator is
/// checked against, on the same audio.
///
/// The five clips and their expected values live in `core`'s
/// `chroma-generator/server/internal/fingerprint/testdata/fixtures/`. They are ~14 MB of raw
/// audio, so they are not committed here: point `AURIS_FINGERPRINT_FIXTURES` at that directory
/// to run this, and it skips with a message otherwise. The server commits them because its CI
/// must run the equivalent assertion; on iOS the library runs on the device, so this is
/// evidence for a change rather than a gate CI can fail on.
///
/// A skip is not a pass. If the directory is set but a clip is missing or malformed, the case
/// fails rather than skipping, so a broken path cannot be mistaken for absent fixtures.
final class FingerprintClipReproductionTests: XCTestCase {

    private static let fixturesEnvVar = "AURIS_FINGERPRINT_FIXTURES"

    private struct Clip: Decodable {
        struct Window: Decodable {
            let timestampMs: Int
            let values: [UInt32]

            private enum CodingKeys: String, CodingKey {
                case timestampMs = "timestamp_ms"
                case values
            }
        }

        let audio: String
        let audioSha256: String
        let sampleRate: Int
        let channels: Int
        let frames: Int
        let windows: [Window]

        private enum CodingKeys: String, CodingKey {
            case audio
            case audioSha256 = "audio_sha256"
            case sampleRate = "sample_rate"
            case channels
            case frames
            case windows
        }
    }

    private func fixtureDirectory() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment[Self.fixturesEnvVar], !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        // The variable was set deliberately, so a wrong path is a failure, not a skip.
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue,
            "\(Self.fixturesEnvVar) is set to \(path), which is not a directory"
        )
        return url
    }

    /// Every value of every window of every clip, position by position.
    ///
    /// Positional and never sorted: the library emits values in time order within a window and
    /// keeps duplicates, and a fingerprint that reordered them would still be "the same set"
    /// while matching nothing.
    func testTheLibraryReproducesEveryFixtureValue() throws {
        guard let directory = try fixtureDirectory() else {
            throw XCTSkip(
                "set \(Self.fixturesEnvVar) to core's server/internal/fingerprint/testdata/fixtures "
                    + "to run; 14 MB of audio is not committed to this repo"
            )
        }

        let clipURLs = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("clip-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertEqual(clipURLs.count, 5, "expected the five clip fixtures in \(directory.path)")

        var compared = 0
        for jsonURL in clipURLs {
            let clip = try JSONDecoder().decode(Clip.self, from: Data(contentsOf: jsonURL))
            let audioURL = directory.appendingPathComponent(clip.audio)

            let audio = try Data(contentsOf: audioURL)
            XCTAssertEqual(
                sha256(audio),
                clip.audioSha256,
                "\(clip.audio): the staged audio is not the audio these values were recorded from"
            )

            let windows = try fingerprint(audio, clip: clip)
            XCTAssertEqual(windows.count, clip.windows.count, "\(clip.audio): window count")

            for (index, expected) in clip.windows.enumerated() {
                guard index < windows.count else { break }
                XCTAssertEqual(
                    windows[index].timestampMs, expected.timestampMs,
                    "\(clip.audio) window \(index): timestamp"
                )
                // Reported as a length first, so a truncation reads as one rather than as a
                // long list of shifted values.
                XCTAssertEqual(
                    windows[index].values.count, expected.values.count,
                    "\(clip.audio) window \(index): value count"
                )
                let shared = zip(windows[index].values, expected.values)
                let mismatched = shared.enumerated().filter { $0.element.0 != $0.element.1 }
                XCTAssertTrue(
                    mismatched.isEmpty,
                    "\(clip.audio) window \(index): "
                        + mismatched.prefix(5).map { "position \($0.offset): \($0.element.0) vs \($0.element.1)" }
                        .joined(separator: "; ")
                )
                compared += min(windows[index].values.count, expected.values.count)
            }
        }

        // The count the server's generator is held to. Pinned so a run that silently compared
        // far less than the whole fixture cannot read as a pass.
        XCTAssertEqual(compared, 975)
    }

    /// The rate and channel count in each clip's name must match what the file actually holds,
    /// or the values below were produced from different audio than the name suggests.
    func testTheFixtureRatesAndChannelsMatchTheirFiles() throws {
        guard let directory = try fixtureDirectory() else {
            throw XCTSkip("set \(Self.fixturesEnvVar) to run")
        }

        for jsonURL in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where jsonURL.lastPathComponent.hasPrefix("clip-") && jsonURL.pathExtension == "json" {
            let clip = try JSONDecoder().decode(Clip.self, from: Data(contentsOf: jsonURL))
            let audio = try Data(contentsOf: directory.appendingPathComponent(clip.audio))

            // Raw interleaved little-endian float32, no header.
            let frameBytes = 4 * clip.channels
            XCTAssertEqual(
                audio.count, clip.frames * frameBytes,
                "\(clip.audio): \(audio.count) bytes is not \(clip.frames) frames of \(clip.channels)ch float32"
            )
            XCTAssertTrue(
                clip.audio.contains("\(clip.sampleRate)hz") && clip.audio.contains("\(clip.channels)ch"),
                "\(clip.audio): name does not describe \(clip.sampleRate)Hz \(clip.channels)ch"
            )
        }
    }

    // MARK: - Fingerprinting

    /// Runs a clip through the same streaming fingerprinter the app uses, in the same one-shot
    /// shape the fixture README records.
    private func fingerprint(_ audio: Data, clip: Clip) throws -> [(timestampMs: Int, values: [UInt32])] {
        let samples = audio.withUnsafeBytes { raw -> [Float] in
            let count = raw.count / 4
            return raw.bindMemory(to: UInt32.self).prefix(count).map { Float(bitPattern: UInt32(littleEndian: $0)) }
        }

        let streamer = StreamingWindowedFingerprinter(
            sampleRate: UInt32(clip.sampleRate),
            channels: UInt16(clip.channels),
            windowDurationMs: FingerprintConstants.windowDurationMs,
            windowIntervalMs: FingerprintConstants.windowIntervalMs
        )
        var windows = streamer.pushSamplesF32(samples: samples, channels: UInt16(clip.channels))
        windows.append(contentsOf: streamer.flush())

        return windows.map { window in
            (timestampMs: Int(window.timestampMs), values: window.hashes)
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
