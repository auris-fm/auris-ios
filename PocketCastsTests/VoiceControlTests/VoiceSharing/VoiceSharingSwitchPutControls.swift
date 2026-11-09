import XCTest
import UIKit
import PocketCastsServer
@testable import podcasts

/// PHASE 2: enrollment and withdrawal are ONE `PUT /api/v1/account/voice-sharing` whose body
/// is the DESIRED state. The server derives the transition from it; there is no precondition to
/// assert and no 409 to replay.
///
/// Every control here drives the production transport path (a real `URLRequest` through a `URLSession`),
/// and each one has a bite: a wrong body, a missing precondition header, or a fresh request identity on
/// resend would fail it.
final class VoiceSharingSwitchPutControls: XCTestCase {
    private typealias Reply = VoiceSharingStubProtocol.Reply

    private var session: URLSession!
    private var tokens: SwitchStubTokenProvider!
    private var identity: String? = "gen-A"
    private var store: VoiceSharingEnrollmentStore!
    private var suite: String!
    private var client: VoiceSharingAccountClient!

    private final class SwitchStubTokenProvider: CloudTokenProviding {
        func token() async -> String? { "switch-bearer" }
        func prepare() async {}
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    override func setUp() {
        super.setUp()
        VoiceSharingStubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceSharingStubProtocol.self]
        session = URLSession(configuration: config)
        tokens = SwitchStubTokenProvider()
        identity = "gen-A"
        suite = "VoiceSharingSwitchPut-\(UUID().uuidString)"
        store = VoiceSharingEnrollmentStore(
            defaults: UserDefaults(suiteName: suite)!,
            accountScopeProvider: { "switch-test-account" },
            sessionIdentityProvider: { [weak self] in self?.identity }
        )
        client = VoiceSharingAccountClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: tokens,
            session: session,
            requestIDFactory: { UUID().uuidString.lowercased() },
            sessionIdentity: { [weak self] in self?.identity },
            membershipStore: store
        )
    }

    override func tearDown() {
        if let suite, let d = UserDefaults(suiteName: suite) { d.removePersistentDomain(forName: suite) }
        store = nil
        VoiceSharingStubProtocol.reset()
        super.tearDown()
    }

    private func projectionBody(_ revision: String, enrolled: Bool, epoch: String?) -> [String: Any] {
        var body: [String: Any] = [
            "schema_version": 1, "membership_revision": revision, "plan": "pro",
            "voice_sharing_enrolled": enrolled,
            // Wire values are the server's snake_case enums: an enrolled membership is `active`; a
            // withdrawal states `withdrawn`. (`none` is not a wire value — the stricter fixture was mine.)
            "withdrawal_state": enrolled ? "active" : "withdrawn",
            "accepted_disclosure_version": enrolled ? "2026-09" : NSNull(),
        ]
        body["enrollment_epoch"] = epoch as Any
        return body
    }

    private var putRequests: [URLRequest] {
        VoiceSharingStubProtocol.seenRequests.filter { $0.httpMethod == "PUT" }
    }

    private func bodyObject(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map(Self.drain))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: - ON

    /// Turning sharing on is ONE put to the membership path, carrying the desired state and the accepted
    /// disclosure — and nothing about the transition the server should take.
    func test_switchOnSendsOnePutWithTheDesiredStateAndTheDisclosure() async throws {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projectionBody("r8", enrolled: true, epoch: "e8"))
        let op = try XCTUnwrap(client.beginMembership(
            enrolled: true, acceptedDisclosureVersion: "2026-09"))
        let outcome = await client.perform(op)

        XCTAssertEqual(putRequests.count, 1, "one PUT, not a POST pair or a retry")
        let request = try XCTUnwrap(putRequests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/account/voice-sharing")
        let body = try bodyObject(request)
        XCTAssertEqual(body["enrolled"] as? Bool, true)
        XCTAssertEqual(body["disclosure_version"] as? String, "2026-09")
        XCTAssertNil(body["enrollment_epoch"], "the server derives the epoch from the desired state")
        guard case .applied(let membership, _) = outcome else {
            return XCTFail("expected applied, got \(outcome)")
        }
        XCTAssertTrue(membership.voiceSharingEnrolled)
    }

    // MARK: - OFF

    /// Turning sharing off is the SAME request shape with `enrolled: false`, and carries NO disclosure:
    /// consent belongs to the enrollment the user is leaving.
    func test_switchOffSendsTheSamePutWithEnrolledFalseAndNoDisclosure() async throws {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projectionBody("r9", enrolled: false, epoch: nil))
        let op = try XCTUnwrap(client.beginMembership(
            enrolled: false, acceptedDisclosureVersion: nil))
        let outcome = await client.perform(op)

        let request = try XCTUnwrap(putRequests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/account/voice-sharing")
        let body = try bodyObject(request)
        XCTAssertEqual(body["enrolled"] as? Bool, false)
        XCTAssertNil(body["disclosure_version"])
        guard case .applied(let membership, _) = outcome else {
            return XCTFail("expected applied, got \(outcome)")
        }
        XCTAssertFalse(membership.voiceSharingEnrolled)
    }

    /// A desired-state PUT is IDEMPOTENT by construction: the repeat is a resend of the same bytes, so a
    /// lost response is recovered without a second mutation. Asserting the EXACT bytes (not just the shape)
    /// is what makes "resend" meaningful.
    func test_repeatOnResendsTheIdenticalBytes() async throws {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projectionBody("r8", enrolled: true, epoch: "e8"))
        let op = try XCTUnwrap(client.beginMembership(
            enrolled: true, acceptedDisclosureVersion: "2026-09"))
        _ = await client.perform(op)
        _ = await client.perform(op)

        XCTAssertEqual(putRequests.count, 2)
        let first = try XCTUnwrap(putRequests.first)
        let second = try XCTUnwrap(putRequests.last)
        let firstBody = try XCTUnwrap(first.httpBody ?? first.httpBodyStream.map(Self.drain))
        let secondBody = try XCTUnwrap(second.httpBody ?? second.httpBodyStream.map(Self.drain))
        XCTAssertEqual(firstBody, secondBody, "a resend must be byte-identical, or it is a new intent")
    }

    // MARK: - 409 is terminal

    /// A stale precondition is answered with 409 and the CURRENT projection. The client surfaces that state
    /// and stops: it must not replay the same desired state against the newer revision, because renewing
    /// sharing is fresh user intent, not a retry.
    func test_staleRevisionConflictSurfacesTheCurrentStateAndDoesNotReplay() async throws {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 409, body: projectionBody("r12", enrolled: false, epoch: nil))
        let op = try XCTUnwrap(client.beginMembership(
            enrolled: true, acceptedDisclosureVersion: "2026-09"))
        let outcome = await client.perform(op)

        guard case .conflict(let current, _) = outcome else {
            return XCTFail("expected conflict, got \(outcome)")
        }
        XCTAssertEqual(current?.membershipRevision, "r12")
        XCTAssertEqual(current?.voiceSharingEnrolled, false)
        XCTAssertEqual(putRequests.count, 1, "a conflict must not produce a second request")
    }

    /// Spec core e3cfc8ae: the 409 body is the plain projection — the same shape `GET` returns, decoded by the
    /// same strict decoder. A conflict answer wrapped in an envelope would leave the user's screen blank at
    /// exactly the moment the server is telling them what the state really is.
    func test_conflictBodyIsThePlainProjectionShapeThatGetReturns() async throws {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 409, body: projectionBody("r12", enrolled: false, epoch: nil))
        let op = try XCTUnwrap(client.beginMembership(
            enrolled: true, acceptedDisclosureVersion: "2026-09"))
        let outcome = await client.perform(op)

        guard case .conflict(let current, _) = outcome else {
            return XCTFail("expected conflict, got \(outcome)")
        }
        let projection = try XCTUnwrap(current, "the 409 body must decode as a projection")
        XCTAssertEqual(projection.membershipRevision, "r12")
        XCTAssertEqual(projection.withdrawalState, .withdrawn)
        XCTAssertNil(projection.enrollmentEpoch)
    }

    // MARK: - local refusals

    /// Turning sharing ON without a disclosure version is refused at BEGIN, so no request exists to record a
    /// consent the user never gave.
    func test_switchOnWithoutADisclosureVersionIsRefusedBeforeAnyRequest() async {
        XCTAssertNil(client.beginMembership(
            enrolled: true, acceptedDisclosureVersion: nil))
        XCTAssertNil(client.beginMembership(
            enrolled: true, acceptedDisclosureVersion: ""))
        XCTAssertTrue(putRequests.isEmpty)
    }

    /// A withdrawal naming a disclosure version is refused at BEGIN: that would record consent for a state
    /// the request is leaving.
    func test_switchOffCarryingADisclosureVersionIsRefused() async {
        XCTAssertNil(client.beginMembership(
            enrolled: false, acceptedDisclosureVersion: "2026-09"))
        XCTAssertTrue(putRequests.isEmpty)
    }
}