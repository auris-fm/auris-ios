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

        // Freshness must be PROVEN, not assumed from `.success`: the SDK returns
        // FIRRemoteConfigFetchStatusSuccess on its cached path too (RCNConfigFetch short-circuits
        // with Success + nil error when the minimum fetch interval has not elapsed), and it only
        // advances `lastFetchTime` inside updateMetadataWithFetchSuccessStatus, i.e. after a real
        // network exchange. So capture the time before the call and require it to have moved.
        #if os(iOS) && !APPCLIP
        let fetchStartedAt = VoiceSharingCoordinator.shared.nowForFreshnessCheck()
        let fetchToken = VoiceSharingCoordinator.shared.policy.tokenForFetchStart()
        #endif
        remoteConfig.fetch(withExpirationDuration: expirationDuration) { status, error in
            guard status == .success, error == nil else {
                // A failed fetch — including cached/no-network outcomes — must NOT renew the
                // lease. Nothing was activated, so whatever snapshot is installed keeps its
                // existing expiry and simply stops permitting once it lapses.
                completion?(status)
                return
            }
            remoteConfig.activate { _, activationError in
                // The only path that may install/renew a snapshot: a fresh fetch that succeeded
                // AND an activate that returned without error. Installation happens after
                // activate returns, never after fetch alone, so values cannot come from mixed
                // template generations.
                //
                // Condition is `os(iOS) && !APPCLIP`, NOT `!APPCLIP` alone: this file is compiled
                // into podcasts, Pocket Casts App Clip and Pocket Casts TV App, and the TV target's
                // configurations define no APPCLIP flag at all (only Debug sets
                // SWIFT_ACTIVE_COMPILATION_CONDITIONS there), so `!APPCLIP` would reference the
                // app-only Coordinator from the tvOS build, whose sources do not include
                // VoiceControl. Those targets stay on the fail-closed default (disabled), which is
                // correct for surfaces that cannot capture voice.
                #if os(iOS) && !APPCLIP
                let didActivate = activationError == nil
                let provedFreshExchange = VoiceSharingCoordinator.shared.lastFetchAdvancedPast(fetchStartedAt)
                VoiceSharingCoordinator.shared.policyRefreshAfterActivation(
                    freshActivationSucceeded: didActivate && provedFreshExchange,
                    fetchToken: fetchToken
                )
                #endif
                completion?(status)
            }
        }
    }
}
