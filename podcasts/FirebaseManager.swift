import PocketCastsUtils
import FirebaseRemoteConfig

struct FirebaseManager {
    static func refreshRemoteConfig(expirationDuration: TimeInterval = 2.hour, completion: ((RemoteConfigFetchStatus) -> Void)? = nil) {
        // we user remote config for varies parameters in the app we want to be able to set remotely. Here we set the defaults, then fetch new ones
        let remoteConfig = RemoteConfig.remoteConfig()
        var remoteConfigDefaults = [
            Constants.RemoteParams.periodicSaveTimeMs: NSNumber(value: Constants.RemoteParams.periodicSaveTimeMsDefault),
            Constants.RemoteParams.episodeSearchDebounceMs: NSNumber(value: Constants.RemoteParams.episodeSearchDebounceMsDefault),
            Constants.RemoteParams.podcastSearchDebounceMs: NSNumber(value: Constants.RemoteParams.podcastSearchDebounceMsDefault),
            Constants.RemoteParams.customStorageLimitGB: NSNumber(value: Constants.RemoteParams.customStorageLimitGBDefault),
            Constants.RemoteParams.endOfYearRequireAccount: NSNumber(value: Constants.RemoteParams.endOfYearRequireAccountDefault),
            Constants.RemoteParams.patronCloudStorageGB: NSNumber(value: Constants.RemoteParams.patronCloudStorageGBDefault),
            Constants.RemoteParams.addMissingEpisodes: NSNumber(value: Constants.RemoteParams.addMissingEpisodesDefault),
            Constants.RemoteParams.errorLogoutHandling: NSNumber(value: Constants.RemoteParams.errorLogoutHandlingDefault),
            Constants.RemoteParams.slumberStudiosPromoCode: NSString(string: Constants.RemoteParams.slumberStudiosPromoCodeDefault),
            // Voice Sharing: default false. Registration here is NOT an enable path —
            // the policy snapshot ignores defaults entirely and requires a valid value
            // read after activate completes (see VoiceSharingPolicy).
            Constants.RemoteParams.voiceSharingEnabled: NSNumber(value: Constants.RemoteParams.voiceSharingEnabledDefault)
        ]
        FeatureFlag.allCases.filter { $0.remoteKey != nil }.forEach { flag in
            remoteConfigDefaults[flag.remoteKey!] = NSNumber(value: flag.default)
        }
        remoteConfig.setDefaults(remoteConfigDefaults)

        remoteConfig.fetch(withExpirationDuration: expirationDuration) { status, _ in
            if status == .success {
                remoteConfig.activate { _, _ in
                    #if !APPCLIP
                    // Snapshot installation happens AFTER activate finishes, never after
                    // fetch alone: reading values between fetch and activate would mix
                    // template generations. Completion order matters for VoiceSharingPolicy's
                    // "valid only post-fetch/activate" rule.
                    //
                    // App-only by necessity AND by policy: FirebaseManager.swift is also compiled
                    // into the App Clip (and TV) targets, which do not include the VoiceControl
                    // sources at all, so an unguarded reference there does not compile. Skipping
                    // the refresh leaves those targets on the fail-closed snapshot (no valid
                    // post-activate value => collection disabled), which is the correct state for
                    // surfaces that cannot capture voice anyway.
                    VoiceSharingCoordinator.shared.policyRefreshAfterActivation()
                    #endif
                    completion?(status)
                }
            } else {
                completion?(status)
            }
        }
    }
}
