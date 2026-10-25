import XCTest
@testable import podcasts

/// STAGING-SCHEME SEMANTICS (review 4371027569): the staging scheme builds the Debug
/// configuration since StagingDebug was retired (61a1bf1bd). That configuration must carry
/// `-D STAGING`, or the app compiles ServerSyncManager.production() == true and syncs against
/// the production Pocket Casts hosts, and CrashLoggingDataProvider reports the wrong build
/// type. This control reads the APP-COMPILED build-type string at runtime — the test target's
/// own preprocessor flags are irrelevant, so it sees exactly the flags the app was built with.
final class StagingConfigurationSemanticsTests: XCTestCase {
    func testAppBuildReportsStagingBuildType() {
        XCTAssertEqual(CrashLoggingDataProvider().buildType, "staging",
                       "the Debug configuration built by the staging scheme must carry -D STAGING; "
                           + "\"debug\" here means the build syncs against production hosts")
    }
}
