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
        XCTAssertEqual(gateway.resolve(upstream: upstreamAPI), "https://gateway.staging.example.com/")
        XCTAssertEqual(gateway.resolve(upstream: upstreamMain), "https://gateway.staging.example.com/")
    }

    func testUserDefaultsOverrideWinsOverBuildDefault() {
        defaults.set("https://override.example.com", forKey: GatewayURLProvider.baseURLKey)
        let gateway = provider(buildDefault: "https://gateway.staging.example.com")
        XCTAssertEqual(gateway.configuredGatewayURL(), "https://override.example.com")
        XCTAssertEqual(gateway.resolve(upstream: upstreamAPI), "https://override.example.com/")
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
