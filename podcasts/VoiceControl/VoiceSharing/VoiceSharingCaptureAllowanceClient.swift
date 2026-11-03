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

    let requestID: String
    let windowID: String
    let batchID: String
    let enrollmentEpoch: String
    let disposition: VoiceSharingCaptureAllowanceDisposition
    /// Monotonic-anchored remaining validity computed by the CLIENT (request-start instant).
    let validForMS: Int
    let batchMaxRecords: Int
    let batchMaxBytes: Int
    let maxClipMS: Int
    let maxClipBytes: Int
    let maxMetadataBytes: Int

    /// `elapsedMS` is the monotonic time already consumed between the request-start instant
    /// and now; transit time can never extend the server interval. Returns nil (fail closed)
    /// for invalid IDs, unknown dispositions, oversized values, or an interval already elapsed.
    init?(json: Data, expectedRequestID: String, expectedEnrollmentEpoch: String,
          elapsedMS: Int) {
        guard let object = (try? JSONSerialization.jsonObject(with: json, options: [])) as? [String: Any],
              object.count <= 24, json.count <= 8 * 1024 else { return nil }
        guard object["schema_version"] as? Int == 1,
              let requestID = object["request_id"] as? String, requestID == expectedRequestID,
              UUID(uuidString: requestID) != nil,
              let windowID = object["window_id"] as? String, UUID(uuidString: windowID) != nil,
              let batchID = object["batch_id"] as? String, UUID(uuidString: batchID) != nil,
              let epoch = object["enrollment_epoch"] as? String, epoch == expectedEnrollmentEpoch,
              epoch.utf8.count <= 512,
              let dispositionRaw = object["disposition"] as? String,
              let disposition = VoiceSharingCaptureAllowanceDisposition(rawValue: dispositionRaw),
              let validFor = Self.validatedInt(object["valid_for_ms"], min: 1, max: Self.compiledMaxValidForMS),
              let batchMaxRecords = Self.validatedInt(object["batch_max_records"], min: 1, max: 4),
              let batchMaxBytes = Self.validatedInt(object["batch_max_bytes"], min: 1_985_580, max: 4 * 1_985_580),
              let maxClipMS = Self.validatedInt(object["max_clip_ms"], min: 1, max: Self.compiledMaxClipMS),
              let maxClipBytes = Self.validatedInt(object["max_clip_bytes"], min: 45, max: Self.compiledMaxClipBytes),
              let maxMetadataBytes = Self.validatedInt(object["max_metadata_bytes"], min: 1, max: Self.compiledMaxMetadataBytes)
        else { return nil }
        // Anchor the interval to the monotonic instant BEFORE the request started.
        let remaining = validFor - elapsedMS
        guard remaining > 0 else { return nil }
        self.requestID = requestID
        self.windowID = windowID
        self.batchID = batchID
        self.enrollmentEpoch = epoch
        self.disposition = disposition
        validForMS = remaining
        self.batchMaxRecords = batchMaxRecords
        self.batchMaxBytes = batchMaxBytes
        self.maxClipMS = maxClipMS
        self.maxClipBytes = maxClipBytes
        self.maxMetadataBytes = maxMetadataBytes
    }

    private static func validatedInt(_ value: Any?, min lower: Int, max upper: Int) -> Int? {
        guard let int = value as? Int, int >= lower, int <= upper else { return nil }
        return int
    }
}

/// Transport for the capture-allowance endpoint. Mirrors the account client's seam style so
/// URLProtocol-based controls stay deterministic; one outstanding request identity per
/// account+epoch is the CALLER's (ledger/coordinator's) responsibility, not this struct's.
struct VoiceSharingCaptureAllowanceClient {
    typealias SessionIdentity = String

    let baseURLProvider: () -> String
    let tokenProvider: CloudTokenProviding
    let session: URLSession
    private let sessionIdentity: () -> SessionIdentity?

    static let path = "/api/v1/account/voice-sharing/capture-allowance"

    init(baseURLProvider: @escaping () -> String = { CloudConfig.shared.baseUrl },
         tokenProvider: CloudTokenProviding,
         session: URLSession = URLSession(configuration: .default),
         sessionIdentity: @escaping () -> SessionIdentity? = { VoiceSharingSessionGeneration.shared.currentGeneration() }) {
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
        self.session = session
        self.sessionIdentity = sessionIdentity
    }

    enum Outcome: Equatable {
        /// A validated response with its monotonic remaining validity.
        case accepted(VoiceSharingCaptureAllowanceResponse)
        /// Explicit server refusal, classified by status.
        case refused(VoiceSharingCaptureAllowanceRefusal)
        /// No trustworthy answer (network failure, invalid/oversized envelope, elapsed interval).
        case unavailable
    }

    enum VoiceSharingCaptureAllowanceRefusal: Equatable {
        case requestConflict       // 409
        case windowExpired         // 409
        case exhausted             // 429
        case retiredEnrollment     // 403
        case serverUnavailable     // 503
        case other(Int)
    }

    /// Sends one request. `deadlineStartMS` must be captured (monotonic) BEFORE the call.
    func perform(_ request: VoiceSharingCaptureAllowanceRequest,
                 elapsedMS: @escaping () -> Int = { 0 }) async -> Outcome {
        guard let identity = sessionIdentity() else { return .unavailable }
        guard let body = request.body else { return .unavailable }
        guard let url = URL(string: baseURLProvider() + Self.path) else { return .unavailable }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let token = await tokenProvider.token() else { return .unavailable }
        guard sessionIdentity() == identity else { return .unavailable }
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard sessionIdentity() == identity else { return .unavailable }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard sessionIdentity() == identity else { return .unavailable }
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            guard data.count <= 8 * 1024 else { return .unavailable }
            switch http.statusCode {
            case 200:
                guard let validated = VoiceSharingCaptureAllowanceResponse(
                    json: data, expectedRequestID: request.requestID,
                    expectedEnrollmentEpoch: request.enrollmentEpoch,
                    elapsedMS: elapsedMS()) else { return .unavailable }
                return .accepted(validated)
            case 409:
                // Distinguish request_conflict from capture_window_expired by body when possible.
                if let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
                   (object["error"] as? String) == "capture_window_expired" {
                    return .refused(.windowExpired)
                }
                return .refused(.requestConflict)
            case 429: return .refused(.exhausted)
            case 403: return .refused(.retiredEnrollment)
            case 503: return .refused(.serverUnavailable)
            case let code: return .refused(.other(code))
            }
        } catch {
            return .unavailable
        }
    }
}
