import CryptoKit
import XCTest
@testable import podcasts

/// The download contract for a PINNED asset: an existing final file is checked against its
/// pin, a corrupt file is replaced, and one final file is produced by one download even when
/// two callers race. These tests pin the holes that let a corrupt model file reach
/// onnxruntime, which then fails to load its graph.
final class ModelDownloaderPinTests: XCTestCase {

    /// Serves registered byte payloads on `http://model-pin.test/...`. Counts requests so a
    /// test can assert how many full downloads a scenario needed.
    private final class StubURLProtocol: URLProtocol {
        static let lock = NSLock()
        static var payloads: [String: Data] = [:]
        static var requestCount: [String: Int] = [:]
        static var startDelayMs: Int = 0
        /// When true, a Range request whose offset is at/past the payload length gets 416.
        static var honorRange: Bool = false
        /// When > 0, the first N requests fail with a network error.
        static var failFirst: Int = 0
        /// When > 0, the first N requests serve these WRONG bytes (hash mismatch, no retry).
        static var wrongFirst: Int = 0
        static var wrongBytes: Data = Data()
        /// Overlap tracking: how many requests were in flight at once, and the max seen.
        static var inFlight: Int = 0
        static var maxInFlight: Int = 0

        static func reset(payloads: [String: Data], startDelayMs: Int = 0, honorRange: Bool = false, failFirst: Int = 0) {
            lock.lock(); defer { lock.unlock() }
            self.payloads = payloads
            self.requestCount = [:]
            self.startDelayMs = startDelayMs
            self.honorRange = honorRange
            self.failFirst = failFirst
            self.wrongFirst = 0
            self.wrongBytes = Data()
            self.inFlight = 0
            self.maxInFlight = 0
        }

        static func count(for path: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return requestCount[path] ?? 0
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "model-pin.test"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let path = url.path
            Self.lock.lock()
            Self.requestCount[path, default: 0] += 1
            let n = Self.requestCount[path]!
            Self.inFlight += 1
            Self.maxInFlight = max(Self.maxInFlight, Self.inFlight)
            let payload = Self.payloads[path]
            let delay = Self.startDelayMs
            let honorRange = Self.honorRange
            let shouldFail = n <= Self.failFirst
            let serveWrong = n <= Self.wrongFirst
            let wrong = Self.wrongBytes
            Self.lock.unlock()
            defer {
                Self.lock.lock()
                Self.inFlight -= 1
                Self.lock.unlock()
            }
            if delay > 0 { Thread.sleep(forTimeInterval: Double(delay) / 1000.0) }
            if shouldFail {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            guard let data = payload else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let served = serveWrong ? wrong : data
            // A real server answers 416 when the Range offset is at/past the full length.
            if honorRange, let range = request.value(forHTTPHeaderField: "Range"),
               let offset = UInt64(range.replacingOccurrences(of: "bytes=", with: "").replacingOccurrences(of: "-", with: "")),
               offset >= UInt64(data.count) {
                let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Range": "bytes */\(data.count)"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": String(served.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: served)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeDownloader() -> ModelDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ModelDownloader(session: URLSession(configuration: config))
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private let goodBytes = Data("good-model-bytes".utf8)
    private let corruptBytes = Data("corrupt-truncated-garbage".utf8)
    private var path: String { "/model.int8.onnx" }
    private var url: URL { URL(string: "http://model-pin.test\(path)")! }

    /// A pinned asset already on disk in a corrupt state must be DELETED AND RE-DOWNLOADED,
    /// never trusted. This is the hole that kept a corrupt sensevoice model loadable forever.
    func testExistingCorruptFinalFileWithPinIsReplacedByADownload() async throws {
        let dir = try makeDir()
        try corruptBytes.write(to: dir.appendingPathComponent("model.int8.onnx"))
        StubURLProtocol.reset(payloads: [path: goodBytes])
        let downloader = makeDownloader()

        let result = await downloader.download(url: url, sha256: sha(goodBytes), to: dir)

        guard case .success = result else { return XCTFail("download failed: \(result)") }
        let final = try Data(contentsOf: dir.appendingPathComponent("model.int8.onnx"))
        XCTAssertEqual(final, goodBytes, "the corrupt file is replaced by the pinned bytes")
        XCTAssertEqual(StubURLProtocol.count(for: path), 1, "the replacement is a real download")
    }

    /// Two concurrent callers for the same pinned asset must produce ONE download and one
    /// correct final file — not two interleaved writers on the same `.tmp`.
    func testConcurrentDownloadsOfTheSamePinnedAssetIssueOneRequest() async throws {
        let dir = try makeDir()
        StubURLProtocol.reset(payloads: [path: goodBytes], startDelayMs: 300)
        let downloader = makeDownloader()

        async let first: Result<Void, Error> = downloader.download(url: url, sha256: sha(goodBytes), to: dir)
        async let second: Result<Void, Error> = downloader.download(url: url, sha256: sha(goodBytes), to: dir)
        let (r1, r2) = await (first, second)

        guard case .success = r1 else { return XCTFail("first failed: \(r1)") }
        guard case .success = r2 else { return XCTFail("second failed: \(r2)") }
        let final = try Data(contentsOf: dir.appendingPathComponent("model.int8.onnx"))
        XCTAssertEqual(final, goodBytes, "the final file carries the pinned bytes")
        XCTAssertEqual(StubURLProtocol.count(for: path), 1,
                       "one final file comes from one download, not two interleaved writers")
    }

    /// An existing GOOD pinned file must be trusted with ZERO requests — otherwise a check
    /// that always re-downloads would pass the corrupt-replacement test too.
    func testExistingGoodPinnedFileMakesZeroRequests() async throws {
        let dir = try makeDir()
        try goodBytes.write(to: dir.appendingPathComponent("model.int8.onnx"))
        StubURLProtocol.reset(payloads: [path: goodBytes])
        let downloader = makeDownloader()

        let result = await downloader.download(url: url, sha256: sha(goodBytes), to: dir)

        guard case .success = result else { return XCTFail("download failed: \(result)") }
        XCTAssertEqual(StubURLProtocol.count(for: path), 0, "a good pinned file is not re-downloaded")
        let final = try Data(contentsOf: dir.appendingPathComponent("model.int8.onnx"))
        XCTAssertEqual(final, goodBytes, "the good file is left untouched")
    }

    /// A verified-marker lets later starts skip the full hash — but a file CHANGED after the
    /// marker was written must still be caught: the marker's size/mtime no longer match, so
    /// the file is hashed in full, fails its pin, and is replaced.
    func testChangedFileWithStaleMarkerIsCaughtAndReplaced() async throws {
        let dir = try makeDir()
        let finalURL = dir.appendingPathComponent("model.int8.onnx")
        try goodBytes.write(to: finalURL)
        StubURLProtocol.reset(payloads: [path: goodBytes])
        let downloader = makeDownloader()

        // First call verifies the good file and writes the marker.
        let first = await downloader.download(url: url, sha256: sha(goodBytes), to: dir)
        guard case .success = first else { return XCTFail("first failed: \(first)") }
        XCTAssertEqual(StubURLProtocol.count(for: path), 0, "premise: the good file was trusted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.int8.onnx.verified").path),
                      "premise: a verified marker was written")

        // Corrupt the file behind the marker's back (same length would still change mtime;
        // here the content changes too, so both the marker check and the hash must catch it).
        try corruptBytes.write(to: finalURL)
        StubURLProtocol.reset(payloads: [path: goodBytes])

        let second = await downloader.download(url: url, sha256: sha(goodBytes), to: dir)
        guard case .success = second else { return XCTFail("second failed: \(second)") }
        let final = try Data(contentsOf: finalURL)
        XCTAssertEqual(final, goodBytes, "the changed file is replaced despite the stale marker")
        XCTAssertEqual(StubURLProtocol.count(for: path), 1, "the stale marker forced a real re-download")
    }

    /// A CHANGED PIN with an UNCHANGED file must force a full hash: the marker records the
    /// old pin, so it no longer matches, the file is hashed against the new pin, fails, and
    /// is replaced by a download.
    func testChangedPinWithUnchangedFileForcesFullHashAndReplace() async throws {
        let dir = try makeDir()
        let finalURL = dir.appendingPathComponent("model.int8.onnx")
        try goodBytes.write(to: finalURL)
        StubURLProtocol.reset(payloads: [path: goodBytes])
        let downloader = makeDownloader()

        // Serve the corrupt bytes and pin THEIR hash, so the first call succeeds and writes
        // a marker under the old pin.
        StubURLProtocol.reset(payloads: [path: corruptBytes])
        let setup = await downloader.download(url: url, sha256: sha(corruptBytes), to: dir)
        guard case .success = setup else { return XCTFail("setup failed: \(setup)") }
        XCTAssertEqual(try Data(contentsOf: finalURL), corruptBytes, "premise: file matches the old pin")

        // Now the pin changes to the good bytes' hash; the file is unchanged.
        StubURLProtocol.reset(payloads: [path: goodBytes])
        let second = await downloader.download(url: url, sha256: sha(goodBytes), to: dir)
        guard case .success = second else { return XCTFail("second failed: \(second)") }
        XCTAssertEqual(try Data(contentsOf: finalURL), goodBytes, "the new pin replaces the old-pinned file")
        XCTAssertEqual(StubURLProtocol.count(for: path), 1, "the changed pin forced a real download")
    }

    /// A full-size `.tmp` left by a kill between download and rename: the next start's Range
    /// request gets 416. That must go STRAIGHT to the hash check — not five retries that keep
    /// the tmp and fail identically on every start.
    func testFullSizeTmpWith416GoesStraightToHashCheck() async throws {
        let dir = try makeDir()
        // The tmp holds the complete, correct bytes; no final file exists.
        try goodBytes.write(to: dir.appendingPathComponent("model.int8.onnx.tmp"))
        StubURLProtocol.reset(payloads: [path: goodBytes], honorRange: true)
        let downloader = makeDownloader()

        let result = await downloader.download(url: url, sha256: sha(goodBytes), to: dir)

        guard case .success = result else { return XCTFail("download failed: \(result)") }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("model.int8.onnx")), goodBytes,
                       "the full-size tmp is verified and renamed, not re-downloaded")
        XCTAssertEqual(StubURLProtocol.count(for: path), 1,
                       "one Range request answered 416, then the hash check — no retry loop")
    }

    /// Three concurrent callers where A's WHOLE download fails (wrong bytes → hash mismatch,
    /// no retry): B and C must then download ONE AT A TIME. On the old unregistered-waiter
    /// code B and C overlap (maxInFlight == 2); the chained tasks keep it at 1.
    func testThreeConcurrentCallersWithFirstFailureStillSerialize() async throws {
        let dir = try makeDir()
        StubURLProtocol.reset(payloads: [path: goodBytes], startDelayMs: 200)
        StubURLProtocol.lock.lock()
        StubURLProtocol.wrongFirst = 1
        StubURLProtocol.wrongBytes = corruptBytes
        StubURLProtocol.lock.unlock()
        let downloader = makeDownloader()

        async let a: Result<Void, Error> = downloader.download(url: url, sha256: sha(goodBytes), to: dir)
        async let b: Result<Void, Error> = downloader.download(url: url, sha256: sha(goodBytes), to: dir)
        async let c: Result<Void, Error> = downloader.download(url: url, sha256: sha(goodBytes), to: dir)
        let (ra, rb, rc) = await (a, b, c)

        guard case .failure = ra else { return XCTFail("a must fail on the wrong bytes: \(ra)") }
        guard case .success = rb else { return XCTFail("b failed: \(rb)") }
        guard case .success = rc else { return XCTFail("c failed: \(rc)") }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("model.int8.onnx")), goodBytes)
        XCTAssertEqual(StubURLProtocol.maxInFlight, 1,
                       "never two requests in flight on the same asset, even after a failure")
    }

    /// An UNREADABLE existing file must fail this start WITHOUT being deleted: a read error
    /// is not evidence the bytes are bad, and deleting a 239 MB model over a transient read
    /// failure is exactly the loss this check must avoid.
    func testUnreadableExistingFileFailsWithoutDeleting() async throws {
        let dir = try makeDir()
        let finalURL = dir.appendingPathComponent("model.int8.onnx")
        try goodBytes.write(to: finalURL)
        // Make the file unreadable: no read permission for anyone.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: finalURL.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: finalURL.path) }
        StubURLProtocol.reset(payloads: [path: goodBytes])
        let downloader = makeDownloader()

        let result = await downloader.download(url: url, sha256: sha(goodBytes), to: dir)

        guard case .failure = result else { return XCTFail("an unreadable file must fail this start: \(result)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path),
                      "the unreadable file is KEPT, not deleted")
        XCTAssertEqual(StubURLProtocol.count(for: path), 0, "no re-download over a read error")
    }
}
