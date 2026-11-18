import CryptoKit
import XCTest
@testable import podcasts

/// The download contract for a PINNED asset: an existing final file is checked against its
/// pin, a corrupt file is replaced, and one final file is produced by one download even when
/// two callers race. These tests pin the holes that let a corrupt sensevoice model reach
/// onnxruntime (`ModelProto does not have a graph` in build #29).
final class ModelDownloaderPinTests: XCTestCase {

    /// Serves registered byte payloads on `http://model-pin.test/...`. Counts requests so a
    /// test can assert how many full downloads a scenario needed.
    private final class StubURLProtocol: URLProtocol {
        static let lock = NSLock()
        static var payloads: [String: Data] = [:]
        static var requestCount: [String: Int] = [:]
        static var startDelayMs: Int = 0

        static func reset(payloads: [String: Data], startDelayMs: Int = 0) {
            lock.lock(); defer { lock.unlock() }
            self.payloads = payloads
            self.requestCount = [:]
            self.startDelayMs = startDelayMs
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
            let (payload, delay) = Self.lock.withLock { (Self.payloads[path], Self.startDelayMs) }
            Self.lock.lock()
            Self.requestCount[path, default: 0] += 1
            Self.lock.unlock()
            if delay > 0 { Thread.sleep(forTimeInterval: Double(delay) / 1000.0) }
            guard let data = payload else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
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
}
