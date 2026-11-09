import Foundation

/// Bridges one `URLSessionDataTask` to an `async` call, including its deadline.
///
/// A data task with a per-task delegate is what makes an elapsed-time budget possible: the timeout
/// handler fires for the whole transfer, not for a single stall, and cancelling the task settles the
/// awaiting call instead of leaving it suspended.
private final class TransferBridge: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var result: Result<(Data, URLResponse), Error>?
    var continuation: CheckedContinuation<(Data, URLResponse), any Error>?

    var settled: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // The body is not read: only the status decides what happens next.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { settle(.failure(error)) }
        else if let response = task.response { settle(.success((Data(), response))) }
        else { settle(.failure(URLError(.badServerResponse))) }
    }

    func settle(_ outcome: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }
}

/// Sends one recording as a single multipart request and reduces the answer to what the uploader
/// decides on. There is no reservation, no second step and no receipt matching.
final class VoiceSharingUploadTransport {

    private let baseURLProvider: () -> String
    private let tokenProvider: CloudTokenProviding
    private let session: URLSession
    /// The credential the last request presented, so a 401 can name what was rejected.
    private var lastPresentedToken: String?
    /// The request currently in flight, so a consent loss can cancel it rather than merely stop
    /// scheduling new work. Without this, "stop" leaves a recording already on its way to the wire.
    private let inFlightLock = NSLock()
    private var inFlight: URLSessionDataTask?

    init(baseURLProvider: @escaping () -> String,
         tokenProvider: CloudTokenProviding,
         session: URLSession? = nil) {
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
        // A session whose resource timeout IS the whole-transfer budget: it counts elapsed time
        // from start to finish rather than restarting on every trickle of bytes.
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForResource = Self.requestTimeout
            self.session = URLSession(configuration: config)
        }
    }

    /// Sends `metadata` then `audio` as multipart parts, in that order, as the spec requires.
    ///
    /// `stillPermitted` is asked immediately before the request leaves, after the credential is in
    /// hand: a withdrawal that lands while this call is waiting for a credential must stop the
    /// recording from reaching the network at all.
    func send(entry: VoiceSharingQueue.Entry,
              stillPermitted: () -> Bool = { true }) async -> VoiceSharingUploader.Answer {
        guard let token = await tokenProvider.token(), !token.isEmpty else {
            // No credential is indistinguishable from an expired one: the caller refreshes.
            return .response(status: 401)
        }
        guard let url = endpoint() else { return .noAnswer }
        guard let body = Self.multipartBody(
            boundary: Self.boundary,
            metadata: (try? Data(contentsOf: entry.metadataURL)) ?? Data(),
            audio: (try? Data(contentsOf: entry.audioURL)) ?? Data())
        else {
            // Unreadable parts mean the entry itself is unusable; report a final refusal rather than
            // retrying forever on the same bytes.
            return .response(status: 400)
        }
        guard stillPermitted() else { return .cancelled }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(Self.boundary)",
                         forHTTPHeaderField: "Content-Type")
        // A fixed-length body: `Data` is fully materialised, so the request carries a real
        // `Content-Length` and is never chunked. The server refuses an undeclared body before it
        // parses anything, so the length is stated explicitly rather than left to the transport.
        request.httpBody = body
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        lastPresentedToken = token
        do {
            let (_, response) = try await transfer(request)
            guard let http = response as? HTTPURLResponse else { return .noAnswer }
            return .response(status: http.statusCode)
        } catch {
            return .noAnswer
        }
    }

    /// Runs one request under a whole-transfer budget and returns once it settles or is cancelled.
    ///
    /// `URLRequest.timeoutInterval` bounds a single stall, not the elapsed time of a transfer that
    /// keeps trickling bytes. This bounds the whole thing: past the deadline the task is cancelled,
    /// which is a retry, not a delete.
    private func transfer(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let bridge = TransferBridge()
        let task = session.dataTask(with: request)
        inFlightLock.lock(); inFlight = task; inFlightLock.unlock()
        defer { inFlightLock.lock(); inFlight = nil; inFlightLock.unlock() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                bridge.continuation = continuation
                task.delegate = bridge
                session.delegateQueue.addOperation { task.resume() }
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancels the request in flight, if any. Called when consent is withdrawn: the recording must
    /// not keep travelling to the server after the user said stop.
    func cancelInFlight() {
        inFlightLock.lock()
        let task = inFlight
        inFlight = nil
        inFlightLock.unlock()
        task?.cancel()
    }

    /// Asks the app's own sign-in machinery to restore a credential, then reports whether one is
    /// available now. The provider refreshes out of band; this reads the result.
    func refreshSignIn() async -> Bool {
        let rejectedToken = lastPresentedToken
        await tokenProvider.handleUnauthorized(rejectedToken: rejectedToken)
        guard let token = await tokenProvider.token() else { return false }
        return !token.isEmpty
    }

    private func endpoint() -> URL? {
        let base = baseURLProvider()
        guard !base.isEmpty else { return nil }
        return URL(string: base)?.appendingPathComponent(String(Self.uploadPath.dropFirst()))
    }

    static let boundary = "auris-voice-recording"

    /// The one route a recording is sent to.
    static let uploadPath = "/api/v1/voice-recordings"

    /// The overall deadline for one upload, matching the server's own budget. The body is up to
    /// 1.9 MB leaving over a phone uplink, so this is dominated by the network, not by the server's
    /// work. Matching the server means neither end abandons work the other still expects; running
    /// out is a retry, never a delete.
    static let requestTimeout: TimeInterval = 60

    /// `metadata` part first, then `audio`, with the WAV named `recording.wav` per the spec.
    static func multipartBody(boundary: String, metadata: Data, audio: Data) -> Data? {
        var body = Data()
        func append(_ s: String) { body.append(contentsOf: Array(s.utf8)) }
        append("--\(boundary)\r\n")
        // Plain form field, no filename: the server reads it as the record JSON value.
        append("Content-Disposition: form-data; name=\"metadata\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(metadata)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"recording.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}