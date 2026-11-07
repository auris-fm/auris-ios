import XCTest
@testable import podcasts
@testable import PocketCastsServer
@testable import PocketCastsUtils

/// SPEC RULING 2026-11-03: Voice Sharing uses the existing Auris token provider on every build where
/// sharing is enabled, selecting it independently of the assistant's `cloudEdgeTokens` flag and of the
/// gateway-CUTOVER switch. Missing configuration must refuse sharing rather than fall back to the static
/// identity, whose `token()` is a bare `user_<uuid>` — not a JWS, so the account route cannot verify it.
final class VoiceSharingProviderSelectionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "voice-sharing-selection-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func config(origin: String?, directUpstream: Bool = false) -> CloudConfig {
        if let origin { defaults.set(origin, forKey: GatewayURLProvider.baseURLKey) }
        defaults.set(directUpstream, forKey: GatewayURLProvider.directUpstreamKey)
        return CloudConfig(defaults: defaults, buildDefaultGatewayURL: "")
    }

    /// The old wiring picked the provider through `provider()`, which returns the STATIC provider when
    /// the assistant flag is off or no origin resolves. The voice-sharing entry must never resolve to it.
    func test_voiceSharingProvider_isNeverTheStaticIdentityProvider() {
        let provider = CloudTokenProviderRouter.voiceSharingProvider(aurisBaseURL: "https://api-staging.auris.fm")
        XCTAssertNotNil(provider, "a configured origin must yield a provider")
        XCTAssertFalse(provider is CloudStaticIdentityTokenProvider,
                       "Voice Sharing must never present a bare user_<uuid> as its bearer")
    }

    /// REVIEWER: a configured origin with cutover OFF must still be a configuration for sharing. The
    /// assistant's `baseUrl` answers empty in that state, and inheriting it made a configured deployment
    /// look unconfigured.
    func test_configuredOrigin_survivesTheDirectUpstreamKillSwitch() {
        let origin = "https://api-staging.auris.fm"
        // Cutover is active whenever an origin is configured — asserted so this control documents the
        // real behaviour rather than my assumption about it.
        XCTAssertEqual(config(origin: origin).baseUrl, origin)
        // The assistant's direct-upstream kill switch DOES empty `baseUrl`. That switch is a migration
        // control, not a statement that no origin exists, so sharing must not inherit it.
        let direct = config(origin: origin, directUpstream: true)
        XCTAssertEqual(direct.baseUrl, "", "the assistant's kill switch still gates its own origin")
        XCTAssertEqual(direct.configuredOrigin, origin,
                       "sharing's origin does not depend on the assistant's kill switch")
    }

    /// Fail-closed: no origin means no credential — sharing is unavailable, not silently degraded.
    func test_missingOrigin_refusesInsteadOfFallingBack() {
        XCTAssertNil(CloudTokenProviderRouter.voiceSharingProvider(aurisBaseURL: ""))
        XCTAssertNil(CloudTokenProviderRouter.voiceSharingProvider(aurisBaseURL: "   "),
                     "a blank origin is not configuration")
        XCTAssertEqual(config(origin: nil).configuredOrigin, "", "no configured origin")
    }

    /// REVIEWER on f37893cd0: the first fix built a SECOND CloudAuthTokenProvider for sharing. Its
    /// cache, refresh chain and single-flight handle are instance state, so two instances fork the chain
    /// and revoke each other — the exact `refresh_reused` defect the sharing rule exists to prevent.
    /// Identity is the property: there must be exactly one Auris provider in the process.
    func test_voiceSharing_andAssistant_shareOneAurisProviderInstance() {
        let origin = "https://api-staging.auris.fm"
        let sharing = CloudTokenProviderRouter.voiceSharingProvider(aurisBaseURL: origin)
        let assistant = CloudTokenProviderRouter.provider(aurisBaseURL: origin, edgeTokensEnabled: true)
        func isSameInstance(_ a: any CloudTokenProviding, _ b: any CloudTokenProviding) -> Bool {
            (a as AnyObject) === (b as AnyObject)
        }
        XCTAssertTrue(isSameInstance(sharing!, assistant),
                      "sharing and the assistant must hold the SAME Auris provider instance")
    }

    /// The assistant's own gated behaviour is deliberately unchanged by this work.
    func test_assistantRoutingBehaviourIsUnchanged() {
        let origin = "https://api-staging.auris.fm"
        XCTAssertTrue(CloudTokenProviderRouter.provider(aurisBaseURL: origin, edgeTokensEnabled: false)
            is CloudStaticIdentityTokenProvider)
        XCTAssertFalse(CloudTokenProviderRouter.provider(aurisBaseURL: origin, edgeTokensEnabled: true)
            is CloudStaticIdentityTokenProvider)
    }
}
