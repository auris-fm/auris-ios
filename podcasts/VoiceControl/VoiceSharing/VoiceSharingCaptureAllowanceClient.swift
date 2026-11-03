import Foundation

/// Client adapter for `POST /api/v1/account/voice-sharing/capture-allowance`
/// (spec docs/specs/voice-recording-uploads.md, "Server-issued capture allowance").
/// The body carries ONLY `request_id` and `enrollment_epoch` — no caller ever supplies
/// capacity, account identity, accounting day or object keys.
struct VoiceSharingCaptureAllowanceRequest: Equatable {
    let requestID: String
    let enrollmentEpoch: String

    init?(requestID: String, enrollmentEpoch: String) {
        guard UUID(uuidString: requestID) != nil,
              !enrollmentEpoch.isEmpty, enrollmentEpoch.utf8.count <= 512 else { return nil }
        self.requestID = requestID
        self.enrollmentEpoch = enrollmentEpoch
    }

    var body: Data? {
        let object: [String: Any] = ["request_id": requestID, "enrollment_epoch": enrollmentEpoch]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= 8 * 1024 else { return nil }
        return data
    }
}

enum VoiceSharingCaptureAllowanceDisposition: String, Equatable {
    case issued
    case replayed
}

/// A VALIDATED response. Any invalid or oversized value fails closed: no authority exists.
struct VoiceSharingCaptureAllowanceResponse: Equatable {
    /// Compiled ceilings: independent of any response and never raised by one.
    static let compiledMaxClipMS: Int = 60_000
    static let compiledMaxClipBytes: Int = 1_920_044
    static let compiledMaxMetadataBytes: Int = 65_536
    /// Server freshness interval bound: at most 300,000 ms.
    static let compiledMaxValidForMS: Int = 300_000
    /// Envelope bound for every bounded read (requests and responses, success or error).
    static let maximumEnvelopeBytes = 8 * 1024

    let requestID: String
    let windowID: String
    let batchID: String
    let enrollmentEpoch: String
    let disposition: VoiceSharingCaptureAllowanceDisposition
    /// REMAINING validity in ms, anchored to the monotonic request-start instant retained
    /// alongside (`deadlineMonotonicMS`): transit and delayed installation can never extend
    /// the server interval because admission re-checks against the ORIGINAL deadline.
    let validForMSRemaining: Int
    let deadlineMonotonicMS: Int
    /// The ORIGINAL monotonic request start; a backward clock cannot restore validity.
    let startMonotonicMS: Int
    let batchMaxRecords: Int
    let batchMaxBytes: Int
    let maxClipMS: Int
    let maxClipBytes: Int
    let maxMetadataBytes: Int

    /// `elapsedMS` is the monotonic time already consumed between the request-start instant
    /// and now; it must be non-negative (a backward clock cannot extend validity) and the
    /// subtraction is overflow-checked. Returns nil (fail closed) for invalid IDs, unknown
    /// dispositions, booleans posing as numbers, oversized values, or an elapsed interval.
    init?(json: Data, expectedRequestID: String, expectedEnrollmentEpoch: String,
          requestStartMonotonicMS: Int, elapsedMS: Int) {
        guard elapsedMS >= 0, elapsedMS <= Self.validForSanityBound else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: json, options: [])) as? [String: Any],
              object.count <= 24, json.count <= Self.maximumEnvelopeBytes else { return nil }
        func integer(_ key: String, min lower: Int, max upper: Int) -> Int? {
            guard let raw = object[key] else { return nil }
            // JSON booleans must NOT pass as Int: NSNumber(value: 1) answers `is Bool` TRUE on
            // Apple platforms, so identity comes from CF type IDs, not Swift bridging.
            let typeID = CFGetTypeID(raw as CFTypeRef)
            guard typeID == CFNumberGetTypeID(), let number = raw as? NSNumber,
                  CFNumberIsFloatType(number) == false else { return nil }
            let int = number.intValue
            guard int >= lower, int <= upper else { return nil }
            return int
        }
        guard let schemaRaw = object["schema_version"], Self.integerCheck(schemaRaw),
              let schemaVersion = (schemaRaw as? NSNumber)?.intValue, schemaVersion == 1,
              let requestID = object["request_id"] as? String, requestID == expectedRequestID,
              UUID(uuidString: requestID) != nil,
              let windowID = object["window_id"] as? String, UUID(uuidString: windowID) != nil,
              let batchID = object["batch_id"] as? String, UUID(uuidString: batchID) != nil,
              let epoch = object["enrollment_epoch"] as? String, epoch == expectedEnrollmentEpoch,
              epoch.utf8.count <= 512,
              let dispositionRaw = object["disposition"] as? String,
              let disposition = VoiceSharingCaptureAllowanceDisposition(rawValue: dispositionRaw),
              let validFor = integer("valid_for_ms", min: 1, max: Self.compiledMaxValidForMS),
              let batchMaxRecords = integer("batch_max_records", min: 1, max: 4),
              let batchMaxBytes = integer("batch_max_bytes", min: 1_985_580, max: 4 * 1_985_580),
              let maxClipMS = integer("max_clip_ms", min: 1, max: Self.compiledMaxClipMS),
              let maxClipBytes = integer("max_clip_bytes", min: 45, max: Self.compiledMaxClipBytes),
              let maxMetadataBytes = integer("max_metadata_bytes", min: 1, max: Self.compiledMaxMetadataBytes)
        else { return nil }
        // Anchor the interval to the ORIGINAL request-start monotonic instant.
        let remainingMS = validFor - elapsedMS
        guard remainingMS > 0 else { return nil }
        self.requestID = requestID
        self.windowID = windowID
        self.batchID = batchID
        self.enrollmentEpoch = epoch
        self.disposition = disposition
        validForMSRemaining = remainingMS
        let (deadline, deadlineOverflow) = requestStartMonotonicMS.addingReportingOverflow(validFor)
        guard !deadlineOverflow else { return nil }
        deadlineMonotonicMS = deadline
        startMonotonicMS = requestStartMonotonicMS
        self.batchMaxRecords = batchMaxRecords
        self.batchMaxBytes = batchMaxBytes
        self.maxClipMS = maxClipMS
        self.maxClipBytes = maxClipBytes
        self.maxMetadataBytes = maxMetadataBytes
    }

    /// Sanity bound so a hostile `elapsedMS` cannot approach Int overflow in subtraction.
    private static let validForSanityBound = compiledMaxValidForMS

    /// JSON booleans must never pass as integers (NSNUMBERS bridge too freely).
    private static let integerCheck: (Any) -> Bool = { raw in
        // NSNumber(value: 1) answers `is Bool` TRUE on Apple platforms; use CF type identity.
        let typeID = CFGetTypeID(raw as CFTypeRef)
        guard typeID == CFNumberGetTypeID(), let number = raw as? NSNumber,
              CFNumberIsFloatType(number) == false else { return false }
        return true
    }

    /// Admission validity AGAINST THE ORIGINAL WINDOW: start <= now < deadline. A clock
    /// reading before the original start (backward jump) cannot restore validity.
    func stillValid(monotonicNowMS: Int) -> Bool {
        guard monotonicNowMS >= 0, monotonicNowMS >= startMonotonicMS else { return false }
        let (elapsed, overflow) = monotonicNowMS.subtractingReportingOverflow(startMonotonicMS)
        guard !overflow else { return false }
        // deadline = start + full server interval, so this is overflow-free by construction.
        return elapsed < deadlineMonotonicMS - startMonotonicMS
    }
}

/// Transport for the capture-allowance endpoint. Mirrors the account client's seam style so
/// URLProtocol-based controls stay deterministic; one outstanding request identity per
/// account+epoch is the installation fence's responsibility, not this struct's.
struct VoiceSharingCaptureAllowanceClient {
    typealias SessionIdentity = String
    static let path = "/api/v1/account/voice-sharing/capture-allowance"

    private let baseURLProvider: () -> String
    private let tokenProvider: CloudTokenProviding
    private let session: URLSession
    private let sessionIdentity: () -> SessionIdentity?
    /// Monotonic wall, injectable so controls pin the request-start anchor deterministically.
    private let monotonicNowMS: () -> Int

    init(baseURLProvider: @escaping () -> String = { CloudConfig.shared.baseUrl },
         tokenProvider: CloudTokenProviding,
         session: URLSession = URLSession(configuration: .default),
         sessionIdentity: @escaping () -> SessionIdentity? = { VoiceSharingSessionGeneration.shared.currentGeneration() },
         monotonicNowMS: @escaping () -> Int = { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }) {
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
        self.session = session
        self.sessionIdentity = sessionIdentity
        self.monotonicNowMS = monotonicNowMS
    }

    enum Outcome: Equatable {
        /// A validated response; the original request-start deadline travels with it.
        case accepted(VoiceSharingCaptureAllowanceResponse)
        /// Explicit server refusal, classified by status.
        case refused(VoiceSharingCaptureAllowanceRefusal)
        /// No trustworthy answer (network failure, oversized envelope, elapsed interval).
        case unavailable
    }

    enum VoiceSharingCaptureAllowanceRefusal: Equatable {
        case requestConflict       // 409
        case windowExpired         // 410
        case exhausted             // 429
        case retiredEnrollment     // 403
        case serverUnavailable     // 503
        case other(Int)
    }

    /// Sends one request, capturing the monotonic request-start BEFORE any work. The response
    /// read is bounded at limit+1 bytes for every status (the connection stops consuming past
    /// the bound), so oversized delivery cannot buffer unbounded response bodies.
    func perform(_ request: VoiceSharingCaptureAllowanceRequest) async -> Outcome {
        guard let identity = sessionIdentity() else { return .unavailable }
        guard let body = request.body else { return .unavailable }
        guard let url = URL(string: baseURLProvider() + Self.path) else { return .unavailable }
        let start = monotonicNowMS()
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let token = await tokenProvider.token() else { return .unavailable }
        guard sessionIdentity() == identity else { return .unavailable }
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard sessionIdentity() == identity else { return .unavailable }
        do {
            let bounded = try await Self.boundedRead(
                urlRequest, session: session, limit: VoiceSharingCaptureAllowanceResponse.maximumEnvelopeBytes)
            guard sessionIdentity() == identity else { return .unavailable }
            let data = bounded.data
            let http = bounded.http
            if bounded.exceeded, http.statusCode == 200 { return .unavailable }
            let (elapsed, elapsedOverflow) = monotonicNowMS().subtractingReportingOverflow(start)
            guard !elapsedOverflow, elapsed >= 0 else { return .unavailable } // backward/invalid clock refuses
            switch http.statusCode {
            case 200:
                guard let validated = VoiceSharingCaptureAllowanceResponse(
                    json: data, expectedRequestID: request.requestID,
                    expectedEnrollmentEpoch: request.enrollmentEpoch,
                    requestStartMonotonicMS: start, elapsedMS: elapsed) else { return .unavailable }
                return .accepted(validated)
            case 409: return .refused(.requestConflict)
            case 410: return .refused(.windowExpired)
            case 429: return .refused(.exhausted)
            case 403: return .refused(.retiredEnrollment)
            case 503: return .refused(.serverUnavailable)
            case let code: return .refused(.other(code))
            }
        } catch {
            return .unavailable
        }
    }

    enum TransportBound: Error { case oversizedOrIncomplete, cancelled }

    /// Per-INVOCATION cancellation state, created BEFORE the task exists: a cancellation
    /// that arrives before binding is remembered and applied at bind time. No static
    /// state: cancelling A never touches B.
    final class Handle {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        func cancelTask() {
            print("DBGHANDLE cancelTask", ObjectIdentifier(self))
            lock.lock(); cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
        func bind(_ task: URLSessionTask) {
            lock.lock(); self.task = task
            let cancelled = self.cancelled
            lock.unlock()
            if cancelled { task.cancel() }
        }
    }

    /// A delegate-driven bounded read for EVERY status. The delegate retains at most
    /// limit+1 bytes and cancels the session task as soon as retained bytes EXCEED the
    /// limit (including the exact limit+1 boundary). The delegate session is invalidated
    /// on every completion path; caller cancellation is per-invocation.
    private static func boundedRead(_ request: URLRequest, session: URLSession,
                                    limit: Int) async throws -> (data: Data, http: HTTPURLResponse, exceeded: Bool) {
        let handle = Handle()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse, Bool), Error>) in
                let delegate = Delegate(limit: limit, continuation: continuation, handle: handle)
                let delegateSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: OperationQueue())
                print("DBGSESSION create", ObjectIdentifier(delegateSession))
                let task = delegateSession.dataTask(with: request)
                print("DBGBIND", request.url?.host ?? "?", ObjectIdentifier(task))
                delegate.bind(task: task, session: delegateSession)
                task.resume()
            }
        }, onCancel: { handle.cancelTask() })
    }

    private final class Delegate: NSObject, URLSessionDataDelegate {
        let limit: Int
        var continuation: CheckedContinuation<(Data, HTTPURLResponse, Bool), Error>?
        let resumeLock = NSLock()
        let handle: Handle
        var response: HTTPURLResponse?
        var data = Data()
        var boundExceeded = false
        var finished = false
        var task: URLSessionTask?
        var owningSession: URLSession?

        init(limit: Int, continuation: CheckedContinuation<(Data, HTTPURLResponse, Bool), Error>, handle: Handle) {
            self.limit = limit
            self.continuation = continuation
            self.handle = handle
        }

        func bind(task: URLSessionTask, session: URLSession) {
            print("DBGDELEGATE bind", task.currentRequest?.url?.host ?? "?", ObjectIdentifier(self))
            self.task = task
            self.owningSession = session
            handle.bind(task)
        }

        /// Resumes EXACTLY once; breaks retained references and invalidates the session.
        private func settle(_ result: Result<(Data, HTTPURLResponse, Bool), Error>) {
            resumeLock.lock()
            let continuation = self.continuation
            self.continuation = nil
            if !finished { finished = true }
            resumeLock.unlock()
            let session = owningSession
            print("DBGSETTLE", (response?.url?.host ?? "?"), "finished:", finished, ObjectIdentifier(session ?? URLSession()), "delegate:", ObjectIdentifier(self), "cont-nil:", continuation == nil)
            task = nil
            session?.finishTasksAndInvalidate()
            owningSession = nil
            guard let continuation else { return }
            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let error): print("DBGFAIL", error); continuation.resume(throwing: error)
            }
        }

        private func fallbackResponse() -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://invalid.invalid")!, statusCode: 0,
                            httpVersion: nil, headerFields: nil)!
        }

        func urlSession(_: URLSession, dataTask _: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response as? HTTPURLResponse
            completionHandler(.allow)
        }

        func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive received: Data) {
            resumeLock.lock()
            guard !finished else { resumeLock.unlock(); return }
            // Append only the REMAINING allowance up to limit+1: a single huge chunk is
            // capped, never buffered whole. The status captured BEFORE the body still
            // classifies; the bounded body itself is only parsed for 200.
            let allowance = limit + 1 - data.count
            data.append(received.prefix(max(allowance, 0)))
            // Cancel as soon as retained bytes EXCEED the limit — the exact limit+1
            // boundary counts, even if nothing further ever arrives.
            if data.count > limit {
                boundExceeded = true
                resumeLock.unlock()
                task?.cancel() // explicitly terminate the transfer
                settle(.success((data, response ?? fallbackResponse(), true)))
                return
            }
            resumeLock.unlock()
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
            if (error as? URLError)?.code == .cancelled {
                settle(.failure(TransportBound.cancelled))
                return
            }
            if let error {
                settle(.failure(error))
                return
            }
            guard let response = response else {
                settle(.failure(TransportBound.oversizedOrIncomplete))
                return
            }
            settle(.success((data, response, false)))
        }
    }
}

/// Connection of a VALIDATED response to the REAL provisioning/admission path (reviewer
/// 80ef8b5f.5): `issued` provisions the batch's ledger; `replayed` NEVER provisions — it can
/// only reopen an intact existing ledger, so a lost/corrupt batch stays burned.
enum VoiceSharingCaptureAllowanceInstallation {
    static func provisioningAuthority(account: String, response: VoiceSharingCaptureAllowanceResponse)
        -> VoiceSharingCaptureProvisioningAuthority? {
        guard response.disposition == .issued else { return nil }
        return VoiceSharingCaptureProvisioningAuthority(
            verifiedFirstProvisioningAccount: account,
            establishedWindow: response.windowID, batchId: response.batchID)
    }

    /// Admission authority derived from the response, clamped under the compiled ceilings by
    /// the limits initializer itself (a response may lower, never raise).
    static func admissionAuthority(account: String, response: VoiceSharingCaptureAllowanceResponse,
                                   consent: VoiceSharingCaptureStamp) -> VoiceSharingCaptureAuthorization? {
        guard response.disposition == .issued || response.disposition == .replayed else { return nil }
        // BOTH clip limits bind independently: samples come from max_clip_ms AND the
        // byte ceiling (16 kHz mono PCM16: 2 bytes/sample + 44-byte WAV header), so a
        // lowered max_clip_bytes cannot admit a WAV the server does not permit.
        let samplesFromMS = response.maxClipMS.multipliedReportingOverflow(by: 16)
        guard !samplesFromMS.overflow, samplesFromMS.partialValue > 0 else { return nil }
        let samplesFromBytes = (response.maxClipBytes - 44).quotientAndRemainder(dividingBy: 2)
        guard samplesFromBytes.quotient > 0 else { return nil }
        let limits = VoiceSharingCaptureLimits(
            dailyRecords: UInt64(response.batchMaxRecords),
            dailyBytes: UInt64(response.batchMaxBytes),
            compiledRecordsCeiling: 4,
            compiledBytesCeiling: UInt64(4 * 1_985_580),
            clipSamples: min(samplesFromMS.partialValue, samplesFromBytes.quotient),
            metadataBytes: response.maxMetadataBytes,
            compiledClipSamples: VoiceSharingCaptureAllowanceResponse.compiledMaxClipMS * 16,
            compiledMetadataBytes: VoiceSharingCaptureAllowanceResponse.compiledMaxMetadataBytes)
        return VoiceSharingCaptureAuthorization(account: account, establishedWindow: response.windowID,
                                                batchId: response.batchID, limits: limits, consent: consent)
    }
}
