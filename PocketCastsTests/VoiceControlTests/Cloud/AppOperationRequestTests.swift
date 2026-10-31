import XCTest
@testable import podcasts

/// The app-operation REQUEST contract (cloud-assistant.md @ bf5fb219), enforced before anything
/// is admitted for execution. Two rules, deliberately tested at the byte level because both are
/// about what a permissive parser would let through:
///
/// * the envelope bound, checked on the received bytes BEFORE decoding;
/// * identity as a PAIR — an incomplete `operation_id`/`capability_version` is malformed, never
///   a legacy playback frame.
final class AppOperationRequestTests: XCTestCase {

    private func frame(_ body: String) -> Data { Data(body.utf8) }

    // MARK: - the envelope bound

    /// 16 KiB is the bound: a frame at the bound is admitted, one byte over is refused.
    func test_envelopeBoundIsInclusiveAndRefusesOversize() {
        let padding = String(repeating: "x", count: 200)
        let base = #"{"operation_id":"bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f","capability_version":"app-ops/1","tool":"playback","action":"pause","pad":""#
            + padding + #""}"#
        // The reachable exact-bound path: pad to exactly 16384 bytes, then one more.
        var body = base
        let shortfall = AppOperationRequest.maxEnvelopeBytes - body.utf8.count
        XCTAssertGreaterThan(shortfall, 0, "the fixture must start under the bound")
        body = String(body.dropLast(2)) + String(repeating: "x", count: shortfall) + #""}"#
        XCTAssertEqual(body.utf8.count, AppOperationRequest.maxEnvelopeBytes)

        switch AppOperationRequest.admit(rawBytes: frame(body)) {
        case .success(let admitted):
            XCTAssertEqual(admitted.operationId, "bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f")
        case .failure(let refusal):
            XCTFail("a frame exactly at the bound must be admitted, got \(refusal)")
        }

        let oversize = body.dropLast(2) + "x" + #""}"#
        XCTAssertEqual(oversize.utf8.count, AppOperationRequest.maxEnvelopeBytes + 1)
        XCTAssertEqual(
            AppOperationRequest.admit(rawBytes: frame(String(oversize))),
            .failure(.envelopeTooLarge(bytes: AppOperationRequest.maxEnvelopeBytes + 1))
        )
    }

    /// The size check precedes decoding: an oversize frame that is not even JSON is refused as
    /// oversize, so an unbounded payload never reaches the parser.
    func test_oversizeIsRefusedBeforeDecoding() {
        let junk = String(repeating: "z", count: AppOperationRequest.maxEnvelopeBytes + 10)
        XCTAssertEqual(
            AppOperationRequest.admit(rawBytes: frame(junk)),
            .failure(.envelopeTooLarge(bytes: AppOperationRequest.maxEnvelopeBytes + 10))
        )
    }

    // MARK: - identity is a pair

    /// Both identity fields present and non-empty: admitted, with the ORIGINAL bytes kept as
    /// replay identity.
    func test_completeIdentityIsAdmittedWithTheOriginalBytes() {
        let bytes = frame(#"{"operation_id":"bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f","capability_version":"app-ops/1","tool":"playback","action":"pause"}"#)
        guard case .success(let admitted) = AppOperationRequest.admit(rawBytes: bytes) else {
            return XCTFail("a complete identity must be admitted")
        }
        XCTAssertEqual(admitted.operationId, "bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f")
        XCTAssertEqual(admitted.capabilityVersion, "app-ops/1")
        XCTAssertEqual(admitted.actionBytes, bytes, "replay identity is the exact received bytes")
    }

    /// The incomplete pair is MALFORMED — the amendment is explicit that it is not legacy
    /// playback. Each half missing, empty, or the wrong type is refused.
    func test_incompleteIdentityPairIsMalformed() {
        let cases: [(String, String)] = [
            ("no capability", #"{"operation_id":"bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f","tool":"playback","action":"pause"}"#),
            ("no operation id", #"{"capability_version":"app-ops/1","tool":"playback","action":"pause"}"#),
            ("empty capability", #"{"operation_id":"bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f","capability_version":"","tool":"playback","action":"pause"}"#),
            ("empty operation id", #"{"operation_id":"","capability_version":"app-ops/1","tool":"playback","action":"pause"}"#),
            ("numeric operation id", #"{"operation_id":7,"capability_version":"app-ops/1","tool":"playback","action":"pause"}"#),
            ("numeric capability", #"{"operation_id":"bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f","capability_version":1,"tool":"playback","action":"pause"}"#),
        ]
        for (label, body) in cases {
            XCTAssertEqual(
                AppOperationRequest.admit(rawBytes: frame(body)),
                .failure(.incompleteIdentity),
                "\(label) must be refused as an incomplete identity pair"
            )
        }
    }

    /// A non-object payload is a malformed frame, not an identity problem.
    func test_nonObjectPayloadIsMalformed() {
        for body in ["[]", "\"bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f\"", "not json at all"] {
            XCTAssertEqual(
                AppOperationRequest.admit(rawBytes: frame(body)),
                .failure(.malformedFrame),
                "payload \(body) is not an action frame"
            )
        }
    }

    // MARK: - the gate is ON the live receive path

    /// The bound and the identity pair are enforced where frames actually arrive, so these are
    /// assertions about what a sink can possibly be handed, not about a helper nobody calls.
    func testLiveParseRefusesAnIdentifiedFrameWithAnIncompletePair() {
        let events = CloudRouteClient.parseTextFrame(
            #"{"type":"action","operation_id":"bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f","tool":"playback","action":"pause"}"#
        )
        XCTAssertEqual(events.count, 0, "an identified frame with no capability_version must not reach a sink")
    }

    func testLiveParseRefusesAnIdentifiedFrameOverTheEnvelopeBound() {
        let padding = String(repeating: "x", count: AppOperationRequest.maxEnvelopeBytes)
        let frame = #"{"type":"action","operation_id":"bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f","capability_version":"app-ops/1","pad":""#
            + padding + #""}"#
        XCTAssertEqual(CloudRouteClient.parseTextFrame(frame).count, 0,
                       "an oversize identified frame must not reach a sink")
    }

    /// The un-identified playback path is unchanged: this bound governs APP OPERATIONS, and a
    /// plain audio/playback frame carrying no identity still parses as it always did.
    func testLiveParseStillAcceptsAnUnidentifiedPlaybackFrame() {
        let events = CloudRouteClient.parseTextFrame(
            #"{"type":"action","tool":"playback","action":"pause"}"#
        )
        XCTAssertTrue(events.contains { if case .action = $0 { return true }; return false },
                      "a legacy playback action frame must still be received")
    }

    /// An admitted frame reaches the sink with the EXACT received bytes, which is the identity a
    /// redelivery must reproduce.
    func testLiveParseCarriesTheExactReceivedBytesForAnAdmittedOperation() throws {
        let payload = #"{"type":"action","operation_id":"6d99ef9f-3c66-4b45-a182-6886927d01a9",  "capability_version":"app-ops/1","tool":"playback","action":"pause"}"#
        let events = CloudRouteClient.parseTextFrame(payload)
        let action = try XCTUnwrap(events.compactMap { event -> CloudRouteEvent? in
            if case .action = event { return event }
            return nil
        }.first)
        guard case .action(tool: _, action: _, params: _, operationId: let operationId,
                           capabilityVersion: _, actionBytes: let raw, precondition: _,
                           parameterViolation: _) = action else {
            return XCTFail("expected an action event")
        }
        XCTAssertEqual(operationId, "6d99ef9f-3c66-4b45-a182-6886927d01a9")
        XCTAssertEqual(raw, Data(payload.utf8), "identity is the received bytes, never a re-encoding")
    }

    // MARK: - the bound is enforced BEFORE the first JSON decoder

    /// The bound must reject on the BYTES. An oversize frame that is not even JSON is the control:
    /// if size were checked after decoding it would surface as `malformedFrame`, so the reason
    /// proves the order. Exercised through the live entry point the socket uses.
    func testOversizeIsRejectedBeforeAnyDecoderRunsOnTheLivePath() {
        let oversizeJunk = String(repeating: "z", count: AppOperationRequest.maxEnvelopeBytes + 1)
        XCTAssertEqual(CloudRouteClient.parseTextFrame(oversizeJunk).count, 0,
                       "an oversize frame must not survive to a decoder")
        // Directly: the size gate alone refuses it, without a parse attempt.
        // `Result<Void, _>` cannot be compared with XCTAssertEqual, so the refusal is matched.
        if case let .failure(refusal) = AppOperationRequest.admitEnvelopeSize(
            rawBytes: Data(oversizeJunk.utf8)) {
            XCTAssertEqual(refusal, .envelopeTooLarge(bytes: oversizeJunk.utf8.count))
        } else {
            XCTFail("an oversize envelope must be refused by the size gate alone")
        }
    }

    /// The bound applies to EVERY control frame, not only identified app operations — otherwise a
    /// payload could dodge the bound just by omitting `operation_id`.
    func testOversizeUnidentifiedFrameIsAlsoRefused() {
        let padding = String(repeating: "y", count: AppOperationRequest.maxEnvelopeBytes)
        let frame = #"{"type":"action","tool":"playback","action":"pause","pad":""# + padding + #""}"#
        XCTAssertEqual(CloudRouteClient.parseTextFrame(frame).count, 0,
                       "dropping the identity must not buy a frame a parse")
    }

    // MARK: - partial v1 never falls back to effects

    /// A frame carrying HALF the identity is an app-operation attempt that failed. It must produce
    /// no event at all — in particular it must not become an unidentified playback action that
    /// then executes as if it were a legacy frame.
    func testPartialIdentityNeverFallsBackToThePlaybackEffectPath() {
        let partials = [
            #"{"type":"action","operation_id":"bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f","tool":"playback","action":"pause"}"#,
            #"{"type":"action","capability_version":"app-ops/1","tool":"playback","action":"pause"}"#,
            #"{"type":"action","operation_id":"","capability_version":"app-ops/1","tool":"playback","action":"pause"}"#,
            #"{"type":"action","operation_id":"bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f","capability_version":"","tool":"playback","action":"pause"}"#,
            #"{"type":"action","operation_id":7,"capability_version":"app-ops/1","tool":"playback","action":"pause"}"#,
        ]
        for body in partials {
            let events = CloudRouteClient.parseTextFrame(body)
            XCTAssertEqual(events.count, 0, "partial v1 must yield no event: \(body)")
        }
    }

    /// The classification itself, stated at its own boundary.
    func testClassificationDistinguishesIdentifiedMalformedAndUnidentified() {
        let bytes = Data("{}".utf8)
        let uuid = "bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f"
        // No identity field of any kind: pre-v1 playback, even with no `type`.
        // Asserted with a case pattern: the classification enum is deliberately not Equatable,
        // and adding conformance to production code to serve a test would be the wrong direction.
        guard case .unidentified = AppOperationRequest.classify(
            json: ["tool": "playback", "action": "pause"], payloadBytes: bytes) else {
            return XCTFail("a frame with no identity field is pre-v1 playback")
        }
        guard case let .identified(admitted) = AppOperationRequest.classify(
            json: ["type": "action", "operation_id": uuid, "capability_version": "app-ops/1"],
            payloadBytes: bytes) else {
            return XCTFail("the published identity pair must be admitted")
        }
        // The full promise of `.identified`, not merely its case.
        XCTAssertEqual(admitted.operationId, uuid)
        XCTAssertEqual(admitted.capabilityVersion, "app-ops/1")
        XCTAssertEqual(admitted.actionBytes, bytes,
                       "identity is the received bytes, never a re-encoding")
    }

    /// Everything that is NOT the published identity pair is malformed. The negatives matter as
    /// much as the positive: each of these used to be admitted, and an admitted frame reaches a
    /// sink and journals an operation under an identity no conforming server issued.
    func testIdentityMustBeThePublishedUUIDAndVersion() {
        let uuid = "bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f"
        let bytes = Data("{}".utf8)
        let negatives: [[String: Any]] = [
            // half a pair
            ["type": "action", "operation_id": uuid],
            ["type": "action", "capability_version": "app-ops/1"],
            // empty / wrong-typed parts
            ["type": "action", "operation_id": "", "capability_version": "app-ops/1"],
            ["type": "action", "operation_id": 1, "capability_version": "app-ops/1"],
            // NOT a UUID — the shape the old parser accepted
            ["type": "action", "operation_id": "op-1", "capability_version": "app-ops/1"],
            ["type": "action", "operation_id": uuid.replacingOccurrences(of: "-", with: ""),
             "capability_version": "app-ops/1"],
            ["type": "action", "operation_id": "bdc53855-0a6a-4bd3-a1ea-fd9c8deecc",
             "capability_version": "app-ops/1"],
            // NOT the published version — likewise previously accepted
            ["type": "action", "operation_id": uuid, "capability_version": "v1"],
            ["type": "action", "operation_id": uuid, "capability_version": "v7"],
            // the wrong frame kind
            ["type": "app_operation", "operation_id": uuid, "capability_version": "app-ops/1"],
        ]
        for json in negatives {
            if case .malformedIdentity = AppOperationRequest.classify(json: json, payloadBytes: bytes) {
                continue
            }
            XCTFail("expected malformedIdentity for \(json)")
        }
    }

    /// The UUID shape rule stated on its own, including the forms it must reject.
    func testOperationUUIDShape() {
        XCTAssertTrue(AppOperationRequest.isOperationUUID("bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f"))
        XCTAssertTrue(AppOperationRequest.isOperationUUID("BDC53855-0A6A-4BD3-A1EA-FD9C8DEECC2F"))
        for bad in ["", "op-1", "bdc538550a6a4bd3a1eafd9c8deecc2f",
                    "bdc53855-0a6a-4bd3-a1ea-fd9c8deecc",
                    "bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f-",
                    "bdc5385-50a6a-4bd3-a1ea-fd9c8deecc2f",
                    "zzzzzzzz-0a6a-4bd3-a1ea-fd9c8deecc2f"] {
            XCTAssertFalse(AppOperationRequest.isOperationUUID(bad), "must reject \(bad)")
        }
    }

    /// DECODING is not VALIDATION — and the validation exercised here is the SHIPPED table, not a
    /// fabricated contract. Every case names a real action from `actionContracts`.
    func testShippedActionContractsEnforceDeclaredTypes() {
        let episode = ["episode_id": CloudRouteJSONValue.string("ep-1")]
        let cases: [(action: String, params: [String: Any], violation: AppOperationRequest.ParameterViolation?)] = [
            // positives: correctly typed
            ("seek_relative", ["delta_seconds": 5], nil),
            ("seek_relative", ["direction": "forward"], nil),
            ("seek_relative", ["direction": "backward"], nil),
            ("seek_to", ["position_seconds": 42], nil),
            ("play_quote", ["reference_position_ms": 1000], nil),
            ("pause", [:], nil),
            // negative: a STRING where a number is declared
            ("seek_relative", ["delta_seconds": "5"], .wrongType(field: "delta_seconds")),
            ("seek_to", ["position_seconds": "42"], .wrongType(field: "position_seconds")),
            // negative: a number where a string is declared
            ("seek_relative", ["direction": 1], .wrongType(field: "direction")),
            // negative: a boolean is never a number or a string
            ("seek_to", ["position_seconds": true], .wrongType(field: "position_seconds")),
            ("seek_relative", ["direction": true], .wrongType(field: "direction")),
            // negative: a value outside the declared direction enum
            ("seek_relative", ["direction": "sideways"], .wrongType(field: "direction")),
        ]
        for testCase in cases {
            let params = CloudRouteJSONValue.object(from: testCase.params)
            let outcome = AppOperationRequest.validate(
                action: testCase.action, params: params, precondition: episode,
                target: .available("ep-1"))
            switch (outcome, testCase.violation) {
            case (.success, nil):
                continue
            case let (.failure(actual), .some(expected)) where actual == expected:
                continue
            default:
                XCTFail("\(testCase.action) \(testCase.params): expected \(String(describing: testCase.violation)), got \(outcome)")
            }
        }
    }

    /// Every episode-relative action REQUIRES its target identity — the shipped table, not a
    /// stand-in. Missing, null, blank and wrong-typed are all "no identity stated".
    func testShippedContractsRequireTheTargetEpisodeIdentity() {
        for action in ["seek_to", "play_quote", "stop_quote", "seek_relative"] {
            assertViolation(.missingPrecondition("episode_id"), action: action,
                            params: Self.validParams(for: action),
                            precondition: [:],
                            message: "\(action) must require episode_id")
            // The same action WITH its identity is not refused for this reason.
            assertViolation(action: action, params: ["position_seconds": .int(1)],
                            precondition: ["episode_id": .string("ep-1")],
                            target: .available("ep-1"), isNot: .missingPrecondition("episode_id"),
                            message: "\(action) refused a stated episode identity")
        }
        // Absent / null / blank / wrong type all fail the identity check.
        for bad: [String: CloudRouteJSONValue] in [[:],
                                                   ["episode_id": .null],
                                                   ["episode_id": .string("")],
                                                   ["episode_id": .int(7)]] {
            // `validParams` keeps the SEARCH TARGET valid so the only failing element is the
            // identity: validate checks required params before preconditions, and a control that
            // also omitted those would report the earlier violation instead of this one.
            assertViolation(.missingPrecondition("episode_id"),
                            action: "seek_to",
                            params: Self.validParams(for: "seek_to"), precondition: bad,
                            message: "\(bad) is not a target identity")
        }
        // pause/resume address the engine, not a chosen episode: no identity required.
        assertSucceeds(action: "pause", params: [:], precondition: [:],
                       message: "pause addresses the engine")
        assertSucceeds(action: "resume", params: [:], precondition: [:],
                       message: "resume addresses the engine")
    }

    /// A proposal formed for an episode the user has since left is STALE, and that is a distinct
    /// refusal from "no identity stated".
    func testTargetThatIsNoLongerCurrentIsStale() {
        let precondition: [String: CloudRouteJSONValue] = ["episode_id": .string("ep-old")]
        assertViolation(.stalePrecondition, action: "seek_to",
                        params: ["position_seconds": .int(1)],
                        precondition: precondition, target: .available("ep-new"),
                        message: "a proposal for an episode the user left is stale")
        // Evaluated, and there is no current episode: nothing can match.
        assertViolation(.stalePrecondition, action: "seek_to",
                        params: ["position_seconds": .int(1)],
                        precondition: precondition, target: .absent,
                        message: "no current episode cannot match a stated one")
        // The matching case passes.
        assertSucceeds(action: "seek_to", params: ["position_seconds": .int(1)],
                       precondition: precondition, target: .available("ep-old"),
                       message: "the stated episode IS the current one")
    }

    /// NOT-EVALUATED is a third answer and must not be read as "no current episode". A caller
    /// that owns no playback state (the parser) validates structure, types and required
    /// identities — and must NOT conclude the target is stale, or every valid request would be
    /// refused before the sink that can actually answer ever sees it.
    func testNotEvaluatedTargetDoesNotProduceAStaleRefusal() {
        let precondition: [String: CloudRouteJSONValue] = ["episode_id": .string("ep-old")]
        assertSucceeds(action: "seek_to", params: ["position_seconds": .int(1)],
                       precondition: precondition, target: .notEvaluated,
                       message: "structure/type/identity passed; the live match is not this caller's question")
        // It still cannot rescue a genuine structural or identity problem.
        assertViolation(.missingPrecondition("episode_id"), action: "seek_to",
                        params: ["position_seconds": .int(1)],
                        precondition: [:], target: .notEvaluated,
                        message: "not-evaluated must not bypass the identity requirement")
        assertViolation(.wrongType(field: "position_seconds"), action: "seek_to",
                        params: ["position_seconds": .string("1")],
                        precondition: precondition, target: .notEvaluated,
                        message: "not-evaluated must not bypass type validation")
    }

    /// `seek_to` states EXACTLY ONE target form. Both, or neither, is ambiguous — never resolved
    /// by a preference, because the two forms are in different time bases.
    func testSeekToRequiresExactlyOneTargetForm() {
        let episode: [String: CloudRouteJSONValue] = ["episode_id": .string("ep-1")]
        assertViolation(.ambiguousSeekTarget, action: "seek_to", params: [:],
                        precondition: episode, target: .available("ep-1"),
                        message: "no target form is not a resolution")
        assertViolation(.ambiguousSeekTarget, action: "seek_to",
                        params: ["position_seconds": .int(95),
                                 "reference_position_ms": .int(200000)],
                        precondition: episode, target: .available("ep-1"),
                        message: "both target forms is ambiguous, never a preference")
        for params: [String: CloudRouteJSONValue] in [["position_seconds": .int(95)],
                                                      ["reference_position_ms": .int(200000)]] {
            assertSucceeds(action: "seek_to", params: params,
                           precondition: episode, target: .available("ep-1"),
                           message: "\(params) is exactly one target form")
        }
    }

    /// play_quote's reference target is REQUIRED, and required is required: absent is refused,
    /// and so is a null.
    func testPlayQuoteRequiresItsNumericReference() {
        let episode: [String: CloudRouteJSONValue] = ["episode_id": .string("ep-1")]
        assertViolation(.missingField("reference_position_ms"), action: "play_quote", params: [:],
                        precondition: episode, target: .available("ep-1"),
                        message: "the quote's reference is required")
        assertViolation(.wrongType(field: "reference_position_ms"), action: "play_quote",
                        params: ["reference_position_ms": .null],
                        precondition: episode, target: .available("ep-1"),
                        message: "a present null is not a numeric reference")
        assertSucceeds(action: "play_quote",
                       params: ["reference_position_ms": .int(1000)],
                       precondition: episode, target: .available("ep-1"),
                       message: "a numeric reference with its episode is valid")
    }

    /// An action this build cannot execute is classified unsupported — and that classification is
    /// DELIVERED to the sink, which settles it durably. It is not silently dropped.
    func testUndeclaredActionIsClassifiedUnsupported() {
        assertViolation(.unsupportedAction("teleport"), action: "teleport",
                        params: [:], precondition: [:],
                        message: "an undeclared action is unsupported, not invalid")
        for action in AppOperationRequest.actionContracts.keys {
            if case .failure(.unsupportedAction) = AppOperationRequest.validate(
                action: action, params: [:], precondition: [:]) {
                XCTFail("\(action) is declared but not executable")
            }
        }
    }

    /// A VALID parameter set for an action, carrying no invalid field, so a control that targets
    /// the PRECONDITION (or another single field) isolates exactly one violation. The wire contract
    /// fixes `invalid_request` but not a precedence among multiple invalid fields; rather than
    /// invent one, each control supplies everything else correctly and varies one thing.
    static func validParams(for action: String) -> [String: CloudRouteJSONValue] {
        switch action {
        case "seek_to": return ["position_seconds": .int(42)]
        case "play_quote": return ["reference_position_ms": .int(1000)]
        case "seek_relative": return ["delta_seconds": .int(5), "direction": .string("forward")]
        case "stop_quote", "pause", "resume": return [:]
        // An undeclared action has no valid parameter set; give it nothing so the unsupported
        // classification is the only thing under test.
        default: return [:]
        }
    }

    // MARK: - assertions over a non-Equatable Result

    /// `Result<Void, ParameterViolation>` is not `Equatable` (its success value is `Void`), so the
    /// outcome is MATCHED rather than compared. Each helper asserts the same thing the equivalent
    /// XCTAssertEqual did — the exact violation, or success — and nothing weaker.
    private func assertViolation(
        _ expected: AppOperationRequest.ParameterViolation,
        action: String,
        params: [String: CloudRouteJSONValue],
        precondition: [String: CloudRouteJSONValue],
        target: AppOperationRequest.TargetMatch = .notEvaluated,
        message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch AppOperationRequest.validate(action: action, params: params,
                                            precondition: precondition, target: target) {
        case .success:
            XCTFail("expected \(expected), got success. \(message())", file: file, line: line)
        case let .failure(actual):
            XCTAssertEqual(actual, expected, message(), file: file, line: line)
        }
    }

    private func assertSucceeds(
        action: String,
        params: [String: CloudRouteJSONValue],
        precondition: [String: CloudRouteJSONValue],
        target: AppOperationRequest.TargetMatch = .notEvaluated,
        message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch AppOperationRequest.validate(action: action, params: params,
                                            precondition: precondition, target: target) {
        case .success:
            break
        case let .failure(actual):
            XCTFail("expected success, got \(actual). \(message())", file: file, line: line)
        }
    }

    /// Asserts the outcome is a failure that is NOT the named violation — used where the control
    /// is "this request was not refused FOR THIS REASON".
    private func assertViolation(
        action: String,
        params: [String: CloudRouteJSONValue],
        precondition: [String: CloudRouteJSONValue],
        target: AppOperationRequest.TargetMatch = .notEvaluated,
        isNot unexpected: AppOperationRequest.ParameterViolation,
        message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case let .failure(actual) = AppOperationRequest.validate(
            action: action, params: params, precondition: precondition, target: target),
           actual == unexpected {
            XCTFail("refused for \(unexpected). \(message())", file: file, line: line)
        }
    }

    /// The structural layer only proves the bags are OBJECTS. It deliberately does not pre-judge
    /// field types — that is `validate`'s job — and it does not turn "absent" into a violation.
    func testStructuralDecodingIsSeparateFromTypeValidation() {
        XCTAssertEqual(AppOperationRequest.typedParams([:])?.isEmpty, true)
        XCTAssertNil(AppOperationRequest.typedParams(["params": "not-an-object"]))
        XCTAssertNil(AppOperationRequest.typedParams(["params": [1, 2, 3]]))
        XCTAssertNil(AppOperationRequest.typedPrecondition(["precondition": 7]))
        let json = (try? JSONSerialization.jsonObject(
            with: Data(#"{"params":{"flag":true}}"#.utf8))) as? [String: Any]
        XCTAssertNotNil(AppOperationRequest.typedParams(json ?? [:]),
                        "a JSON boolean is a valid JSON value; its admissibility is per action")
    }

    /// Through the LIVE boundary: an identified request that violates its contract is still
    /// DELIVERED (so the sink can settle the honest refusal), and carries the violation with it.
    func testLiveParseDeliversAnInvalidRequestWithItsViolation() throws {
        let uuid = "bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f"
        let wrongType = #"{"type":"action","operation_id":"\#(uuid)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":"5"},"precondition":{"episode_id":"ep-1"}}"#
        let events = CloudRouteClient.parseTextFrame(wrongType)
        XCTAssertEqual(events.count, 1, "an invalid identified request must still be answered")
        guard case let .action(_, _, _, _, _, _, _, violation) = try XCTUnwrap(events.first) else {
            return XCTFail("expected an action event")
        }
        XCTAssertEqual(violation, .wrongType(field: "delta_seconds"))

        // The correctly typed control is delivered with NO violation.
        let rightType = #"{"type":"action","operation_id":"\#(uuid)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"ep-1"}}"#
        guard case let .action(_, _, _, _, _, _, _, none) = try XCTUnwrap(CloudRouteClient.parseTextFrame(rightType).first) else {
            return XCTFail("expected an action event")
        }
        XCTAssertNil(none)
    }

    /// Through the LIVE boundary: a missing or stale target identity also reaches the sink with a
    /// violation rather than vanishing, and the both-forms seek is caught there too.
    func testLiveParseMarksMissingAndStaleTargets() throws {
        let uuid = "bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f"
        func violation(_ body: String) throws -> AppOperationRequest.ParameterViolation? {
            let events = CloudRouteClient.parseTextFrame(body)
            guard case let .action(_, _, _, _, _, _, _, violation) = try XCTUnwrap(events.first) else {
                XCTFail("expected an action event for \(body)")
                return nil
            }
            return violation
        }
        XCTAssertEqual(
            try violation(#"{"type":"action","operation_id":"\#(uuid)","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"position_seconds":1}}"#),
            .missingPrecondition("episode_id")
        )
        XCTAssertEqual(
            try violation(#"{"type":"action","operation_id":"\#(uuid)","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"position_seconds":1,"reference_position_ms":2},"precondition":{"episode_id":"ep-1"}}"#),
            .ambiguousSeekTarget
        )
        XCTAssertEqual(
            try violation(#"{"type":"action","operation_id":"\#(uuid)","capability_version":"app-ops/1","tool":"playback","action":"stop_quote","params":{},"precondition":{"episode_id":null}}"#),
            .missingPrecondition("episode_id")
        )
    }

    /// JSON `true`/`false` versus numeric `0`/`1` at the LIVE parser boundary, through typed
    /// action validation. This is the control for a decoder that tested `as? Bool` first: on
    /// Apple platforms `1 as? Bool` is `true` and `0 as? Bool` is `false`, so the integers became
    /// booleans and every legitimate numeric parameter failed type validation.
    func testLiveParseDistinguishesJSONBooleansFromNumbersIntoValidation() throws {
        let uuid = "bdc53855-0a6a-4bd3-a1ea-fd9c8deecc2f"
        func params(_ literal: String) throws -> [String: CloudRouteJSONValue] {
            let body = #"{"type":"action","operation_id":"\#(uuid)","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":\#(literal),"precondition":{"episode_id":"ep-1"}}"#
            guard case let .action(_, _, params, _, _, _, _, _) =
                try XCTUnwrap(CloudRouteClient.parseTextFrame(body).first) else {
                throw XCTSkip("no action event for \(literal)")
            }
            return params
        }
        // NUMBERS stay numbers, at three magnitudes, and each validates for seek_to.
        for (literal, expected) in [("{\"position_seconds\":0}", Int64(0)),
                                    ("{\"position_seconds\":1}", Int64(1)),
                                    ("{\"position_seconds\":1234567890123}", Int64(1_234_567_890_123))] {
            let decoded = try params(literal)
            XCTAssertEqual(decoded["position_seconds"], .int(expected),
                           "\(literal) must decode as an integer, not a boolean")
            assertSucceeds(action: "seek_to", params: decoded,
                           precondition: ["episode_id": .string("ep-1")],
                           message: "\(literal) is a valid seek target")
        }
        // BOOLEANS stay booleans, and are NOT accepted as a numeric parameter.
        for (literal, expected) in [("{\"position_seconds\":true}", true),
                                    ("{\"position_seconds\":false}", false)] {
            let decoded = try params(literal)
            XCTAssertEqual(decoded["position_seconds"], .bool(expected),
                           "\(literal) must decode as a boolean")
            assertViolation(.wrongType(field: "position_seconds"), action: "seek_to",
                            params: decoded,
                            precondition: ["episode_id": .string("ep-1")],
                            message: "a boolean is never a numeric target")
        }
        // The fractional control: a double is a number and stays one.
        let fractional = try params("{\"position_seconds\":1.5}")
        XCTAssertEqual(fractional["position_seconds"], .double(1.5))
        assertSucceeds(action: "seek_to", params: fractional,
                       precondition: ["episode_id": .string("ep-1")],
                       message: "a fractional target is still numeric")
    }

    /// Two concatenated objects, and an object followed by trailing junk, are NOT one payload.
    /// The old first-`{`-to-last-`}` search would have produced bytes spanning both.
    func testPayloadExtractionRefusesConcatenatedOrTrailingEnvelopes() {
        for bad in [
            #"{"type":"action","a":1}{"type":"action","b":2}"#,
            #"{"type":"action","a":1} trailing junk"#,
            #"{"type":"action""#,
            #"not json at all"#,
        ] {
            XCTAssertNil(AppOperationRequest.actionPayloadBytes(rawFrame: Data(bad.utf8)),
                         "must not define a payload boundary for: \(bad)")
        }
    }

    /// The legacy SSE framing boundary is the transport's own single `data:` line, and two
    /// `data:` lines are two payloads rather than one.
    func testLegacyFramingBoundaryRejectsMultipleDataLines() {
        XCTAssertNil(AppOperationRequest.actionPayloadBytes(
            rawFrame: Data("event: action\ndata: {\"a\":1}\ndata: {\"b\":2}\n\n".utf8)))
        XCTAssertEqual(
            AppOperationRequest.actionPayloadBytes(
                rawFrame: Data("event: action\ndata: {\"a\": 1}\n\n".utf8))
                .map { String(decoding: $0, as: UTF8.self) },
            "{\"a\": 1}"
        )
    }

    // MARK: - ONE definition of the payload byte boundary

    /// The extractor is the single authority: framing outside the object is excluded, and the
    /// payload's own whitespace is preserved exactly. Both properties are load-bearing, because a
    /// redelivery is recognised by byte equality on these bytes.
    func testPayloadExtractorExcludesFramingAndKeepsInteriorWhitespace() throws {
        let framed = "event: action\ndata: {\"a\": 1,  \"b\":2}\n\n"
        let payload = try XCTUnwrap(
            AppOperationRequest.actionPayloadBytes(rawFrame: Data(framed.utf8)))
        XCTAssertEqual(String(decoding: payload, as: UTF8.self),
                       "{\"a\": 1,  \"b\":2}",
                       "framing is outside the braces; interior whitespace is preserved")
    }

    /// SSE FRAMING, kept as its OWN case because it belongs to the extractor and not to the live
    /// socket parser. The two have different input contracts and mixing them is how the case above
    /// came to assert a parse the socket path can never perform.
    func testExtractorStripsSSEFramingForTheSameIdentity() throws {
        let framed = "event: action\ndata: {\"type\":\"action\",\"operation_id\":\"40736873-b1c0-48ab-a239-3cb0711fc2f9\","
            + "\"capability_version\":\"app-ops/1\",\"tool\":\"playback\",\"action\":\"pause\"}\n\n"
        let payload = try XCTUnwrap(
            AppOperationRequest.actionPayloadBytes(rawFrame: Data(framed.utf8)),
            "the extractor is the boundary that understands SSE framing")
        let json = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any])
        XCTAssertEqual(json["operation_id"] as? String, "40736873-b1c0-48ab-a239-3cb0711fc2f9",
                       "framing is removed, the identity it wrapped survives intact")
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).hasPrefix("event:"),
                       "the extracted bytes are the payload alone")
    }

    /// The SAME extractor defines the identity the sink journals, so what a case computes and what
    /// the sink claims cannot diverge.
    func testLiveParseCarriesTheExtractorBytesAsReplayIdentity() throws {
        // BARE JSON, because this case exercises the LIVE SOCKET parser and the socket delivers
        // the payload, not an SSE envelope. The previous fixture prepended `event:`/`data:` lines;
        // `parseTextFrame` runs `JSONSerialization` straight on the received bytes, so it returned
        // `[]` at its structural guard and this case asserted something the transport can never
        // produce. SSE framing has its own coverage below, against the extractor it belongs to.
        let framed = #"{"type":"action",  "operation_id":"40736873-b1c0-48ab-a239-3cb0711fc2f9","capability_version":"app-ops/1","tool":"playback","action":"pause"}"#
        let expected = try XCTUnwrap(
            AppOperationRequest.actionPayloadBytes(rawFrame: Data(framed.utf8)))
        let action = try XCTUnwrap(CloudRouteClient.parseTextFrame(framed).compactMap { event -> CloudRouteEvent? in
            if case .action = event { return event }
            return nil
        }.first)
        guard case .action(tool: _, action: _, params: _, operationId: _, capabilityVersion: _,
                           actionBytes: let carried, precondition: _,
                           parameterViolation: _) = action else {
            return XCTFail("expected an action event")
        }
        XCTAssertEqual(carried, expected, "the sink must receive exactly the extractor's bytes")
    }
}
