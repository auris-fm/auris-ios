import AVFoundation
import XCTest

@testable import PocketCastsUtils
@testable import podcasts

/// Preparation when the Pocket Casts transcript-sync reference is missing but
/// the Auris cloud reference exists. The two references are independent: a
/// missing Pocket Casts object must not disable the cloud alignment path.
///
/// Real audio, real fingerprinters, real drift filter — only the two reference
/// hosts are stubbed. The Auris reference is built from the episode's own audio
/// with the Go-scheme `CloudFingerprinter`, so a correct cloud-only pass maps
/// every anchor onto its own timestamp.
@MainActor
final class CloudReferenceDecouplingTests: XCTestCase {

    /// Long enough for the drift filter to bootstrap (three consecutive
    /// in-trend candidates) and commit anchors across the file.
    private static let episodeDuration: Double = 45

    private let featureFlags = FeatureFlagMock()
    private var manager: FingerprintTimingManager!
    private var fixture: FingerprintEpisodeFixture!
    private var currentEpisode: CurrentEpisodeOverride!
    private var defaultsSuite: String!
    private var previousBaseURL: Any?
    private var previousDirectUpstream: Any?
    private var cloudPayload: Data!
    /// Own fetcher with a static bearer: the fetcher fails closed without a
    /// token, and the suite's gateway is URLProtocol-stubbed, so a fixed
    /// literal exercises exactly the request path under test — without
    /// touching the shared singleton or the keychain-backed Auris chain.
    private final class StubTokenProvider: CloudTokenProviding {
        func token() async -> String? { "decoupling-test-token" }
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    private lazy var stubbedFetcher = CloudFingerprintReferenceFetcher(tokenProvider: StubTokenProvider())

    override func setUpWithError() throws {
        try super.setUpWithError()
        featureFlags.set(.syncedTranscripts, value: true)

        // Point the production config reader at the stubbed gateway. Saved and
        // restored around each test so no other suite sees the override.
        defaultsSuite = "cloud_decoupling_\(UUID().uuidString)"
        previousBaseURL = UserDefaults.standard.object(forKey: CloudConfig.baseURLKey)
        previousDirectUpstream = UserDefaults.standard.object(forKey: CloudConfig.directUpstreamKey)
        UserDefaults.standard.set("https://gateway.cloud-decoupling.test", forKey: CloudConfig.baseURLKey)
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
        cloudPayload = nil

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
        defaultsSuite = nil

        featureFlags.reset()
        super.tearDown()
    }

    // MARK: - Controls

    /// The defect this suite exists for: Pocket Casts' object is missing (403)
    /// and the Auris reference loads. Preparation must still map the episode
    /// through the cloud matcher instead of ending `.unavailable`.
    func testPreparationMapsThroughTheAurisReferenceWhenPocketCastsIsMissing() async throws {
        try prepareFixture()
        stubHosts(pocketCasts: .complete(status: 403, headers: [:], body: Data()))

        manager.prepareForCurrentEpisode()
        await waitForPass(manager)

        guard case .active(let coverage) = manager.state else {
            XCTFail("expected .active from the Auris reference alone, got \(manager.state)")
            return
        }
        let entries = manager.debugMappingSnapshot()
        XCTAssertEqual(coverage, entries.count)
        XCTAssertGreaterThanOrEqual(entries.count, FingerprintConstants.minimumCoverageForActive)

        // The reference was built from this exact audio with the Go scheme, so
        // anchors map onto their own timestamps.
        for entry in entries {
            XCTAssertEqual(entry.referenceTime, entry.playbackTime, accuracy: 1.0)
        }
        // Probe a committed anchor's neighbourhood, not a fixed timestamp: the
        // drift filter bootstraps a few seconds into the file and the tail
        // window may not commit, so the exact midpoint can legitimately sit
        // outside the matched span on a short fixture.
        let probe = try XCTUnwrap(entries.dropLast().last).playbackTime + 0.5
        XCTAssertTrue(manager.isWithinMatchedContent(forPlaybackTime: probe))
        XCTAssertEqual(try XCTUnwrap(manager.matchedReferenceTime(forPlaybackTime: probe)), probe, accuracy: 1.0)
    }

    /// Both references absent stays `.unavailable` — the fix must not invent
    /// alignment out of nothing.
    func testPreparationStaysUnavailableWhenBothReferencesAreMissing() async throws {
        try prepareFixture()
        stubHosts(pocketCasts: .complete(status: 403, headers: [:], body: Data()))
        CloudRouteTestURLProtocol.requestHandler = { request in
            if request.url?.host == "gateway.cloud-decoupling.test" {
                return .complete(status: 404, headers: [:], body: Data())
            }
            return .complete(status: 403, headers: [:], body: Data())
        }

        manager.prepareForCurrentEpisode()

        await waitUntil("preparation to report unavailable") { self.manager.state.analyticsName == "unavailable" }
        XCTAssertTrue(manager.debugMappingSnapshot().isEmpty)
    }

    /// A later session that starts with the persisted Auris reference on disk
    /// and Pocket Casts still missing reaches `.active` through the cloud
    /// matcher — never through the Rust checkpoint matcher, which must stay
    /// empty because the Auris payload uses the Go hash scheme.
    func testPersistedAurisReferenceOnDiskPreparesWithoutAnyFetch() async throws {
        try prepareFixture()
        // First pass: fetch the Auris reference and let it persist.
        stubHosts(pocketCasts: .complete(status: 403, headers: [:], body: Data()))
        manager.prepareForCurrentEpisode()
        await waitForPass(manager)
        XCTAssertEqual(manager.state.analyticsName, "active")
        manager.stop()
        await waitUntil("the manager to return to idle") { self.manager.state.analyticsName == "idle" }

        // Second session: a fresh manager, both hosts now fail hard. If the
        // persisted Auris file is read, preparation still maps; if the code
        // only knows the Pocket Casts path, this ends `.unavailable`.
        let secondManager = FingerprintTimingManager(cloudFetcher: stubbedFetcher)
        defer { secondManager.stop() }
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .complete(status: 500, headers: [:], body: Data())
        }
        secondManager.prepareForCurrentEpisode()
        await waitForPass(secondManager)

        guard case .active = secondManager.state else {
            XCTFail("expected .active from the persisted Auris reference, got \(secondManager.state)")
            return
        }
        let entries = secondManager.debugMappingSnapshot()
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            XCTAssertEqual(entry.referenceTime, entry.playbackTime, accuracy: 1.0)
        }
    }

    /// The Pocket Casts sibling path stays Pocket Casts-owned: a cloud-built
    /// pass must not write Go-scheme bytes where `loadReference` (and the
    /// one-shot resolves) would parse them as a transcript-sync reference.
    func testCloudBuiltPassLeavesThePocketCastsReferencePathUntouched() async throws {
        try prepareFixture()
        stubHosts(pocketCasts: .complete(status: 403, headers: [:], body: Data()))

        manager.prepareForCurrentEpisode()
        await waitForPass(manager)
        XCTAssertEqual(manager.state.analyticsName, "active")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.referenceURL.path),
            "the cloud pass wrote into the Pocket Casts reference path"
        )
    }

    /// On a cloud-built context the one-shot resolvers must NOT feed the
    /// context's `referenceData` (the Auris payload) to the Rust decoder — the
    /// decode could only fail and fall back to the unaligned time. The
    /// observable pin: the resolve goes to the transcript-sync sources
    /// (network request visible) instead of silently consuming the context.
    func testOneShotResolveOnACloudContextSkipsTheAurisPayload() async throws {
        try prepareFixture()
        stubHosts(pocketCasts: .complete(status: 403, headers: [:], body: Data()))
        manager.prepareForCurrentEpisode()
        await waitForPass(manager)
        XCTAssertEqual(manager.state.analyticsName, "active")

        // Both sources now fail: the resolver must go looking (visible as
        // further gateway traffic) rather than decoding the context payload.
        CloudRouteTestURLProtocol.reset()
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .complete(status: 500, headers: [:], body: Data())
        }
        let before = CloudRouteTestURLProtocol.requestCount
        let result = await manager.resolveBookmarkPlaybackTime(
            forReferenceTime: Self.episodeDuration / 2,
            episode: fixture.episode
        )

        guard case .unresolved = result else {
            XCTFail("expected unresolved from a cloud context with no transcript-sync reference, got \(result)")
            return
        }
        XCTAssertGreaterThan(
            CloudRouteTestURLProtocol.requestCount,
            before,
            "the resolve must consult the transcript-sync sources, not the context's Auris payload"
        )
    }

    /// A decodable Pocket Casts reference with NO usable checkpoints must not
    /// mask the Auris reference: the disk call site falls through to the
    /// persisted cloud reference instead of ending `.unavailable`.
    func testUnusableDiskReferenceFallsThroughToThePersistedAurisReference() async throws {
        try prepareFixture()
        try fixture.writeReference(data: Self.unusableReference())
        try cloudPayload!.write(to: fixture.cloudReferenceURL)
        stubHosts(pocketCasts: .complete(status: 403, headers: [:], body: Data()))

        manager.prepareForCurrentEpisode()
        await waitForPass(manager)

        guard case .active = manager.state else {
            XCTFail("expected .active from the persisted Auris reference despite an unusable Pocket Casts object, got \(manager.state)")
            return
        }
        // The mapping came from the Go-scheme cloud matcher: anchors map onto
        // their own timestamps on this self-referenced fixture.
        let entries = manager.debugMappingSnapshot()
        XCTAssertGreaterThanOrEqual(entries.count, FingerprintConstants.minimumCoverageForActive)
        for entry in entries {
            XCTAssertEqual(entry.referenceTime, entry.playbackTime, accuracy: 1.0)
        }
    }

    /// Same fall-through at the fetched call site: the server returns a
    /// decodable Pocket Casts reference with no usable checkpoints, and the
    /// concurrent Auris fetch succeeds — preparation must use the Auris one.
    func testUnusableFetchedReferenceFallsThroughToTheFetchedAurisReference() async throws {
        try prepareFixture()
        let unusable = Self.unusableReference()
        let payload = cloudPayload!
        CloudRouteTestURLProtocol.requestHandler = { request in
            if request.url?.host == "gateway.cloud-decoupling.test" {
                return .complete(status: 200, headers: ["Content-Type": "application/json"], body: payload)
            }
            if request.url?.path.contains("-fingerprints.json") == true {
                return .complete(status: 200, headers: ["Content-Type": "application/json"], body: unusable)
            }
            return .complete(status: 403, headers: [:], body: Data())
        }

        manager.prepareForCurrentEpisode()
        await waitForPass(manager)

        guard case .active = manager.state else {
            XCTFail("expected .active from the fetched Auris reference despite an unusable fetched Pocket Casts object, got \(manager.state)")
            return
        }
        let entries = manager.debugMappingSnapshot()
        XCTAssertGreaterThanOrEqual(entries.count, FingerprintConstants.minimumCoverageForActive)
        for entry in entries {
            XCTAssertEqual(entry.referenceTime, entry.playbackTime, accuracy: 1.0)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.cloudReferenceURL.path),
            "the fetched Auris payload must persist to its own sibling file"
        )
    }

    /// A valid compact-v2 JSON object that decodes but carries no checkpoints —
    /// `configureForReference` must report failure so the caller falls through.
    private static func unusableReference() -> Data {
        let json: [String: Any] = [
            "format": ReferenceFingerprint.supportedFormat,
            "total_duration": episodeDuration,
            "checkpoint_interval": 1,
            "checkpoint_duration": 5,
            "timestamp_quantum": 1,
            "checkpoints": [[Any]]()
        ]
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: json)
    }

    // MARK: - Fixture

    private func prepareFixture() throws {
        let fixture = FingerprintEpisodeFixture(duration: Self.episodeDuration)
        try fixture.writeAudio(seconds: Self.episodeDuration)
        self.fixture = fixture
        currentEpisode = CurrentEpisodeOverride(episode: fixture.episode)
        manager = FingerprintTimingManager(cloudFetcher: stubbedFetcher)
        cloudPayload = try Self.makeCloudReference(forAudioAt: fixture.audioURL)
    }

    /// Serves the Auris reference from the stubbed gateway; the Pocket Casts
    /// host answers with the given stub (403 = the object is missing).
    private func stubHosts(pocketCasts: CloudRouteTestStub) {
        let payload = cloudPayload!
        CloudRouteTestURLProtocol.requestHandler = { request in
            if request.url?.host == "gateway.cloud-decoupling.test" {
                return .complete(status: 200, headers: ["Content-Type": "application/json"], body: payload)
            }
            return pocketCasts
        }
    }

    /// Builds a `fingerprint-compact-v2` payload with Go-scheme hashes from the
    /// episode's own audio — the same scheme the server's reference uses.
    private static func makeCloudReference(forAudioAt url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let fingerprinter = CloudFingerprinter()
        let chunkFrames = AVAudioFrameCount(format.sampleRate * 5)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw NSError(domain: "CloudReferenceDecouplingTests", code: 1)
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
