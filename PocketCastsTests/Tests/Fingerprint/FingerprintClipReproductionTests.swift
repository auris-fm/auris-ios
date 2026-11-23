import CryptoKit
import XCTest

import Fingerprint

@testable import podcasts

/// Proof that the library bundled in this app produces the values the server's generator is
/// checked against, on the same audio.
///
/// The clips and their expected values are committed beside this file: the simulator runs the
/// real library, so this is a gate rather than evidence. Three clips are checked in (48 kHz
/// stereo, 48 kHz mono, 11.025 kHz mono) — the fractional resampling ratio and the no-resampling
/// case — rather than all five, to keep 7.7 MB out of the repository instead of 14.
///
/// A missing fixture fails rather than skipping: a skip would let a broken path or a dropped
/// resource read as a pass.
final class FingerprintClipReproductionTests: XCTestCase {

    /// The clips committed with this test. 44.1 kHz and 22.05 kHz are omitted: their ratios are
    /// whole numbers, so 48 kHz exercises the harder resampling path.
    private static let clipNames = ["clip-48000hz-2ch", "clip-48000hz-1ch", "clip-11025hz-1ch"]

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

    /// The committed clip fixtures, which must be in the test bundle. A missing resource fails
    /// here rather than skipping, so a dropped resource cannot read as a pass.
    private func fixtureURL(_ name: String, _ extension: String) throws -> URL {
        try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: `extension`, subdirectory: "Fixtures")
                ?? Bundle(for: Self.self).url(forResource: name, withExtension: `extension`),
            "fixture \(name).\(`extension`) is not in the test bundle"
        )
    }

    /// Every value of every window of every clip, position by position.
    ///
    /// Positional and never sorted: the library emits values in time order within a window and
    /// keeps duplicates, and a fingerprint that reordered them would still be "the same set"
    /// while matching nothing.
    func testTheLibraryReproducesEveryFixtureValue() throws {
        var compared = 0
        for name in Self.clipNames {
            let jsonURL = try fixtureURL(name, "json")
            let clip = try JSONDecoder().decode(Clip.self, from: Data(contentsOf: jsonURL))
            let audioURL = try fixtureURL(name, "f32")

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

        // Three clips x five windows x 39 values. Pinned so a run that silently compared less
        // than the whole fixture — or dropped a clip — cannot read as a pass.
        XCTAssertEqual(compared, 585)
    }

    /// The rate and channel count in each clip's name must match what the file actually holds,
    /// or the values below were produced from different audio than the name suggests.
    func testTheFixtureRatesAndChannelsMatchTheirFiles() throws {
        for name in Self.clipNames {
            let clip = try JSONDecoder().decode(Clip.self, from: Data(contentsOf: try fixtureURL(name, "json")))
            let audio = try Data(contentsOf: try fixtureURL(name, "f32"))

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
