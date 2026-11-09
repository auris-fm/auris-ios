import Foundation

/// Holds a just-created transfer until its caller has published it for cancellation.
private final class TransferGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    func waitUntilReleased() async {
        while true {
            lock.lock()
            let isReleased = released
            lock.unlock()
            if isReleased { return }
            await Task.yield()
        }
    }

    func release() {
        lock.lock(); released = true; lock.unlock()
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
    /// The transfer currently in flight, so a consent loss can cancel it rather than merely stop
    /// scheduling new work. Cancelling the task cancels the underlying request.
    private let inFlightLock = NSLock()
    /// Test seam for the withdrawal window: called under the registration lock, after permission is
    /// answered and before the transfer is published. A caller that withdraws here proves the stop is
    /// observed by the same critical section rather than slipping into a gap.
    var afterPermissionBeforeRegistrationForTesting: (() -> Void)?
    private var inFlight: Task<(Data, URLResponse), any Error>?

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
    /// `stillPermitted` is asked after the credential is in hand, INSIDE the same critical section
    /// that registers the transfer: a withdrawal that lands while this call is waiting for a
    /// credential — or in the instant between that answer and registration — must stop the recording
    /// from reaching the network at all.
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
            let (_, response) = try await runInFlight(request, body: body, stillPermitted: stillPermitted)
            guard let http = response as? HTTPURLResponse else { return .noAnswer }
            return .response(status: http.statusCode)
        } catch is CancellationError {
            // Refused under the registration lock: nothing was sent, and nothing is left registered.
            return .cancelled
        } catch {
            return .noAnswer
        }
    }

    /// Runs one transfer, publishing it so `cancelInFlight()` can reach it.
    ///
    /// No latch: a stop cancels the attempt in flight, and the next call starts a fresh one.
    ///
    /// The permission check is INSIDE the same critical section that creates and publishes the task.
    /// Asking before taking the lock leaves a window: a withdrawal landing after the answer but
    /// before registration found nothing to cancel, and the transfer then started without ever
    /// re-reading permission — a recording would reach the network after the user said stop. The
    /// gate closes the remaining interval, so the task cannot send until it is reachable.
    private func runInFlight(_ request: URLRequest, body: Data,
                             stillPermitted: () -> Bool) async throws -> (Data, URLResponse) {
        let gate = TransferGate()
        inFlightLock.lock()
        guard stillPermitted() else {
            inFlightLock.unlock()
            throw CancellationError()
        }
        // Test seam: runs the interleaving a real withdrawal could otherwise only reach by luck.
        afterPermissionBeforeRegistrationForTesting?()
        let task = Task { [session] in
            await gate.waitUntilReleased()
            return try await session.upload(for: request, from: body)
        }
        inFlight = task
        // Asked AGAIN once the transfer is registered, still under the same lock: the answer above
        // can be stale by now, and a withdrawal in between would otherwise let the bytes leave. A
        // stop that ran in that window cancelled nothing (there was nothing to cancel yet), so this
        // second reading is what makes the start atomic.
        let permittedAfterRegistration = stillPermitted()
        if !permittedAfterRegistration {
            inFlight = nil
            task.cancel()
        }
        inFlightLock.unlock()
        defer { inFlightLock.lock(); inFlight = nil; inFlightLock.unlock() }
        guard permittedAfterRegistration else { throw CancellationError() }
        gate.release()
        return try await task.value
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