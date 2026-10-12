import XCTest

@testable import PocketCastsServer
@testable import podcasts

class AutoplayHelperTests: XCTestCase {
    var autoplayHelper: AutoplayHelper!

    /// The suite this case uses, so teardown can clear exactly this one.
    ///
    /// The name was `Int.random(in: 0..<1000)` — 1000 possible values across ~1350 tests, so two
    /// cases can draw the same name and the second inherits the first's persisted value. A UUID
    /// makes a collision impossible rather than unlikely, and the teardown removes the domain so
    /// nothing outlives the case either.
    private var suiteName: String!

    override func setUp() {
        // A forced-collision control sets this to a FIXED name, which reproduces the shared-suite
        // arrangement on purpose. Without the control the observation stays an inference: the
        // failure is consistent with a collision but a collision was never demonstrated.
        suiteName = ProcessInfo.processInfo.environment["AURIS_AUTOPLAY_SHARED_SUITE"]
            ?? "autoplay_helper_\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        autoplayHelper = AutoplayHelper(
            userDefaults: userDefaults
        )
        SettingsStore.appSettings = SettingsStore(userDefaults: userDefaults, key: "app_settings", value: AppSettings.defaults)
    }

    override func tearDown() {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        autoplayHelper = nil
        super.tearDown()
    }

    func testInitialValueIsNil() {
        XCTAssertNil(autoplayHelper.lastPlaylist)
    }

    func testSaveLatestPlaylist() {
        autoplayHelper.playedFrom(playlist: .podcast(uuid: "fake-uuid"))

        switch autoplayHelper.lastPlaylist {
        case .podcast(uuid: let uuid):
            XCTAssertTrue(uuid == "fake-uuid")
        default:
            XCTFail()
        }
    }

    func testCorrectlyUpdateLatestPlaylist() {
        autoplayHelper.playedFrom(playlist: .podcast(uuid: "fake-uuid"))

        autoplayHelper.playedFrom(playlist: .starred)

        switch autoplayHelper.lastPlaylist {
        case .starred:
            break
        default:
            XCTFail()
        }
    }

    func testCorrectlyRemoveValueIfPlaylistIsUnknown() {
        autoplayHelper.playedFrom(playlist: .podcast(uuid: "fake-uuid"))

        autoplayHelper.playedFrom(playlist: nil)

        XCTAssertNil(autoplayHelper.lastPlaylist)
    }
}
