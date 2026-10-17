import Foundation
import PocketCastsServer

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
    /// Non-secret originating-session label. Compared, never dereferenced into anything credential-shaped.
    typealias SessionIdentity = String

    /// Current session generation, or nil when nothing is authenticated. A captured value that no longer
    /// matches is stale: its response is dropped and its operation refuses to send at all.
    private let sessionIdentity: () -> SessionIdentity?

    init(
        baseURLProvider: @escaping () -> String = { CloudConfig.shared.baseUrl },
        tokenProvider: CloudTokenProviding,
        session: URLSession = URLSession(configuration: .default),
        requestIDFactory: @escaping () -> String = { UUID().uuidString.lowercased() },
        // Default reads the in-memory lifecycle generation. NOTE: this deliberately does NOT read a
        // credential — refresh rotation would look like logout, and credentials are not operation identity.
        sessionIdentity: @escaping () -> SessionIdentity? = { VoiceSharingSessionGeneration.shared.currentGeneration() }
    ) {
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
        self.session = session
        self.requestIDFactory = requestIDFactory
        self.sessionIdentity = sessionIdentity
    }

    // MARK: - GET projection

    func fetchProjection() async -> VoiceSharingMembership? {
        // Identity is taken FIRST and must be non-nil: an unauthenticated session cannot be attributed, so
        // it gets no request at all. The same value is re-checked after the credential await and after the
        // response — otherwise a sign-out that lands while we are fetching would apply the previous
        // account's projection.
        guard let identityAtStart = sessionIdentity() else { return nil }
        guard let request = await makeRequest(path: Self.projectionPath, method: "GET", body: nil) else { return nil }
        guard sessionIdentity() == identityAtStart else { return nil }
        do {
            let (data, response) = try await session.data(for: request)
            guard sessionIdentity() == identityAtStart else { return nil }
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 401 || http.statusCode == 403 {
                // Validate BEFORE the side effect, then report the bearer this request carried.
                guard sessionIdentity() == identityAtStart else { return nil }
                let rejected = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
                await tokenProvider.handleUnauthorized(rejectedToken: rejected)
            }
            guard http.statusCode == 200 else { return nil }
            return Self.decodeProjection(data)
        } catch {
            return nil
        }
    }

    // MARK: - POST enrollment / withdrawal

    /// An operation's identity and body are IMMUTABLE once created, so a lost response can be retried with
    /// the SAME `request_id` and body — which is what makes the server's idempotency rule reachable from the
    /// public API. Minting a fresh UUID per call would defeat it: every retry would read as new intent, and
    /// a delayed first delivery could no longer be recognised as a request the server already served.
    struct MutationOperation {
        let requestID: String
        let path: String
        /// Body must never contain credential material; it carries only contract fields.
        let body: [String: Any]
        /// Non-secret generation of the session that BEGAN this operation, retained across retries. A
        /// `perform` under a different current generation refuses before touching the transport, so account
        /// A's enrollment/withdrawal/deletion intent can never be sent while account B is signed in.
        let originatingGeneration: SessionIdentity
    }

    /// One enrollment operation. Retry by calling `perform(_:)` again with the SAME operation (bounded
    /// backoff), never by beginning another.
    func beginEnrollment(acceptedDisclosureVersion: String, expectedMembershipRevision: String) -> MutationOperation? {
        guard let generation = sessionIdentity() else { return nil }
        let id = requestIDFactory()
        return MutationOperation(
            requestID: id,
            path: Self.enrollmentPath,
            body: [
                Field.requestId: id,
                Field.expectedRevision: expectedMembershipRevision,
                Field.acceptedDisclosure: acceptedDisclosureVersion,
            ],
            originatingGeneration: generation
        )
    }

    /// `epoch` is nullable BY CONTRACT: null is valid only when the expected projection has no active
    /// epoch, which is what lets an opt-out invalidate an outstanding opt-in. Neither form may withdraw a
    /// later enrollment — that ordering is enforced server-side by the revision check.
    func beginWithdrawal(enrollmentEpoch: String?, expectedMembershipRevision: String) -> MutationOperation? {
        guard let generation = sessionIdentity() else { return nil }
        let id = requestIDFactory()
        var body: [String: Any] = [
            Field.requestId: id,
            Field.expectedRevision: expectedMembershipRevision,
        ]
        // Explicit null on the wire when absent, so "no active epoch" is stated rather than omitted.
        body[Field.epoch] = enrollmentEpoch ?? NSNull()
        return MutationOperation(requestID: id, path: Self.withdrawalPath, body: body, originatingGeneration: generation)
    }

    /// Performs an operation. Safe to call again with the SAME operation to retry a lost response: the
    /// request_id and body are unchanged, so the server's idempotency rule applies instead of a second
    /// mutation being recorded.
    func perform(_ operation: MutationOperation) async -> VoiceSharingMutationOutcome {
        // Refusal happens BEFORE any transport work: sending A's intent under B's credential would attribute
        // one account's mutation to another, and the server cannot tell the difference.
        guard sessionIdentity() == operation.originatingGeneration else { return .refusedStaleSession }
        guard !operation.body.keys.contains(where: { $0.lowercased().contains("token") || $0.lowercased().contains("credential") }) else {
            // Defensive: an operation body must never carry secret material in the first place.
            return .unavailableBackend
        }
        return await mutate(path: operation.path, body: operation.body, originatingGeneration: operation.originatingGeneration)
    }


    // MARK: - DELETE accepted data (separate operation, separate request identity)

    /// Deletion carries its own immutable request identity; retrying an unknown outcome must reuse BOTH the
    /// original request_id and the original cutoff, since retries keep the same request identity per spec.
    struct DeletionOperation {
        let requestID: String
        let body: [String: Any]
        let originatingGeneration: SessionIdentity
    }

    func beginDeletion() -> DeletionOperation? {
        guard let generation = sessionIdentity() else { return nil }
        let id = requestIDFactory()
        return DeletionOperation(requestID: id, body: [Field.requestId: id], originatingGeneration: generation)
    }

    /// Requires an explicit operation: there is no implicit "begin + send" form, because an unknown outcome
    /// must be retried with the SAME identity and cutoff rather than re-minted here.
    func performDeletion(_ operation: DeletionOperation) async -> VoiceSharingDeletionOutcome {
        // Identity fence FIRST, before the credential await inside makeRequest — otherwise a transition that
        // lands during token acquisition would go unnoticed by this path.
        guard sessionIdentity() == operation.originatingGeneration else { return .unavailableBackend }
        guard let request = await makeRequest(
            path: Self.dataPath,
            method: "DELETE",
            body: op_body(of: operation)
        ) else { return .unavailableBackend }
        guard sessionIdentity() == operation.originatingGeneration else { return .unavailableBackend }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailableBackend }
            switch http.statusCode {
            case 202:
                // A receipt is only a receipt if it says so in the contracted shape: schema_version 1,
                // status exactly `deletion_pending`, and a non-empty opaque identifier. Anything else is an
                // unknown outcome (retryable with the SAME operation), never a success to display.
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Self.isExactInteger(object[Field.schemaVersion], 1),
                      (object[Field.status] as? String) == "deletion_pending",
                      let id = Self.nonEmptyString(object[Field.deletionRequestId])
                else { return .unavailableBackend }
                // Deletion is scoped to the account that asked for it. If the user changed while this was in
                // flight, applying the receipt would attribute one account's deletion to another.
                guard sessionIdentity() == operation.originatingGeneration else { return .unavailableBackend }
                return .pending(deletionRequestId: id)
            case 401:
                // Validate the captured generation BEFORE any side effect, then report the actual bearer.
                guard sessionIdentity() == operation.originatingGeneration else { return .unavailableBackend }
                await tokenProvider.handleUnauthorized(rejectedToken: request.value(forHTTPHeaderField: "Authorization")?
                    .replacingOccurrences(of: "Bearer ", with: ""))
                return .unauthorized
            case 403: return .refused(reason: .ineligible)
            case 422: return .refused(reason: .invalidRequest)
            default: return .unavailableBackend
            }
        } catch {
            return .unavailableBackend
        }
    }

    // MARK: - Shared mutation path

    private func mutate(path: String, body: [String: Any], originatingGeneration: SessionIdentity) async -> VoiceSharingMutationOutcome {
        // The operation's own generation is the authority; `identityAtStart` is only the value observed right
        // now, and both must agree before anything is sent.
        guard sessionIdentity() == originatingGeneration else { return .refusedStaleSession }
        guard let request = await makeRequest(path: path, method: "POST", body: body) else {
            return .unavailableBackend
        }
        guard sessionIdentity() == originatingGeneration else { return .refusedStaleSession }
        // NOTE: `mutate` is entered only after makeRequest() succeeded, which already required a non-nil
        // identity; callers capture it before the credential await and pass it in so every comparison uses
        // the same pre-await value rather than one read after network work began.
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailableBackend }
            switch http.statusCode {
            case 200:
                guard let projection = Self.decodeProjection(data) else { return .unavailableBackend }
                guard sessionIdentity() == originatingGeneration else { return .refusedStaleSession }
                return .applied(projection)
            case 409:
                // A conflict carries the current projection. Surfacing it is required so the caller can show
                // the real state; auto-replaying against the newer revision is forbidden.
                let current = Self.decodeProjection(data)
                guard sessionIdentity() == originatingGeneration else { return .refusedStaleSession }
                return .conflict(current: current)
            case 401:
                // Order matters twice here. Validate the captured generation FIRST so a 401 that belongs to
                // account A cannot invalidate account B's freshly-installed credential. Then report the
                // bearer THIS request actually carried — passing nil would fail every other cached token.
                guard sessionIdentity() == originatingGeneration else { return .refusedStaleSession }
                let rejected = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
                await tokenProvider.handleUnauthorized(rejectedToken: rejected)
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

    /// Builds the request. Callers capture session identity BEFORE awaiting here, because the credential
    /// fetch is a suspension point where an account transition can land; this function never reads identity
    /// itself, so there is exactly one pre-await capture per operation.
    private func op_body(of operation: DeletionOperation) -> [String: Any] { operation.body }

    private func makeRequest(path: String, method: String, body: [String: Any]?) async -> URLRequest? {
        let base = baseURLProvider()
        guard !base.isEmpty, let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.defaultTimeoutSeconds
        // Fail closed without a credential: no bearer, no call. Never fall back to a client-supplied
        // identity — the server scopes ownership from the authenticated account.
        guard let credential = await tokenProvider.token(), !credential.isEmpty else { return nil }
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
    /// Strict decoding. Every rule below exists because a lenient read would hand permission to something
    /// the server never granted, so each failure returns nil rather than a default.
    ///
    /// Type strictness matters on this specific wire: `JSONSerialization` bridges JSON booleans to NSNumber,
    /// and Swift's `as? Bool` will happily bridge an INTEGER (0/1) to Bool. A numeric publication must not
    /// authorize collection, so booleans are checked as genuine boolean objects before use.
    static func decodeProjection(_ data: Data) -> VoiceSharingMembership? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // schema_version must be exactly the integer 1 — not "1", not 1.0, not absent.
        guard Self.isExactInteger(object[Field.schemaVersion], 1) else { return nil }

        guard let revision = nonEmptyString(object[Field.membershipRevision]) else { return nil }
        guard let planRaw = nonEmptyString(object[Field.plan]), let plan = VoiceSharingMembership.Plan(rawValue: planRaw) else { return nil }
        guard let enrolled = strictBool(object[Field.enrolled]) else { return nil }
        guard let withdrawalRaw = nonEmptyString(object[Field.withdrawalState]),
              let withdrawal = VoiceSharingMembership.WithdrawalState(rawValue: withdrawalRaw) else { return nil }

        // Epoch / disclosure: absent means NSNull or missing; present must be non-empty text.
        let epoch: String?
        switch object[Field.epoch] {
        case nil, is NSNull: epoch = nil
        case let e as String where !e.trimmingCharacters(in: .whitespaces).isEmpty: epoch = e
        default: return nil
        }
        let disclosure: String?
        switch object[Field.acceptedDisclosure] {
        case nil, is NSNull: disclosure = nil
        case let d as String where !d.trimmingCharacters(in: .whitespaces).isEmpty: disclosure = d
        default: return nil
        }

        // Consistency rules — an impossible combination is unknown state, never permission:
        //  * active withdrawal_state with enrolled=false contradicts itself;
        //  * enrollment without an epoch cannot authorize collection (records key on the epoch);
        //  * an ACTIVE enrollment must carry the disclosure version it accepted;
        //  * withdrawn/not_enrolled must not still claim enrollment.
        if withdrawal == .active && !enrolled { return nil }
        if enrolled && epoch == nil { return nil }
        if enrolled && withdrawal == .withdrawn { return nil }
        if enrolled && withdrawal == .notEnrolled { return nil }
        if withdrawal == .active && disclosure == nil { return nil }

        return VoiceSharingMembership(
            membershipRevision: revision,
            plan: plan,
            voiceSharingEnrolled: enrolled,
            enrollmentEpoch: epoch,
            acceptedDisclosureVersion: disclosure,
            withdrawalState: withdrawal
        )
    }

    /// Exact integer match. `intValue` truncates (1.5 → 1) and `as? Int` bridges a Bool, so both are
    /// rejected: the value must be a real number whose value is exactly the expected integer.
    static func isExactInteger(_ value: Any?, _ expected: Int) -> Bool {
        guard let number = value as? NSNumber else { return false }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.compare(NSNumber(value: expected)) == .orderedSame
    }

    /// Non-empty trimmed string or nil; whitespace-only never counts as present.
    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : s
    }

    /// Accepts only a genuine boolean object. An NSNumber holding 0/1 is REJECTED: JSONSerialization bridges
    /// integers through `as? Bool`, so a permissive cast would let a numeric publication enable uploads.
    static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func refusalReason(from data: Data) -> VoiceSharingMutationOutcome.RefusalReason {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["error"] as? String else { return .invalidRequest }
        if code.contains("disclosure") { return .unsupportedDisclosure }
        if code.contains("ineligible") { return .ineligible }
        return .invalidRequest
    }
}
