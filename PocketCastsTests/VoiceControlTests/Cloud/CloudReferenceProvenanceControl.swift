import XCTest
import AVFoundation
import PocketCastsDataModel
@testable import PocketCastsUtils
@testable import podcasts

/// CLOUD-REFERENCE PROVENANCE CONTROL (PR 62 × PR 88).
///
/// When the Pocket Casts transcript-sync object is missing (403) and the Auris
/// cloud reference builds the context, the playback snapshot must carry the
/// AURIS reference's `reference_asset_version` together with a mapped
/// `reference_position_ms` — the version of the bytes the position was actually
/// derived from, never the absent Pocket Casts object's.
final class CloudReferenceProvenanceControl: XCTestCase {

    private static let episodeDuration: Double = 45

    private let featureFlags = FeatureFlagMock()
    private var manager: FingerprintTimingManager!
    private var fixture: FingerprintEpisodeFixture!
    private var currentEpisode: CurrentEpisodeOverride!
    private var previousBaseURL: Any?
    private var previousDirectUpstream: Any?

    /// Own fetcher with a static bearer: the gateway is URLProtocol-stubbed, so
    /// a fixed literal exercises exactly the request path under test without
    /// touching the shared singleton or the keychain-backed Auris chain.
    private final class StubTokenProvider: CloudTokenProviding {
        func token() async -> String? { "provenance-test-token" }
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    private lazy var stubbedFetcher = CloudFingerprintReferenceFetcher(tokenProvider: StubTokenProvider())

    override func setUpWithError() throws {
        try super.setUpWithError()
        featureFlags.set(.syncedTranscripts, value: true)

        previousBaseURL = UserDefaults.standard.object(forKey: CloudConfig.baseURLKey)
        previousDirectUpstream = UserDefaults.standard.object(forKey: CloudConfig.directUpstreamKey)
        UserDefaults.standard.set("https://gateway.provenance.test", forKey: CloudConfig.baseURLKey)
        UserDefaults.standard.set(false, forKey: CloudConfig.directUpstreamKey)

        URLProtocol.registerClass(CloudRouteTestURLProtocol.self)
        CloudRouteTestURLProtocol.reset()
    }

    override func tearDown() {
        manager?.stop()
        manager = nil
        currentEpisode?.restore()
        currentEpisode = nil
        fixture?.removeFiles()
        fixture = nil

        CloudRouteTestURLProtocol.reset()
        URLProtocol.unregisterClass(CloudRouteTestURLProtocol.self)

        if let previousBaseURL {
            UserDefaults.standard.set(previousBaseURL, forKey: CloudConfig.baseURLKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CloudConfig.baseURLKey)
        }
        if let previousDirectUpstream {
            UserDefaults.standard.set(previousDirectUpstream, forKey: CloudConfig.directUpstreamKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CloudConfig.directUpstreamKey)
        }
        featureFlags.reset()
        super.tearDown()
    }

    func test_cloudBuiltSnapshotCarriesTheAurisVersionWithItsMappedPosition() async throws {
        let fixture = FingerprintEpisodeFixture(duration: Self.episodeDuration)
        self.fixture = fixture
        try fixture.writeAudio(seconds: Self.episodeDuration)
        currentEpisode = CurrentEpisodeOverride(episode: fixture.episode)
        manager = FingerprintTimingManager(cloudFetcher: stubbedFetcher)

        // The Auris reference, built from this exact audio with the Go scheme.
        let cloudPayload = try Self.makeCloudReference(forAudioAt: fixture.audioURL)
        let aurisVersion = FingerprintMappingCache.referenceAssetVersion(of: cloudPayload)

        // Pocket Casts' object is missing; the Auris gateway serves the payload.
        CloudRouteTestURLProtocol.requestHandler = { request in
            if request.url?.host == "gateway.provenance.test" {
                return .complete(status: 200, headers: ["Content-Type": "application/json"], body: cloudPayload)
            }
            return .complete(status: 403, headers: [:], body: Data())
        }

        manager.prepareForCurrentEpisode()
        await waitForPass(manager)
        guard case .active = manager.state else {
            XCTFail("expected .active from the Auris reference alone, got \(manager.state)")
            return
        }

        // The production snapshot shape: the same provider the assembly wires,
        // reading the real manager's atomic position+version+episode.
        let provider = DefaultPlaybackContextProvider(
            playbackState: PlaybackManager.shared,
            fingerprintMapper: manager,
            cloudPlaybackContextState: CloudPlaybackContextState()
        )
        let context = try XCTUnwrap(provider.current(), "a playing episode must produce a snapshot")

        XCTAssertEqual(context.episodeId, fixture.episode.uuid)
        let positionMs = try XCTUnwrap(
            context.referencePositionMs,
            "the cloud-built map must serve a mapped reference position"
        )
        XCTAssertGreaterThanOrEqual(positionMs, 0)
        XCTAssertEqual(
            context.referenceAssetVersion, aurisVersion,
            "the snapshot carries the digest of the exact Auris bytes the position was mapped under"
        )
    }

    /// Builds a `fingerprint-compact-v2` payload with Go-scheme hashes from the
    /// episode's own audio — the same scheme the server's reference uses.
    private static func makeCloudReference(forAudioAt url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let fingerprinter = CloudFingerprinter()
        let chunkFrames = AVAudioFrameCount(format.sampleRate * 5)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw NSError(domain: "CloudReferenceProvenanceControl", code: 1)
        }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunkFrames)
            if buffer.frameLength == 0 { break }
            guard let channel = buffer.floatChannelData?[0] else { break }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            fingerprinter.pushSamples(samples, channels: Int(format.channelCount), sampleRate: Int(format.sampleRate))
        }
        let windows = fingerprinter.finish()

        var checkpoints: [String] = []
        var previousSecond = 0
        for window in windows {
            // One checkpoint per second, matching the server's grid.
            guard checkpoints.isEmpty || window.timestampSec > previousSecond else { continue }
            var bytes = Data(capacity: window.hashes.count * 4)
            for hash in window.hashes {
                var littleEndian = hash.littleEndian
                withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
            }
            let delta = window.timestampSec - previousSecond
            checkpoints.append("[\(delta), \"\(bytes.base64EncodedString())\"]")
            previousSecond = window.timestampSec
        }
        let json = """
        {
          "format": "fingerprint-compact-v2",
          "total_duration": \(Double(file.length) / format.sampleRate),
          "checkpoint_interval": 1,
          "checkpoint_duration": 8,
          "timestamp_quantum": 1,
          "checkpoints": [\(checkpoints.joined(separator: ","))]
        }
        """
        return Data(json.utf8)
    }
}
