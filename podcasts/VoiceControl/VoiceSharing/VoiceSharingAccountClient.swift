import Foundation

/// Client for the Go-owned voice-sharing account routes (spec `270dfa5b`).
///
/// Deliberately narrow: it performs HTTP, decodes the published projection, and enforces the two rules the
/// contract places on clients — never apply a response belonging to an obsolete account/session, and never
/// auto-replay a conflicted opt-in. Everything else (disclosure copy, numeric limits, upload) is elsewhere.
///
/// The transport is injected so the production `URLSession` path and the race controls drive the SAME
/// decoding/status handling; a stub that only returns pre-decided enums would prove nothing about the wire.
final class VoiceSharingAccountClient {
    static let projectionPath = "/api/v1/account/voice-sharing"
    static let enrollmentPath = "/api/v1/account/voice-sharing/enrollment"
    static let withdrawalPath = "/api/v1/account/voice-sharing/withdrawal"
    static let dataPath = "/api/v1/account/voice-sharing/data"
    static let defaultTimeoutSeconds: TimeInterval = 15

    /// Wire field names, kept next to the code that reads them so a contract change is one edit.
    enum Field {
        static let schemaVersion = "schema_version"
        static let membershipRevision = "membership_revision"
        static let plan = "plan"
        static let enrolled = "voice_sharing_enrolled"
        static let epoch = "enrollment_epoch"
        static let acceptedDisclosure = "accepted_disclosure_version"
        static let withdrawalState = "withdrawal_state"
        static let requestId = "request_id"
        static let expectedRevision = "expected_membership_revision"
        static let deletionRequestId = "deletion_request_id"
        static let status = "status"
    }

    private let baseURLProvider: () -> String
    private let tokenProvider: CloudTokenProviding
    private let session: URLSession
    private let requestIDFactory: () -> String
    /// Identity of the current account/session. A response whose captured identity no longer matches is
    /// dropped rather than applied — a late reply from a previous account must not resurrect membership.
    private let sessionIdentity: () -> String?

    init(
        baseURLProvider: @escaping () -> String = { CloudConfig.shared.baseUrl },
        tokenProvider: CloudTokenProviding,
        session: URLSession = URLSession(configuration: .default),
        requestIDFactory: @escaping () -> String = { UUID().uuidString.lowercased() },
        sessionIdentity: @escaping () -> String? = { CloudIdentity.shared.userId }
    ) {
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
        self.session = session
        self.requestIDFactory = requestIDFactory
        self.sessionIdentity = sessionIdentity
    }

    // MARK: - GET projection

    func fetchProjection() async -> VoiceSharingMembership? {
        guard let request = await makeRequest(path: Self.projectionPath, method: "GET", body: nil) else { return nil }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 401 || http.statusCode == 403 {
                await tokenProvider.handleUnauthorized(rejectedToken: nil)
            }
            guard http.statusCode == 200 else { return nil }
            return Self.decodeProjection(data)
        } catch {
            return nil
        }
    }

    // MARK: - POST enrollment / withdrawal

    func enroll(acceptedDisclosureVersion: String, expectedMembershipRevision: String) async -> VoiceSharingMutationOutcome {
        var body: [String: Any] = [
            Field.requestId: requestIDFactory(),
            Field.expectedRevision: expectedMembershipRevision,
            Field.acceptedDisclosure: acceptedDisclosureVersion,
        ]
        // Null-vs-absent matters on the wire only where the contract allows null; disclosure is required here.
        body[Field.acceptedDisclosure] = acceptedDisclosureVersion
        return await mutate(path: Self.enrollmentPath, body: body)
    }

    /// `epoch` is nullable BY CONTRACT: null is valid only when the expected projection has no active
    /// epoch, which is what lets an opt-out invalidate an outstanding opt-in. Neither form may withdraw a
    /// later enrollment — that ordering is enforced server-side by the revision check.
    func withdraw(enrollmentEpoch: String?, expectedMembershipRevision: String) async -> VoiceSharingMutationOutcome {
        let body: [String: Any] = [
            Field.requestId: requestIDFactory(),
            Field.expectedRevision: expectedMembershipRevision,
            Field.epoch: enrollmentEpoch as Any,
        ]
        return await mutate(path: Self.withdrawalPath, body: body)
    }

    // MARK: - DELETE accepted data (separate operation, separate request identity)

    func deleteAcceptedData() async -> VoiceSharingDeletionOutcome {
        guard let request = await makeRequest(
            path: Self.dataPath,
            method: "DELETE",
            body: [Field.requestId: requestIDFactory()]
        ) else { return .unavailableBackend }
        let startedForIdentity = sessionIdentity()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailableBackend }
            switch http.statusCode {
            case 202:
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (object[Field.status] as? String) == "deletion_pending",
                      let id = object[Field.deletionRequestId] as? String
                else { return .unavailableBackend }
                // Deletion is scoped to the account that asked for it. If the user changed while this was in
                // flight, applying the receipt would attribute one account's deletion to another.
                guard sessionIdentity() == startedForIdentity else { return .unavailableBackend }
                return .pending(deletionRequestId: id)
            case 401: return .unauthorized
            case 403: return .refused(reason: .ineligible)
            case 422: return .refused(reason: .invalidRequest)
            default: return .unavailableBackend
            }
        } catch {
            return .unavailableBackend
        }
    }

    // MARK: - Shared mutation path

    private func mutate(path: String, body: [String: Any]) async -> VoiceSharingMutationOutcome {
        guard let request = await makeRequest(path: path, method: "POST", body: body) else {
            return .unavailableBackend
        }
        // Identity is captured BEFORE the round trip so a late reply can be recognised as stale.
        let identityAtStart = sessionIdentity()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailableBackend }
            switch http.statusCode {
            case 200:
                guard let projection = Self.decodeProjection(data) else { return .unavailableBackend }
                guard sessionIdentity() == identityAtStart else { return .droppedStaleSession }
                return .applied(projection)
            case 409:
                // A conflict carries the current projection. Surfacing it is required so the caller can show
                // the real state; auto-replaying against the newer revision is forbidden.
                let current = Self.decodeProjection(data)
                guard sessionIdentity() == identityAtStart else { return .droppedStaleSession }
                return .conflict(current: current)
            case 401:
                await tokenProvider.handleUnauthorized(rejectedToken: nil)
                return .unauthorized
            case 403:
                return .refused(reason: .ineligible)
            case 422:
                let reason = Self.refusalReason(from: data)
                return .refused(reason: reason)
            default:
                return .unavailableBackend
            }
        } catch {
            return .unavailableBackend
        }
    }

    private func makeRequest(path: String, method: String, body: [String: Any]?) async -> URLRequest? {
        let base = baseURLProvider()
        guard !base.isEmpty, let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.defaultTimeoutSeconds
        // Fail closed without a credential: no bearer, no call. Never fall back to a client-supplied
        // identity — the server scopes ownership from the authenticated account.
        guard let credential = await tokenProvider.token() else { return nil }
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            request.httpBody = encoded
        }
        return request
    }

    // MARK: - Decoding

    /// Unknown/partial/mismatched-schema input yields `nil` (or `.unavailable` membership) rather than a
    /// permissive default: a parse failure must read as "not enrolled", never as permission.
    static func decodeProjection(_ data: Data) -> VoiceSharingMembership? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object[Field.schemaVersion] as? Int, version == 1,
              let revision = object[Field.membershipRevision] as? String,
              let planRaw = object[Field.plan] as? String, let plan = VoiceSharingMembership.Plan(rawValue: planRaw),
              let enrolled = object[Field.enrolled] as? Bool,
              let withdrawalRaw = object[Field.withdrawalState] as? String,
              let withdrawal = VoiceSharingMembership.WithdrawalState(rawValue: withdrawalRaw)
        else { return nil }
        let epoch = object[Field.epoch] as? String
        let disclosure = object[Field.acceptedDisclosure] as? String
        // Cross-field sanity: an ACTIVE enrollment without an epoch cannot authorize collection, because
        // every record is keyed by (contributor, enrollment_epoch, capture_id). Treat it as unknown state.
        if withdrawal == .active && !enrolled { return nil }
        if enrolled && epoch == nil { return nil }
        return VoiceSharingMembership(
            membershipRevision: revision,
            plan: plan,
            voiceSharingEnrolled: enrolled,
            enrollmentEpoch: epoch,
            acceptedDisclosureVersion: disclosure,
            withdrawalState: withdrawal
        )
    }

    private static func refusalReason(from data: Data) -> VoiceSharingMutationOutcome.RefusalReason {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["error"] as? String else { return .invalidRequest }
        if code.contains("disclosure") { return .unsupportedDisclosure }
        if code.contains("ineligible") { return .ineligible }
        return .invalidRequest
    }
}
