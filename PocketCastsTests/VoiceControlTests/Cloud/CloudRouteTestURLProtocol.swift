import Foundation

/// Shared URLProtocol stub for cloud route SSE client/sink tests.
enum CloudRouteTestStub {
    case complete(status: Int, headers: [String: String], body: Data)
    case dropAfter(body: Data, error: Error)
    case slowChunks(body: Data, chunkDelayNanoseconds: UInt64)
}

final class CloudRouteTestURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> CloudRouteTestStub)?
    static var onRequest: ((URLRequest, Data?) -> Void)?
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyData = Self.readBody(from: request)
        Self.lock.lock()
        Self._requestCount += 1
        Self.lock.unlock()
        Self.onRequest?(request, bodyData)

        let handler: ((URLRequest) throws -> CloudRouteTestStub)?
        Self.lock.lock()
        handler = Self.requestHandler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            switch try handler(request) {
            case let .complete(status, headers, body):
                let response = Self.httpResponse(url: request.url!, status: status, headers: headers, body: body)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !body.isEmpty {
                    client?.urlProtocol(self, didLoad: body)
                }
                client?.urlProtocolDidFinishLoading(self)

            case let .dropAfter(body, error):
                let response = Self.httpResponse(
                    url: request.url!,
                    status: 200,
                    headers: ["Content-Type": "text/event-stream"],
                    body: body
                )
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                // Defer failure so AsyncBytes can observe the loaded prefix first.
                let protocolClient = client
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    protocolClient?.urlProtocol(self, didFailWithError: error)
                }

            case let .slowChunks(body, delay):
                let response = Self.httpResponse(
                    url: request.url!,
                    status: 200,
                    headers: ["Content-Type": "text/event-stream"],
                    body: body
                )
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                let chunks = Self.chunkSSE(body)
                let protocolClient = client
                Task {
                    for chunk in chunks {
                        try? await Task.sleep(nanoseconds: delay)
                        protocolClient?.urlProtocol(self, didLoad: chunk)
                    }
                    protocolClient?.urlProtocolDidFinishLoading(self)
                }
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func stubSSE(_ body: String) {
        let data = Data(body.utf8)
        lock.lock()
        requestHandler = { _ in
            .complete(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: data
            )
        }
        lock.unlock()
    }

    /// Responds with a non-SSE JSON body (e.g. the prefetch 202).
    static func stubJSON(status: Int, body: String) {
        let data = Data(body.utf8)
        lock.lock()
        _requestCount = 0
        requestHandler = { _ in
            .complete(
                status: status,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        }
        lock.unlock()
    }

    /// Number of requests handled since the last `stubJSON`/`reset`.
    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestCount
    }

    private static var _requestCount = 0

    static func reset() {
        lock.lock()
        requestHandler = nil
        onRequest = nil
        _requestCount = 0
        lock.unlock()
    }

    private static func httpResponse(
        url: URL,
        status: Int,
        headers: [String: String],
        body: Data
    ) -> HTTPURLResponse {
        var fields = headers
        fields["Content-Length"] = "\(body.count)"
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }

    private static func chunkSSE(_ data: Data) -> [Data] {
        let text = String(data: data, encoding: .utf8) ?? ""
        let parts = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        if parts.count <= 1 { return [data] }
        return parts.map { Data(($0 + "\n\n").utf8) }
    }
}
