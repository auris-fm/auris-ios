import XCTest

@testable import podcasts

/// Projection refresh controls for the SIMPLIFIED contract.
///
/// The whole restored-session settlement machinery — identity digests, owner-readiness polling,
/// retry ticks, generation provenance — is deleted. What remains of the coordinator's server
/// interaction is ONE operation: fetch the account's sharing view and apply it to the store. These
/// controls keep the guarantees that still mean something: a fresh projection becomes consent, a
/// failed fetch never invents consent, and a fetch issued under a superseded lifecycle cannot be
/// applied.
final class VoiceSharingRestoredSessionTests: XCTestCase {

    private final class Tokens: CloudTokenProviding {
        var token: String? = "test-bearer"
        func token() async -> String? { token }
        func prepare() async {}
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    /// The store reads its lifecycle from this provider, so a control can move the session under an
    /// in-flight read exactly as sign-out/login does.
    private var lifecycle = "gen-A"
    private func makeStore() -> VoiceSharingEnrollmentStore {
        let store = VoiceSharingEnrollmentStore(sessionIdentityProvider: { [weak self] in self?.lifecycle })
        return store
    }

    private func makeClient(_ store: VoiceSharingEnrollmentStore) -> VoiceSharingAccountClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceSharingStubProtocol.self]
        return VoiceSharingAccountClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: Tokens(),
            session: URLSession(configuration: config),
            sessionIdentity: { "gen-A" },
            membershipStore: store)
    }

    private func enrolledReply() {
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] = .init(
            status: 200,
            body: [
                "schema_version": 1,

                "plan": "pro",
                "voice_sharing_enrolled": true,
                "withdrawal_state": "active",
                "enrollment_epoch": "e1" as Any,
                "accepted_disclosure_version": "voice-sharing-v1" as Any,
            ])
    }

    /// The one remaining server interaction: the projection refresh applies the account's own view,
    /// and that view is what consent decides from.
    func test_projectionRefreshAppliesTheAccountsView() async throws {
        let store = makeStore()
        store.setLocalOptIn(true)
        enrolledReply()
        defer { VoiceSharingStubProtocol.replies.removeAll() }
        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)

        XCTAssertFalse(store.currentEffectiveEnrolled, "premise: nothing known before the refresh")
        await coordinator.refreshProjectionFromServer(accountClient: makeClient(store))

        XCTAssertTrue(store.currentEffectiveEnrolled, "the refresh applied the account's own view")
        XCTAssertTrue(store.consentAllowsCollection, "and consent decides from it")
    }

    /// A FAILED refresh must never invent consent: a store that knew nothing keeps knowing nothing.
    func test_aFailedRefreshGrantsNothing() async throws {
        let store = makeStore()
        store.setLocalOptIn(true)
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] = .init(
            status: 500, body: ["error": "unavailable"])
        defer { VoiceSharingStubProtocol.replies.removeAll() }
        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)

        await coordinator.refreshProjectionFromServer(accountClient: makeClient(store))

        // Consent still stands (the user asked to share; a failed GET is not a decision for them),
        // but no ACCOUNT authority is invented: nothing was learned from the server.
        XCTAssertFalse(store.currentEffectiveEnrolled, "a failed fetch grants nothing")
    }

    /// A withdrawal in the account's projection reaches consent — this is how a withdrawal made on
    /// another device becomes an immediate local stop.
    func test_aServerWithdrawalReachesConsent() async throws {
        let store = makeStore()
        store.setLocalOptIn(true)
        enrolledReply()
        defer { VoiceSharingStubProtocol.replies.removeAll() }
        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        await coordinator.refreshProjectionFromServer(accountClient: makeClient(store))
        XCTAssertTrue(store.consentAllowsCollection, "premise: enrolled and permitted")

        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] = .init(
            status: 200,
            body: [
                "schema_version": 1,

                "plan": "pro",
                "voice_sharing_enrolled": false,
                "withdrawal_state": "withdrawn",
                "enrollment_epoch": "e1" as Any,
                "accepted_disclosure_version": "voice-sharing-v1" as Any,
            ])
        await coordinator.refreshProjectionFromServer(accountClient: makeClient(store))

        XCTAssertFalse(store.consentAllowsCollection, "a server withdrawal stops collection")
    }

    /// A projection fetched under a SUPERSEDED lifecycle cannot be applied: the store's fence
    /// refuses it, so an answer that outlived its session never becomes consent.
    func test_aProjectionFromASupersededLifecycleIsRefused() async throws {
        let store = makeStore()
        store.setLocalOptIn(true)
        enrolledReply()
        defer { VoiceSharingStubProtocol.replies.removeAll() }
        let client = makeClient(store)

        let projection = await client.fetchProjection()
        let fetched = try XCTUnwrap(projection, "premise: projection fetched")
        // The account transitions between the fetch and its application.
        lifecycle = "gen-B"
        store.transitionToAccount(signedIn: false)
        XCTAssertFalse(store.apply(authoritative: fetched.membership, readUnder: fetched.issuedUnder),
                       "a projection issued under a departed lifecycle must be refused")
        XCTAssertFalse(store.consentAllowsCollection, "and must never become consent")
    }
}