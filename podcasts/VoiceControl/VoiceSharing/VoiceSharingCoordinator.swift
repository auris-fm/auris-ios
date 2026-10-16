import Foundation
import Firebase

/// Composition point for the Voice Sharing feature on iOS.
///
/// Owns the policy snapshot and exposes the single decision every other component
/// asks: may collection run right now? Keeping construction here (rather than a
/// singleton maze) means tests can build a coordinator with stubbed providers,
/// exactly like the rest of the voice pipeline injects clocks and sources.
final class VoiceSharingCoordinator {
    static let shared = VoiceSharingCoordinator()

    let policy: VoiceSharingPolicy

    /// Production wiring reads the remote switch through the existing typed-accessor
    /// pattern but WITHOUT the local-default fallback that other flags use: a default
    /// must never satisfy the policy. Only a value that exists post-activate counts.
    init(
        clock: MonotonicClock = SystemMonotonicClock(),
        readRemoteSwitch: (() -> VoiceSharingPolicy.RemoteSwitchValue)? = nil,
        isAccountEnrolled: (() -> Bool)? = nil
    ) {
        self.policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: readRemoteSwitch ?? Self.readActivatedSwitch,
            isAccountEnrolled: isAccountEnrolled ?? { false } // enrollment backend API lands in cloud lane; fail closed until then
        )
    }

    /// Called from the fetch→activate completion path. Reads source-of-truth values
    /// only if activation actually delivered them.
    func policyRefreshAfterActivation() {
        policy.refreshAfterActivation()
    }

    private static func readActivatedSwitch() -> VoiceSharingPolicy.RemoteSwitchValue {
        guard FirebaseApp.app() != nil else { return .unavailable }
        let config = RemoteConfig.remoteConfig()
        // The VALUE SOURCE is the gate: only `.remote` (a genuinely published server
        // value) counts. `.default` here means OUR compiled fallback, and `.static` means
        // the key doesn't exist at all — neither may satisfy the policy. That is the
        // fail-closed asymmetry the spec requires.
        //
        // `RemoteConfigValue` exposes stringValue/numberValue/dataValue/boolValue/jsonValue
        // and `source` — there is no `status` property on it, so `source` is the only
        // existence signal available and it is checked first, before any coercion.
        let value = config.configValue(forKey: Constants.RemoteParams.voiceSharingEnabled)
        guard value.source == .remote else { return .unavailable }
        // RemoteConfig coerces loosely (strings become numbers, etc.). Accept only a
        // genuine boolean or a strict 0/1 publication; anything else is invalid ⇒ off.
        guard let number = value.numberValue as? NSNumber else { return .unavailable }
        if number === kCFBooleanTrue { return .valid(true) }
        if number === kCFBooleanFalse { return .valid(false) }
        switch number.intValue {
        case 0: return .valid(false)
        case 1: return .valid(true)
        default: return .unavailable
        }
    }
}
