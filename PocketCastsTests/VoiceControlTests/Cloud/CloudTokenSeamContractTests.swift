import XCTest
@testable import podcasts

/// Pins the seam's two optional capabilities so they are exercised rather than
/// merely declared (PR #19 review): implementing **only** the preferred
/// rejected-token form must satisfy conformance, and the convenience no-arg
/// call must forward to it with `nil`.
/// The two questions the transport seam must keep SEPARATE. Kept in its own class so the
/// distinction is legible rather than buried in one of the suites that happens to exercise it.
final class CloudTokenTransportVersusPrincipalTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "token-seam-\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        super.tearDown()
    }

    /// LEGACY TRANSPORT SURVIVES. The trust-on-first-use bearer has no verified principal, and
    /// that must not stop an ordinary turn: `transportCredential()` still yields the `user_<id>`
    /// bearer the server's UserIDMiddleware accepts.
    func testStaticProviderStillSuppliesALegacyTransportCredential() async throws {
        let identity = CloudIdentity(defaults: defaults)
        let provider = CloudStaticIdentityTokenProvider(identity: identity)

        let credential = await provider.transportCredential()
        XCTAssertEqual(credential, identity.userId,
                       "the TOT bearer must still carry an ordinary turn")
        // Resolved into a local: XCTest's comparison arguments are autoclosures, which cannot
        // carry an `await`. Asserted, not discarded, so the property is still covered.
        let legacyToken = await provider.token()
        XCTAssertEqual(legacyToken, identity.userId,
                       "token() is unchanged: legacy behaviour is preserved")
    }

    /// NO PRINCIPAL. The same provider reports NO authenticated session, because a client-written
    /// bearer is not a statement the server verified. Claiming one would journal operations under
    /// an owner no issuer vouched for.
    func testStaticProviderReportsNoEstablishedPrincipal() async {
        let provider = CloudStaticIdentityTokenProvider(identity: CloudIdentity(defaults: defaults))
        let session = await provider.authenticatedSession()
        XCTAssertNil(session,
                     "a self-asserted bearer is transport, not an established principal")
    }

    /// The two answers are independent for this provider: having a transport credential says
    /// nothing about having a principal. This is the control that fails if anyone re-conflates
    /// them by deriving one from the other.
    func testTransportCredentialDoesNotImplyAPrincipal() async {
        let provider = CloudStaticIdentityTokenProvider(identity: CloudIdentity(defaults: defaults))
        let credential = await provider.transportCredential()
        let session = await provider.authenticatedSession()
        XCTAssertNotNil(credential, "transport is available")
        XCTAssertNil(session, "authority is not")
    }
}

final class CloudTokenSeamContractTests: XCTestCase {
    private final class PreferredFormOnly: CloudTokenProviding {
        var seen: [String??] = []
        func token() async -> String? { "token" }
        func handleUnauthorized(rejectedToken: String?) async { seen.append(rejectedToken) }
        func authenticatedSession() async -> CloudAuthenticatedSession? {
            CloudAuthenticatedSession(accountId: "seam-owner", accessToken: "token")
        }
    }

    func testConformanceRequiresOnlyThePreferredForm() async {
        let provider = PreferredFormOnly()
        // Compiles and runs without implementing the legacy no-arg requirement.
        await provider.handleUnauthorized()
        XCTAssertEqual(provider.seen.count, 1, "the convenience form forwards to the preferred one")
        XCTAssertNil(provider.seen[0] ?? nil, "it forwards nil, meaning 'credential unknown'")
    }

    func testConvenienceFormForwardsToThePreferredFormWithTheToken() async {
        let provider = PreferredFormOnly()
        await provider.handleUnauthorized(rejectedToken: "token-that-401d")
        XCTAssertEqual(provider.seen.compactMap { $0 }, ["token-that-401d"])
    }

    func testPrepareDefaultsToANoOp() async {
        let provider = PreferredFormOnly()
        await provider.prepare()  // must not require an implementation
    }
}
