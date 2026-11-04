import XCTest
@testable import podcasts

/// Focused control for the sharing switch binding (reviewer 042d5a69 finding 2, @spec a98e—
/// request "pending-withdrawal check"): withdrawal stops LOCAL collection while the server
/// projection can remain enrolled, so a switch bound to `voiceSharingEnrolled` springs back on
/// after withdrawal and cannot be re-enabled. The binding reads `locallyOptedIn`; this control
/// pins the model state the binding renders, including the pending state (local off, projection
/// still enrolled) which must be VISIBLE as pending rather than confirmed-on or confirmed-off.
@MainActor
final class VoiceSharingWithdrawalBindingTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var store: VoiceSharingEnrollmentStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vswithdraw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: root.absoluteString)
        store = VoiceSharingDeletionFixture.enroll(
            VoiceSharingEnrollmentStore(
                defaults: defaults, accountScopeProvider: { "account-a" },
                sessionIdentityProvider: { "gen-1" }),
            defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: root.absoluteString)
        try? FileManager.default.removeItem(at: root)
    }

    private func model() -> VoiceSharingAccountModel {
        VoiceSharingAccountModel(
            store: store,
            client: VoiceSharingAccountClient(tokenProvider: NeverTokenProvider()),
            disclosureVersion: "v1",
            session: { "gen-1" },
            purgeLocal: nil)
    }

    /// The precondition state: local on and projection enrolled render as ON.
    func test_enrolledOptInRendersOn() {
        let m = model()
        XCTAssertTrue(m.locallyOptedIn == true, "precondition: opted in")
        XCTAssertNotNil(m.membership?.membershipRevision, "precondition: authoritative projection")
    }

    /// THE BINDING PROPERTY: after a local withdrawal with NO confirmed server reply, the local
    /// preference is OFF while the projection still reads enrolled. The switch must read OFF, and
    /// the model must still expose the enrolled projection so the surface can render PENDING —
    /// neither a confirmed-on nor a confirmed-off state.
    func test_withdrawalLeavesLocalOffWithProjectionEnrolled() async {
        let m = model()
        await m.withdraw()
        XCTAssertEqual(m.locallyOptedIn, false,
                       "the switch must read OFF immediately: withdrawal stops local collection")
        XCTAssertEqual(m.membershipStatus, .withdrawalUnconfirmed,
                       "no server confirmation arrived: the withdrawal is UNCONFIRMED, never done")
    }

    /// Re-enable after a failed withdrawal must be possible: the local preference is the source
    /// of the switch, not a terminal server verdict (finding 2's "cannot be turned back on").
    func test_localOptInCanBeRestoredAfterWithdrawal() async {
        let m = model()
        await m.withdraw()
        store.setLocalOptIn(true)
        XCTAssertEqual(m.locallyOptedIn, true, "re-enable is a local preference change, not blocked")
    }

    /// A nil local preference (no readable state) renders as UNKNOWN, never as off-confirmed:
    /// the view disables the switch and explains rather than implying a decision was made.
    func test_nilLocalPreferenceIsUnknownNotConfirmedOff() {
        let blank = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "account-b" },
            sessionIdentityProvider: { "gen-1" })
        let m = VoiceSharingAccountModel(
            store: blank,
            client: VoiceSharingAccountClient(tokenProvider: NeverTokenProvider()),
            disclosureVersion: "v1",
            session: { "gen-1" },
            purgeLocal: nil)
        XCTAssertNil(m.locallyOptedIn, "an unreadable local state is UNKNOWN, not off")
    }
}

/// A credential source that never yields a token: withdraw()'s server step cannot begin, which
/// is exactly the "withdrawal sent nowhere, locally stopped" state the binding must survive.
private struct NeverTokenProvider: CloudTokenProviding {
    func token() async -> String? { nil }
}
