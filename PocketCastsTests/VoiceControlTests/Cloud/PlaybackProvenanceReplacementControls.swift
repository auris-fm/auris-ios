import Foundation
import XCTest

@testable import PocketCastsDataModel
@testable import PocketCastsUtils
@testable import podcasts

/// TASK 90 PROVENANCE — REAL-MANAGER replacement/reset controls (review d815be4a #3;
/// spec 351dd308). The provider-seam doubles prove the call shape; these controls drive the
/// REAL `FingerprintTimingManager` over real reference bytes through two distinct maps and a
/// reset, asserting the version is replaced and cleared WITH the map it describes.
final class PlaybackProvenanceReplacementControls: XCTestCase {

    private static let episodeDuration: Double = 45

    private var featureFlags = FeatureFlagMock()
    private var fixture: FingerprintEpisodeFixture?
    private var currentEpisode: CurrentEpisodeOverride?
    private var manager: FingerprintTimingManager?
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        featureFlags.set(.syncedTranscripts, value: true)
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PlaybackProvenanceControls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        manager?.stop()
        manager = nil
        currentEpisode?.restore()
        currentEpisode = nil
        fixture?.removeFiles()
        fixture = nil
        try? FileManager.default.removeItem(at: directory)
        featureFlags.reset()
        super.tearDown()
    }

    /// THE PROPERTY: the reference version is read atomically with the position AND replaced
    /// with the map. Map V1 (reference R1) serves V1; a RESET drops both map and version; a
    /// replacement map (reference R2, different bytes → different version) serves V2 — never
    /// a mixture, and always for the prepared episode.
    func test_realManager_versionIsReplacedAndClearedWithItsMap() async throws {
        // Fixture episode + its own audio; R1 = reference derived from that audio.
        let fixture = FingerprintEpisodeFixture(duration: Self.episodeDuration)
        self.fixture = fixture
        try fixture.writeAudio(seconds: Self.episodeDuration)
        try fixture.writeReference()
        currentEpisode = CurrentEpisodeOverride(episode: fixture.episode)
        let manager = FingerprintTimingManager()
        self.manager = manager

        let referenceData1 = try Data(contentsOf: fixture.referenceURL)
        let version1 = FingerprintMappingCache.referenceAssetVersion(of: referenceData1)

        manager.prepareForCurrentEpisode()
        await waitForPass(manager)
        guard case .active = manager.state else {
            XCTFail("expected .active after first pass, got \(manager.state)")
            return
        }

        let midpoint = Self.episodeDuration / 2
        let first = try XCTUnwrap(
            manager.matchedReferenceContext(forPlaybackTime: midpoint),
            "an active map must serve position+version+episode"
        )
        XCTAssertEqual(first.episodeUuid, fixture.episode.uuid, "the map names its episode")
        XCTAssertEqual(first.referenceAssetVersion, version1,
                       "the served version is the digest of the exact reference bytes R1")

        // RESET: stop() tears the map down. Both the map AND its version are gone — no read
        // can serve a position (or a version) from a torn-down map.
        manager.stop()
        // Let the first pass's streaming task fully drain before touching files it reads.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertNil(manager.matchedReferenceContext(forPlaybackTime: midpoint),
                     "after reset neither position nor version is served")

        // REPLACEMENT: a DIFFERENT reference (different bytes → different version), same
        // episode. The new map serves V2 — never V1, and never a mixed pair. A fresh
        // manager mirrors the real episode-replacement lifecycle (old manager stopped,
        // new one prepares).
        // Different bytes that still map: the same content with a 2 s leading gap —
        // a genuinely different reference (new digest) whose map shifts positions by 2 s.
        let gapFrames = Int(FingerprintFixtures.frameCount(forSeconds: 2))
        let replacementAudio = directory.appendingPathComponent("replacement.wav")
        try FingerprintFixtures.writeAudio(
            [Float](repeating: 0, count: gapFrames)
                + FingerprintFixtures.samples(seconds: Self.episodeDuration),
            to: replacementAudio
        )
        try FingerprintFixtures.makeReference(forAudioAt: replacementAudio).write(to: fixture.referenceURL)
        try? FileManager.default.removeItem(atPath: fixture.mappingCachePath)

        let referenceData2 = try Data(contentsOf: fixture.referenceURL)
        let version2 = FingerprintMappingCache.referenceAssetVersion(of: referenceData2)
        XCTAssertNotEqual(version1, version2, "the replacement reference is genuinely different bytes")

        let replacementManager = FingerprintTimingManager()
        self.manager = replacementManager
        replacementManager.prepareForCurrentEpisode()
        await waitForPass(replacementManager)
        guard case .active = replacementManager.state else {
            XCTFail("expected .active after replacement pass, got \(replacementManager.state)")
            return
        }

        let second = try XCTUnwrap(
            replacementManager.matchedReferenceContext(forPlaybackTime: midpoint),
            "the replacement map must serve position+version+episode"
        )
        XCTAssertEqual(second.episodeUuid, fixture.episode.uuid)
        XCTAssertEqual(second.referenceAssetVersion, version2,
                       "the replacement map serves ITS OWN reference version")
        XCTAssertNotEqual(second.referenceAssetVersion, version1,
                          "an old version never survives a map replacement")
    }
}
