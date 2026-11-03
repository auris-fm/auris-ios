import XCTest
@testable import podcasts
@testable import PocketCastsUtils

/// SPEC RULING 2026-11-03: Voice Sharing uses the existing Auris token provider on every build where
/// sharing is enabled, selecting it independently of the assistant's `cloudEdgeTokens` flag and the
/// gateway-cutover gate. Missing configuration must refuse sharing rather than fall back to the static
/// identity, whose `token()` is a bare `user_<uuid>` — not a JWS, so the account route cannot verify it
/// under any configuration.
final class VoiceSharingProviderSelectionTests: XCTestCase {
    /// The old wiring picked the provider through `provider()`, which returns the STATIC provider when
    /// the assistant flag is off or no origin is configured. A shipped build would then send a
    /// non-JWS credential. The voice-sharing entry must never resolve to it.
    func test_voiceSharingProvider_isNeverTheStaticIdentityProvider() {
        let provider = CloudTokenProviderRouter.voiceSharingProvider(aurisBaseURL: "https://api-staging.auris.fm")
        XCTAssertNotNil(provider, "a configured origin must yield a provider")
        XCTAssertFalse(provider is CloudStaticIdentityTokenProvider,
                       "Voice Sharing must never present a bare user_<uuid> as its bearer")
    }

    /// Fail-closed: no origin means no credential. Sharing is unavailable, not silently degraded to an
    /// identity the route would refuse.
    func test_missingOrigin_refusesInsteadOfFallingBack() {
        XCTAssertNil(CloudTokenProviderRouter.voiceSharingProvider(aurisBaseURL: ""))
        XCTAssertNil(CloudTokenProviderRouter.voiceSharingProvider(aurisBaseURL: "   "),
                     "a blank origin is not configuration")
    }

    /// The selection does not depend on `cloudEdgeTokens`: the same answer holds whichever way the
    /// assistant's flag is resolved, because the voice-sharing entry never consults it.
    func test_selectionIsIndependentOfTheAssistantRoutingFlag() {
        let origin = "https://api-staging.auris.fm"
        XCTAssertNotNil(CloudTokenProviderRouter.voiceSharingProvider(aurisBaseURL: origin))
        // The assistant's entry point still honours its own flag/cutover gates — unchanged by this work.
        let assistant = CloudTokenProviderRouter.provider(aurisBaseURL: origin, edgeTokensEnabled: false)
        XCTAssertTrue(assistant is CloudStaticIdentityTokenProvider,
                      "the assistant's gated behaviour is deliberately unchanged")
    }
}
