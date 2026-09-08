import Foundation
import PocketCastsServer
import XCTest

/// API-family-only cutover (Android `GatewayUrlResolver` parity): only
/// `ServerConstants.Urls.api()` collapses onto the gateway; discover/search/etc.
/// stay on their Pocket Casts hosts.
final class ServerConstantsGatewayCutoverTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var previousShared: GatewayURLProvider!

    override func setUp() {
        super.setUp()
        suiteName = "server_constants_cutover_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        previousShared = GatewayURLProvider.shared
    }

    override func tearDown() {
        GatewayURLProvider.shared = previousShared
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testApiOnlyCutoverCollapsesApiAndLeavesCdnHostsDirect() {
        defaults.set("https://api.auris.fm", forKey: GatewayURLProvider.baseURLKey)
        GatewayURLProvider.shared = GatewayURLProvider(defaults: defaults, buildDefaultGatewayURL: "")

        XCTAssertEqual(ServerConstants.Urls.api(), "https://api.auris.fm/")
        XCTAssertTrue(ServerConstants.Urls.discover().hasPrefix("https://static.pocketcasts."))
        XCTAssertTrue(ServerConstants.Urls.discover().hasSuffix("/discover/"))
        XCTAssertTrue(ServerConstants.Urls.search.hasPrefix("https://search.pocketcasts."))
        XCTAssertTrue(ServerConstants.Urls.cache().hasPrefix("https://cache.pocketcasts.")
            || ServerConstants.Urls.cache().hasPrefix("https://podcast-api.pocketcasts."))
        XCTAssertTrue(ServerConstants.Urls.main().hasPrefix("https://refresh.pocketcasts."))
        XCTAssertTrue(ServerConstants.Urls.lists().hasPrefix("https://lists.pocketcasts."))
        XCTAssertEqual(ServerConstants.Urls.files(), "https://files.pocketcasts.com/files/")
    }

    func testKillSwitchRestoresDirectApiUpstream() {
        defaults.set("https://api.auris.fm", forKey: GatewayURLProvider.baseURLKey)
        defaults.set(true, forKey: GatewayURLProvider.directUpstreamKey)
        GatewayURLProvider.shared = GatewayURLProvider(defaults: defaults, buildDefaultGatewayURL: "")

        XCTAssertTrue(ServerConstants.Urls.api().hasPrefix("https://api.pocketcasts."))
        XCTAssertTrue(ServerConstants.Urls.discover().hasPrefix("https://static.pocketcasts."))
    }
}
