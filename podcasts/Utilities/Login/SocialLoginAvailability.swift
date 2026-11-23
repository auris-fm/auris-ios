import Foundation
import PocketCastsServer

/// Which social sign-in buttons a build can actually offer.
///
/// `GIDSignIn` raises `NSInvalidArgumentException` when its configured client ID is empty, and an
/// Objective-C exception crossing the Swift continuation in `GoogleSocialLogin` crashes rather than
/// throwing. A build archived with empty credentials would therefore crash on tapping "Continue
/// with Google". Hiding the button when there is no client ID keeps that tap from existing.
enum SocialLoginAvailability {

    static func isAvailable(_ provider: SocialAuthProvider, googleClientId: String) -> Bool {
        switch provider {
        case .apple:
            return true
        case .google:
            return !googleClientId.isEmpty
        }
    }

    /// The providers this build should show, in the enum's own order. Takes the client ID so a
    /// control can drive the same selection the view uses without real credentials.
    static func providers(googleClientId: String) -> [SocialAuthProvider] {
        SocialAuthProvider.allCases.filter { isAvailable($0, googleClientId: googleClientId) }
    }

    static var availableProviders: [SocialAuthProvider] {
        providers(googleClientId: ApiCredentials.googleSignInSecret)
    }
}
