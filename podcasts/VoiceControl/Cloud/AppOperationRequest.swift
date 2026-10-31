import Foundation

/// The client side of the app-operation REQUEST contract (cloud-assistant.md @ bf5fb219).
///
/// Two rules the amendment states that a permissive parser silently breaks:
///
/// 1. **Bounded envelope.** A complete action frame is at most 16 KiB of UTF-8. Oversize input
///    is refused BEFORE it is decoded, so an oversize frame can neither execute nor settle a
///    success — the cost of discovering it later is an effect nobody bounded.
/// 2. **Identity is a pair.** `operation_id` and `capability_version` are both required. An
///    action frame carrying one without the other is MALFORMED, not a legacy playback frame:
///    treating an incomplete pair as legacy is how a new-protocol operation slips into the old
///    execution path with no identity at all.
enum AppOperationRequest {
    /// The amendment's bound on a complete serialized request envelope.
    static let maxEnvelopeBytes = 16 * 1024
    /// The pinned capability version.
    static let capabilityVersion = "app-ops/1"

    /// Why a request was not admitted. Nothing here executes.
    enum Refusal: Error, Equatable {
        /// The serialized frame exceeded the envelope bound (or was not whole UTF-8).
        case envelopeTooLarge(bytes: Int)
        /// `operation_id` and `capability_version` were not both present and well formed.
        case incompleteIdentity
        /// The frame is not a JSON object at all.
        case malformedFrame
    }

    /// The admitted parts of an app-operation action.
    struct Admitted: Equatable {
        let operationId: String
        let capabilityVersion: String
        /// The EXACT bytes the server sent for this action, kept verbatim as the replay
        /// identity: a redelivery must reproduce them byte-for-byte, so they are never
        /// re-serialized from parsed parts.
        let actionBytes: Data
    }

    /// How a control-envelope frame relates to the v1 app-operation identity.
    ///
    /// This is the BOUNDED top-level detection the parser must make, and there are exactly three
    /// answers. The middle one is the one that matters: a frame declaring part of the identity is
    /// an app-operation attempt that failed, never a legacy frame.
    enum IdentityClassification {
        /// Both `operation_id` and `capability_version` are present, non-empty strings. Carries
        /// the admitted identity, including the exact replay bytes.
        case identified(Admitted)
        /// At least one identity field is present but the pair is not complete and well formed.
        /// NO event may be produced for this frame: it must not reach a sink, and it must not
        /// fall back to the playback effect path.
        case malformedIdentity
        /// Neither identity field appears at all. This is a pre-v1 playback frame.
        case unidentified
    }

    /// Detects whether an already-parsed frame declares the v1 app-operation identity.
    ///
    /// `payloadBytes` must be the value produced by `actionPayloadBytes(rawFrame:)` — the single
    /// definition of where an action payload begins and ends — so that the bytes carried as
    /// replay identity are the same bytes for a live frame and for a persisted one.
    static func classify(json: [String: Any], payloadBytes: Data) -> IdentityClassification {
        let hasOperationId = json["operation_id"] != nil
        let hasCapabilityVersion = json["capability_version"] != nil
        guard hasOperationId || hasCapabilityVersion else { return .unidentified }
        // The wire pins exactly these: `operation_id` is a server-issued UUID and
        // `capability_version` is `app-ops/1`. "Any non-empty string" would admit `op-1` and a
        // made-up version, i.e. accept a frame no conforming server can send and then journal an
        // operation under an identity that means nothing. Both are validated here, before kinds.
        guard let operationId = json["operation_id"] as? String, isOperationUUID(operationId),
              let capabilityVersion = json["capability_version"] as? String,
              capabilityVersion == Self.capabilityVersion
        else { return .malformedIdentity }
        // The frame must also be the kind the contract describes.
        guard json["type"] as? String == "action" else { return .malformedIdentity }
        return .identified(
            Admitted(
                operationId: operationId,
                capabilityVersion: capabilityVersion,
                actionBytes: payloadBytes
            )
        )
    }

    /// Decoding a frame as JSON is NOT validating a parameter against its declared type.
    ///
    /// These are two separate steps, and collapsing them is how a wrong-typed value reaches an
    /// effect: `JSONSerialization` will happily hand back `"5"` for a field the sink reads with
    /// `.int64Value`, and the sink then treats a malformed request as a five-second seek. So
    /// decoding stays generic (`CloudRouteJSONValue`), and admission validates per action against
    /// an explicit declaration.
    ///
    /// Only actions this build can actually execute are declared. An action with no declaration
    /// is not executable here and is refused `unsupported_operation`, which is a DIFFERENT answer
    /// from an invalid request and is kept separate on purpose.
    enum ActionParameter: Equatable {
        /// A JSON integer (`Int64`-representable number), never a boolean or a string.
        case integer
        /// A JSON number, integer or fractional — but never a boolean.
        case number
        /// A JSON string.
        case string
        /// A JSON string restricted to the enumerated values. Used for fields the sink reads as a
        /// closed set: anything outside it is not a value the action can act on.
        case enumerated(Set<String>)
        /// A non-empty JSON string used as an identity (episode id, and the like). Blank is not an
        /// identity, so it is rejected with the same force as a wrong type.
        case identity
    }

    /// One action's admission contract, stated in the wire's own terms.
    struct ActionContract {
        /// Every field the action reads, with the JSON kind it must arrive as.
        let parameters: [String: ActionParameter]
        /// Fields that must be PRESENT. No nullable escape: the wire's rule is that an absent
        /// required field is `invalid_request`, refused before any effect — the action never
        /// applies a default its sink does not have.
        let required: Set<String>
        /// Target identities the action cannot execute against without, read from `precondition`.
        /// Required for episode-relative actions even though `precondition` is optional globally.
        let requiredPreconditions: Set<String>

        init(parameters: [String: ActionParameter], required: Set<String> = [],
             requiredPreconditions: Set<String> = []) {
            self.parameters = parameters
            self.required = required
            self.requiredPreconditions = requiredPreconditions
        }
    }

    /// The executable playback actions and their exact parameter/precondition contracts.
    ///
    /// Derived from the sink's own switch, not invented. Every episode-relative action here
    /// requires the target episode's identity, because acting on "whichever episode is now
    /// active" is exactly the staleness the wire contract forbids: the proposal was formed for an
    /// episode, and if that episode is no longer the target the honest answer is a refusal, not a
    /// seek applied to a different recording.
    static let actionContracts: [String: ActionContract] = [
        // Exactly one numeric target form: `position_seconds` OR `reference_position_ms`.
        // Supplying neither, or both, is ambiguous and refused (`malformed_seek_target`).
        "seek_to": ActionContract(
            parameters: ["position_seconds": .number, "reference_position_ms": .number],
            requiredPreconditions: ["episode_id"]
        ),
        "play_quote": ActionContract(
            parameters: ["reference_position_ms": .number],
            required: ["reference_position_ms"],
            requiredPreconditions: ["episode_id"]
        ),
        "stop_quote": ActionContract(parameters: [:], requiredPreconditions: ["episode_id"]),
        // Direction-only seeks carry a declared direction from a closed set; a numeric delta, when
        // present, states the amount and the sink derives direction from its sign.
        "seek_relative": ActionContract(
            parameters: ["delta_seconds": .integer,
                         "direction": .enumerated(["forward", "backward"])],
            requiredPreconditions: ["episode_id"]
        ),
        // Pause/resume act on the engine, not on a chosen episode: no target identity to require.
        "pause": ActionContract(parameters: [:]),
        "resume": ActionContract(parameters: [:]),
    ]

    /// Why a declared parameter bag did not match its action contract. Each case is a distinct
    /// malformation, so a failure report can say which rule refused it.
    enum ParameterViolation: Error, Equatable {
        /// The action is not executable in this build — a DIFFERENT answer from an invalid
        /// request, and settled separately.
        case unsupportedAction(String)
        /// A field is present with a JSON kind (or enum value) the action does not accept.
        case wrongType(field: String)
        /// A field the action cannot work without is absent.
        case missingField(String)
        /// A target identity the action cannot execute against is absent from the precondition.
        case missingPrecondition(String)
        /// `seek_to` supplied both target forms, or neither: ambiguous, so refused rather than
        /// resolved by a preference.
        case ambiguousSeekTarget
        /// The precondition's episode identity is not the episode currently targeted.
        case stalePrecondition
    }

    /// Validates one action's params and preconditions against its declaration.
    ///
    /// `params`/`precondition` are the already-decoded bags; this only judges them. Unknown extra
    /// fields are allowed through (the wire does not forbid the server adding one), but a declared
    /// field with the wrong kind is refused — silently reinterpreting it is precisely the coercion
    /// the contract forbids.
    ///
    /// `currentEpisodeId` answers "what is the live target", and there are THREE answers, not two:
    ///
    /// - `.available(id)` — evaluated; a stated episode that differs is stale.
    /// - `.absent` — evaluated; there is no current episode, so nothing can match and the proposal
    ///   is stale. This is a FACT the caller observed.
    /// - `.notEvaluated` — this caller does not own playback state, so the question was not asked.
    ///   Structure, types and required identities are still validated; the live target match is
    ///   left to the caller who can answer it.
    ///
    /// Collapsing `.notEvaluated` into `.absent` is the v5 defect: the parser, which knows nothing
    /// about playback, would report every well-formed episode-relative request as stale — and the
    /// sink would then refuse a request whose live target actually matched.
    enum TargetMatch {
        case notEvaluated
        case absent
        case available(String)
    }

    static func validate(
        action: String,
        params: [String: CloudRouteJSONValue],
        precondition: [String: CloudRouteJSONValue],
        target: TargetMatch = .notEvaluated
    ) -> Result<Void, ParameterViolation> {
        guard let contract = actionContracts[action] else {
            // Not executable here. The server is still TOLD — the sink claims and settles
            // `unsupported_operation` — so this is a distinct classification, never a silent drop.
            return .failure(.unsupportedAction(action))
        }
        for (field, declared) in contract.parameters.sorted(by: { $0.key < $1.key }) {
            guard let value = params[field] else { continue }
            guard value.matches(declared) else { return .failure(.wrongType(field: field)) }
        }
        for field in contract.required.sorted() where params[field] == nil {
            return .failure(.missingField(field))
        }
        // seek_to's two target forms are mutually exclusive; exactly one must be stated.
        if action == "seek_to" {
            let forms = contract.parameters.keys.filter { params[$0] != nil }
            guard forms.count == 1 else { return .failure(.ambiguousSeekTarget) }
        }
        // REQUIRED TARGET IDENTITIES. Absent, null, blank or non-string are all "no identity was
        // stated", which is the wire's `invalid_request` — the action cannot be attributed to a
        // target, so it is refused before any effect.
        var statedIdentities: [String: String] = [:]
        for field in contract.requiredPreconditions.sorted() {
            guard let stated = precondition[field]?.identityValue, !stated.isEmpty else {
                return .failure(.missingPrecondition(field))
            }
            statedIdentities[field] = stated
        }
        // CURRENT-TARGET MATCH — only when the caller can answer the question. `.notEvaluated`
        // means this caller does not own playback state (the parser), so the match is left to the
        // sink; treating it as "no current episode" would refuse every valid request at the
        // parser and prevent the sink from ever seeing a request it should run.
        if let statedEpisode = statedIdentities["episode_id"] {
            switch target {
            case .notEvaluated:
                break
            case .absent:
                return .failure(.stalePrecondition)
            case let .available(current) where current != statedEpisode:
                return .failure(.stalePrecondition)
            case .available:
                break
            }
        }
        return .success(())
    }

    /// True when the frame's `params`/`precondition` are JSON OBJECTS (or absent), which is the
    /// only structural precondition for admission. Type validation is per action, in `validate`:
    /// this deliberately does not pre-judge field types, so the two steps stay separable.
    static func typedParams(_ json: [String: Any]) -> [String: Any]? {
        guard let params = json["params"] else { return [:] }
        return params as? [String: Any]
    }

    static func typedPrecondition(_ json: [String: Any]) -> [String: Any]? {
        guard let precondition = json["precondition"] else { return [:] }
        return precondition as? [String: Any]
    }

    /// A server-issued operation ID: a canonical, case-insensitive UUID string.
    ///
    /// Uniqueness is the server's job; what the client can and must enforce is the SHAPE, because
    /// an ID that is not a UUID cannot be an identity the server issued for this turn.
    static func isOperationUUID(_ value: String) -> Bool {
        // Exactly the canonical 8-4-4-4-12 form. `UUID(uuidString:)` alone also accepts lowercase,
        // which is fine; it rejects a missing-hyphen or any wrong-grouping variant.
        guard value.count == 36 else { return false }
        let groups = value.split(separator: "-", omittingEmptySubsequences: false).map(\.count)
        guard groups == [8, 4, 4, 4, 12] else { return false }
        return UUID(uuidString: value) != nil
    }

    /// THE single definition of the action-payload byte boundary.
    ///
    /// Server-serialized action bytes EXCLUDE transport framing but INCLUDE the payload's own
    /// whitespace, so this must not re-serialize and must not trim. One extractor defines the
    /// boundary for both the live receive path and anything replaying a persisted record; two
    /// extractors is how the same operation acquires two identities.
    ///
    /// Returns nil unless the frame carries EXACTLY ONE complete JSON object. A `first {` to
    /// `last }` search cannot tell one object from two concatenated ones (`{...}{...}`) and cannot
    /// tell a payload from one followed by trailing junk; both would yield bytes that are not what
    /// the server sent, and a replay keyed on them would silently never match.
    static func actionPayloadBytes(rawFrame: Data) -> Data? {
        guard let text = String(data: rawFrame, encoding: .utf8) else { return nil }
        if let framed = legacyEventDataPayload(in: text) { return framed }

        // No legacy framing present: the frame must be exactly one JSON object, optionally
        // surrounded by insignificant whitespace, which `JSONSerialization` already requires.
        let trimmed = text.drop(while: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
        let start = trimmed.firstIndex(of: "{") ?? trimmed.startIndex
        let candidate = String(trimmed[start...])
        guard !candidate.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)),
              parsed is [String: Any]
        else { return nil }
        // Preserved verbatim — including the payload's own leading whitespace relative to the
        // object and all interior whitespace — because replay is byte equality.
        return Data(candidate.utf8)
    }

    /// The PRE-EXISTING transport boundary for a legacy SSE frame, reused rather than reinvented.
    ///
    /// A legacy frame is `event: <name>` / `data: <json>` line pairs. The payload boundary here is
    /// the transport's own — take the `data:` line's value — not a brace search inside it. Returns
    /// nil when the frame carries no `event:`/`data:` framing at all, so a plain JSON frame is
    /// handled by the branch above instead of being guessed at.
    private static func legacyEventDataPayload(in text: String) -> Data? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let hasFraming = lines.contains { $0.hasPrefix("event:") } || lines.contains { $0.hasPrefix("data:") }
        guard hasFraming else { return nil }
        // Exactly one `data:` line: two would be two payloads, which is not a single action frame.
        let dataLines = lines.filter { $0.hasPrefix("data:") }
        guard dataLines.count == 1 else { return nil }
        let value = dataLines[0].dropFirst("data:".count)
        let payload = value.drop(while: { $0 == " " })
        guard !payload.isEmpty, payload.first == "{" else { return nil }
        return Data(payload.utf8)
    }

    /// The envelope bound alone, checked on received bytes BEFORE any JSON decoder runs.
    ///
    /// Separate from `admit(rawBytes:)` so the live parser can refuse an oversize frame without
    /// the frame first having to be identified — a bound that only applies once the payload has
    /// been parsed is not a bound.
    static func admitEnvelopeSize(rawBytes: Data) -> Result<Void, Refusal> {
        guard rawBytes.count <= maxEnvelopeBytes else {
            return .failure(.envelopeTooLarge(bytes: rawBytes.count))
        }
        return .success(())
    }

    /// Admits a raw action frame for an app operation, or refuses it with the reason.
    ///
    /// The order matters: the size bound is checked on the BYTES before any decoding, so an
    /// oversize payload never reaches the JSON parser.
    static func admit(rawBytes: Data) -> Result<Admitted, Refusal> {
        guard rawBytes.count <= maxEnvelopeBytes else {
            return .failure(.envelopeTooLarge(bytes: rawBytes.count))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: rawBytes)) as? [String: Any] else {
            return .failure(.malformedFrame)
        }
        guard let operationId = json["operation_id"] as? String, !operationId.isEmpty,
              let capabilityVersion = json["capability_version"] as? String,
              !capabilityVersion.isEmpty
        else {
            return .failure(.incompleteIdentity)
        }
        return .success(
            Admitted(
                operationId: operationId,
                capabilityVersion: capabilityVersion,
                actionBytes: rawBytes
            )
        )
    }
}