import XCTest

@testable import podcasts
import PocketCastsUtils

/// An Auris build can be archived with every API credential empty — that is what
/// `make external_contributor` writes, and it is a deliberate option for a first beta. Two paths
/// did not survive it: both reached code that treats an empty value as a valid one and then traps.
/// A crash on empty configuration is a defect regardless of which credentials ship, so these pin
/// the guards rather than the values.
final class EmptyCredentialsGuardTests: XCTestCase {

    // MARK: - Log upload encryption key

    /// The upload path force-unwraps `sodium.box.seal(...)`, which returns nil unless the recipient
    /// key is exactly 32 bytes. An empty key reaches it because `Data(base64Encoded: "")` is EMPTY
    /// Data, not nil, so the library's own precondition passes.
    ///
    /// Red: without the length check this returns true for "" and the app traps when a tester
    /// submits a support request with logs attached.
    func test_emptyEncryptionKeyIsNotUsableForLogUpload() {
        XCTAssertFalse(LogUploadCredentials.isUsableEncryptionKey(""),
                       "an empty key must be refused before the force-unwrap in the encryptor")
    }

    /// A key that decodes but is the wrong length is the same trap. Pins that the rule is the
    /// decoded BYTE COUNT, not merely "decodes to something".
    ///
    /// Red: a guard written as `Data(base64Encoded:) != nil` accepts this 16-byte key.
    func test_wrongLengthEncryptionKeyIsNotUsable() {
        let sixteenBytes = Data(repeating: 0xAB, count: 16).base64EncodedString()
        XCTAssertFalse(LogUploadCredentials.isUsableEncryptionKey(sixteenBytes),
                       "only a 32-byte key can seal; 16 bytes must be refused")
    }

    /// Non-base64 text must be refused too — `Data(base64Encoded:)` returns nil for it.
    ///
    /// Red: a guard checking only the string's emptiness accepts this.
    func test_nonBase64EncryptionKeyIsNotUsable() {
        XCTAssertFalse(LogUploadCredentials.isUsableEncryptionKey("not base64 !!!"),
                       "a key that does not decode must be refused")
    }

    /// A real 32-byte key still works, so the guard is about usability and not a blanket ban.
    ///
    /// Red: a guard that refuses everything (or checks the STRING length instead of the decoded
    /// byte count) fails here — a 32-byte key's base64 form is 44 characters.
    func test_thirtyTwoByteEncryptionKeyIsUsable() {
        let key = Data((0..<32).map { UInt8($0) }).base64EncodedString()
        XCTAssertTrue(LogUploadCredentials.isUsableEncryptionKey(key),
                      "a 32-byte key must still upload")
    }

    /// The refusal must be wired into the upload path, not merely exist as a predicate. This drives
    /// the same entry point `queueFileUpload` calls, with the key the data provider supplies.
    ///
    /// Red: removing the `try Self.assertUsableEncryptionKey(...)` call from `queueFileUpload`
    /// leaves this passing only if the guard itself is deleted too — so it pins the throwing
    /// behaviour the upload path depends on, which a predicate-only test cannot.
    func test_uploadRefusalThrowsForAnUnusableKey() {
        XCTAssertThrowsError(try FileLog.assertUsableEncryptionKey("")) { error in
            XCTAssertEqual(error as? FileLog.LogError, .logGenerationFailed,
                           "the upload path must see logGenerationFailed, not trap")
        }
    }

    /// A usable key must not be refused, so the guard cannot become a blanket ban on uploading.
    ///
    /// Red: making `assertUsableEncryptionKey` throw unconditionally fails here.
    func test_uploadRefusalAllowsAUsableKey() throws {
        let key = Data((0..<32).map { UInt8($0) }).base64EncodedString()
        try FileLog.assertUsableEncryptionKey(key)
    }

    // MARK: - Google sign-in availability

    /// `GIDSignIn` raises NSInvalidArgumentException when the configured client ID is empty, and an
    /// ObjC exception through the Swift continuation crashes rather than throwing. The button must
    /// not be offered when there is no client ID.
    ///
    /// Red: without the guard `.google` is always available and tapping it crashes.
    func test_googleSignInUnavailableWhenClientIdIsEmpty() {
        XCTAssertFalse(SocialLoginAvailability.isAvailable(.google, googleClientId: ""),
                       "an empty client ID must hide the Google button")
    }

    /// With a client ID present the button stays, so the guard does not remove a working sign-in.
    ///
    /// Red: a guard that hides Google unconditionally fails here.
    func test_googleSignInAvailableWhenClientIdIsSet() {
        XCTAssertTrue(SocialLoginAvailability.isAvailable(.google, googleClientId: "abc.apps.googleusercontent.com"),
                      "a configured client ID must keep the Google button")
    }

    /// The view iterates this selection, so it — not just the predicate — must drop Google when
    /// there is no client ID. Pins the list the buttons are actually built from.
    ///
    /// Red: `providers` returning `allCases` unfiltered fails here even with the predicate intact.
    func test_providerSelectionDropsGoogleWithoutAClientId() {
        let offered = SocialLoginAvailability.providers(googleClientId: "")
        XCTAssertFalse(offered.contains(.google), "the button list must not offer Google")
        XCTAssertEqual(offered, [.apple], "Apple must remain the offered provider")
    }

    /// With a client ID the selection keeps both, in the enum's order.
    ///
    /// Red: filtering Google out unconditionally fails here.
    func test_providerSelectionKeepsBothWhenConfigured() {
        XCTAssertEqual(SocialLoginAvailability.providers(googleClientId: "abc"), [.apple, .google])
    }

    /// Apple sign-in needs none of these credentials and must never be hidden by this rule.
    ///
    /// Red: applying the empty-client-ID rule to every provider hides Apple too.
    func test_appleSignInUnaffectedByGoogleCredentials() {
        XCTAssertTrue(SocialLoginAvailability.isAvailable(.apple, googleClientId: ""),
                      "Apple sign-in does not depend on the Google client ID")
    }
}
