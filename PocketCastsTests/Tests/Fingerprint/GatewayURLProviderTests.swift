import Foundation
import PocketCastsServer
import XCTest

final class GatewayURLProviderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "gateway_url_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func provider(buildDefault: String = "") -> GatewayURLProvider {
        GatewayURLProvider(defaults: defaults, buildDefaultGatewayURL: buildDefault)
    }

    private let upstreamAPI = "https://api.pocketcasts.com/"
    private let upstreamMain = "https://refresh.pocketcasts.com/"
    private let upstreamCache = "https://cache.pocketcasts.com/"

    func testDefaultsToDirectUpstreamWhenGatewayURLEmpty() {
        let gateway = provider(buildDefault: "")
        XCTAssertFalse(gateway.isCutoverActive())
        XCTAssertEqual(gateway.resolve(upstream: upstreamAPI), upstreamAPI)
        XCTAssertEqual(gateway.resolve(upstream: upstreamMain), upstreamMain)
        XCTAssertEqual(gateway.resolve(upstream: upstreamCache), upstreamCache)
    }

    func testUsesBuildTimeGatewayDefaultWhenCutoverActive() {
        let gateway = provider(buildDefault: "https://gateway.staging.example.com")
        XCTAssertTrue(gateway.isCutoverActive())
        // Gateway mounts Pocket Casts compat under /api/ (Android GatewayCompatPathInterceptor parity).
        XCTAssertEqual(gateway.resolve(upstream: upstreamAPI), "https://gateway.staging.example.com/api/")
        XCTAssertEqual(gateway.resolve(upstream: upstreamMain), "https://gateway.staging.example.com/api/")
    }

    func testUserDefaultsOverrideWinsOverBuildDefault() {
        defaults.set("https://override.example.com", forKey: GatewayURLProvider.baseURLKey)
        let gateway = provider(buildDefault: "https://gateway.staging.example.com")
        XCTAssertEqual(gateway.configuredGatewayURL(), "https://override.example.com")
        XCTAssertEqual(gateway.resolve(upstream: upstreamAPI), "https://override.example.com/api/")
    }

    func testResolveDoesNotDoublePrefixApi() {
        defaults.set("https://gateway.example.com/api", forKey: GatewayURLProvider.baseURLKey)
        let gateway = provider()
        XCTAssertEqual(gateway.resolve(upstream: upstreamAPI), "https://gateway.example.com/api/")
    }

    func testRewriteCompatURLPrefixesHostRootedGatewayPaths() {
        defaults.set("https://api.auris.fm", forKey: GatewayURLProvider.baseURLKey)
        let gateway = provider()
        let rewritten = gateway.rewriteCompatURL(URL(string: "https://api.auris.fm/import/opml")!)
        XCTAssertEqual(rewritten.absoluteString, "https://api.auris.fm/api/import/opml")
    }

    func testRewriteCompatURLLeavesApiPrefixedAndNonGatewayHosts() {
        defaults.set("https://api.auris.fm", forKey: GatewayURLProvider.baseURLKey)
        let gateway = provider()
        XCTAssertEqual(
            gateway.rewriteCompatURL(URL(string: "https://api.auris.fm/api/user/login")!).absoluteString,
            "https://api.auris.fm/api/user/login"
        )
        XCTAssertEqual(
            gateway.rewriteCompatURL(URL(string: "https://api.auris.fm/api/v1/cloud/route")!).absoluteString,
            "https://api.auris.fm/api/v1/cloud/route"
        )
        XCTAssertEqual(
            gateway.rewriteCompatURL(URL(string: "https://api.pocketcasts.com/import/opml")!).absoluteString,
            "https://api.pocketcasts.com/import/opml"
        )
    }

    func testExplicitEmptyOverrideDisablesCutover() {
        defaults.set("", forKey: GatewayURLProvider.baseURLKey)
        let gateway = provider(buildDefault: "https://gateway.staging.example.com")
        XCTAssertFalse(gateway.isCutoverActive())
        XCTAssertEqual(gateway.resolve(upstream: upstreamAPI), upstreamAPI)
    }

    func testKillSwitchRestoresDirectUpstream() {
        defaults.set("https://gateway.staging.example.com", forKey: GatewayURLProvider.baseURLKey)
        defaults.set(true, forKey: GatewayURLProvider.directUpstreamKey)
        let gateway = provider(buildDefault: "https://gateway.staging.example.com")
        XCTAssertTrue(gateway.isDirectUpstreamForced())
        XCTAssertFalse(gateway.isCutoverActive())
        XCTAssertEqual(gateway.resolve(upstream: upstreamAPI), upstreamAPI)
        XCTAssertEqual(gateway.resolve(upstream: upstreamMain), upstreamMain)
    }

    func testKillSwitchWithEmptyGatewayStaysDirect() {
        defaults.set(true, forKey: GatewayURLProvider.directUpstreamKey)
        let gateway = provider(buildDefault: "")
        XCTAssertFalse(gateway.isCutoverActive())
        XCTAssertEqual(gateway.resolve(upstream: upstreamCache), upstreamCache)
    }
}
