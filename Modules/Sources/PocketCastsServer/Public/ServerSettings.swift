import Foundation
import PocketCastsUtils

public class ServerSettings {
    // MARK: - Last Update Status

    private static let lastSyncSuccess = "LastSyncSuccess"
    public class func lastSyncSucceeded() -> Bool {
        if let succeeded = UserDefaults.standard.value(forKey: lastSyncSuccess) as? Bool {
            return succeeded
        }

        return true
    }

    public class func setLastSyncSucceeded(_ succeeded: Bool) {
        UserDefaults.standard.set(succeeded, forKey: lastSyncSuccess)
    }

    private static let lastRefreshSuccess = "LastRefreshSuccess"
    public class func lastRefreshSucceeded() -> Bool {
        if let succeeded = UserDefaults.standard.value(forKey: lastRefreshSuccess) as? Bool {
            return succeeded
        }

        return true
    }

    public class func setLastRefreshSucceeded(_ succeeded: Bool) {
        UserDefaults.standard.set(succeeded, forKey: lastRefreshSuccess)
    }

    // MARK: - Skip Forward

    private static let skipForwardAmount = "JumpForwardAmountInSeconds"
    private static let skipForwardNeedsSync = "JumpForwardSynced"
    public class func setSkipForwardTime(_ time: Int, syncChange: Bool = true) {
        UserDefaults.standard.set(time, forKey: ServerSettings.skipForwardAmount)

        if syncChange {
            UserDefaults.standard.set(true, forKey: ServerSettings.skipForwardNeedsSync)
        }
    }

    public class func skipForwardTime() -> Int {
        UserDefaults.standard.integer(forKey: ServerSettings.skipForwardAmount)
    }

    public class func skipForwardNeedsSyncing() -> Bool {
        UserDefaults.standard.bool(forKey: ServerSettings.skipForwardNeedsSync)
    }

    public class func setSkipForwardSynced() {
        UserDefaults.standard.set(false, forKey: ServerSettings.skipForwardNeedsSync)
    }

    // MARK: - Skip Back

    private static let skipBackAmount = "JumpBackAmountInSeconds"
    private static let skipBackNeedsSync = "JumpBackSynced"
    public class func setSkipBackTime(_ time: Int, syncChange: Bool = true) {
        UserDefaults.standard.set(time, forKey: ServerSettings.skipBackAmount)

        if syncChange {
            UserDefaults.standard.set(true, forKey: ServerSettings.skipBackNeedsSync)
        }
    }

    public class func skipBackTime() -> Int {
        UserDefaults.standard.integer(forKey: ServerSettings.skipBackAmount)
    }

    public class func skipBackNeedsSyncing() -> Bool {
        UserDefaults.standard.bool(forKey: ServerSettings.skipBackNeedsSync)
    }

    public class func setSkipBackSynced() {
        UserDefaults.standard.set(false, forKey: ServerSettings.skipBackNeedsSync)
    }

    // MARK: Home Grid Order

    private static let homeGridSortOrderKey = "SJPodcastLibrarySort"
    private static let homeGridSortModifiedKey = "SJPodcastLibrarySortModified"
    public class func homeGridSortOrderNeedsSyncing() -> Bool {
        UserDefaults.standard.bool(forKey: ServerSettings.homeGridSortModifiedKey)
    }

    public class func setHomeGridSortOrder(_ order: Int, syncChange: Bool = false) {
        UserDefaults.standard.set(order, forKey: homeGridSortOrderKey)
        if syncChange {
            UserDefaults.standard.set(true, forKey: homeGridSortModifiedKey)
        }
    }

    public class func setHomeGridSortOrderSynced() {
        UserDefaults.standard.set(false, forKey: homeGridSortModifiedKey)
    }

    public class func homeGridSortOrder() -> Int {
        UserDefaults.standard.integer(forKey: homeGridSortOrderKey)
    }

    // MARK: Home Grid Refresh

    private static let homeGridNeedsRefreshKey = "SJHomeGridRefreshRequired"
    public class func setHomeGridNeedsRefresh(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: homeGridNeedsRefreshKey)
    }

    public class func homeGridNeedsRefresh() -> Bool {
        UserDefaults.standard.bool(forKey: homeGridNeedsRefreshKey)
    }

    // MARK: Clear Listening History Date

    public class func setLastClearHistoryDate(_ value: Date?) {
        if let newDate = value {
            UserDefaults.standard.set(newDate, forKey: ServerConstants.UserDefaults.lastClearHistoryDate)
        } else {
            UserDefaults.standard.removeObject(forKey: ServerConstants.UserDefaults.lastClearHistoryDate)
        }
    }

    public class func lastClearHistoryDate() -> Date? {
        UserDefaults.standard.value(forKey: ServerConstants.UserDefaults.lastClearHistoryDate) as? Date
    }

    // MARK: Marketing Opt In

    public class func setMarketingOptIn(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: ServerConstants.UserDefaults.marketingOptInKey)
        UserDefaults.standard.set(true, forKey: ServerConstants.UserDefaults.marketingOptInNeedsSyncKey)
    }

    public class func marketingOptIn() -> Bool {
        UserDefaults.standard.bool(forKey: ServerConstants.UserDefaults.marketingOptInKey)
    }

    public class func marketingOptInNeedsSyncing() -> Bool {
        UserDefaults.standard.bool(forKey: ServerConstants.UserDefaults.marketingOptInNeedsSyncKey)
    }

    public class func marketingOptInSynced() {
        UserDefaults.standard.set(false, forKey: ServerConstants.UserDefaults.marketingOptInNeedsSyncKey)
    }

    // MARK: Audio Only

    public class func setAudioOnly(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: ServerConstants.UserDefaults.audioOnlyKey)
        UserDefaults.standard.set(true, forKey: ServerConstants.UserDefaults.audioOnlyNeedsSyncKey)
    }

    public class func audioOnly() -> Bool {
        UserDefaults.standard.bool(forKey: ServerConstants.UserDefaults.audioOnlyKey)
    }

    public class func audioOnlyNeedsSyncing() -> Bool {
        UserDefaults.standard.bool(forKey: ServerConstants.UserDefaults.audioOnlyNeedsSyncKey)
    }

    public class func audioOnlySynced() {
        UserDefaults.standard.set(false, forKey: ServerConstants.UserDefaults.audioOnlyNeedsSyncKey)
    }

    // MARK: Disable AI Chapters

    public class func setDisableAiChapters(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: ServerConstants.UserDefaults.disableAiChaptersKey)
        UserDefaults.standard.set(true, forKey: ServerConstants.UserDefaults.disableAiChaptersNeedsSyncKey)
    }

    public class func disableAiChapters() -> Bool {
        UserDefaults.standard.bool(forKey: ServerConstants.UserDefaults.disableAiChaptersKey)
    }

    public class func disableAiChaptersNeedsSyncing() -> Bool {
        UserDefaults.standard.bool(forKey: ServerConstants.UserDefaults.disableAiChaptersNeedsSyncKey)
    }

    public class func disableAiChaptersSynced() {
        UserDefaults.standard.set(false, forKey: ServerConstants.UserDefaults.disableAiChaptersNeedsSyncKey)
    }

    // MARK: Date of Latest UnsentSubscription Purchase Receipt

    private static let iapUnverifiedPurchaseReceipDatetKey = "SJIapDateUnverifiedPurchaseReceipt"
    public class func setIapUnverifiedPurchaseReceiptDate(_ value: Date?) {
        UserDefaults.standard.set(value, forKey: iapUnverifiedPurchaseReceipDatetKey)
    }

    public class func iapUnverifiedPurchaseReceiptDate() -> Date? {
        UserDefaults.standard.object(forKey: iapUnverifiedPurchaseReceipDatetKey) as? Date
    }

    // MARK: Files last modified

    public class func setFilesLastModified(_ value: String) {
        UserDefaults.standard.set(value, forKey: ServerConstants.UserDefaults.filesLastModifiedKey)
    }

    public class func filesLastModified() -> String? {
        UserDefaults.standard.string(forKey: ServerConstants.UserDefaults.filesLastModifiedKey)
    }

    public class func removeFilesLastModifiedKey() {
        UserDefaults.standard.removeObject(forKey: ServerConstants.UserDefaults.filesLastModifiedKey)
    }

    private static let filesUsageLastModifiedKey = "UserFilesUsageLastModified"

    public class func setFilesUsageLastModified(_ value: String) {
        UserDefaults.standard.set(value, forKey: filesUsageLastModifiedKey)
    }

    public class func filesUsageLastModified() -> String? {
        UserDefaults.standard.string(forKey: filesUsageLastModifiedKey)
    }

    public class func removeFilesUsageLastModifiedKey() {
        UserDefaults.standard.removeObject(forKey: filesUsageLastModifiedKey)
    }

    // MARK: Custom Storage limit from user

    public class func setCustomStorageUserLimit(_ value: Int) {
        UserDefaults.standard.set(value, forKey: ServerConstants.Values.customStorageUserLimit)
    }

    public class func customStorageUserLimit() -> Int {
        UserDefaults.standard.integer(forKey: ServerConstants.Values.customStorageUserLimit)
    }

    // MARK: Custom Storage used on server

    public class func setCustomStorageUsed(_ value: Int) {
        UserDefaults.standard.set(value, forKey: ServerConstants.Values.customStorageUsed)
    }

    public class func customStorageUsed() -> Int {
        UserDefaults.standard.integer(forKey: ServerConstants.Values.customStorageUsed)
    }

    // MARK: Custom Storage number of files on server

    public class func setCustomStorageNumFiles(_ value: Int) {
        UserDefaults.standard.set(value, forKey: ServerConstants.Values.customStorageNumFiles)
    }

    public class func customStorageNumFiles() -> Int {
        UserDefaults.standard.integer(forKey: ServerConstants.Values.customStorageNumFiles)
    }

    // User files autodownload
    private static let userEpisodeAutoDownloadKey = "UserEpisodeAutoDownload"
    public class func userEpisodeAutoDownload() -> Bool {
        UserDefaults.standard.bool(forKey: userEpisodeAutoDownloadKey)
    }

    public class func setUserEpisodeAutoDownload(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: userEpisodeAutoDownloadKey)
    }

    // User files autodownload on wifi
    private static let userEpisodeOnlyOnWifiKey = "UserEpisodeOnlyOnWifi"
    public class func userEpisodeOnlyOnWifi() -> Bool {
        UserDefaults.standard.bool(forKey: userEpisodeOnlyOnWifiKey)
    }

    public class func setUserEpisodeOnlyOnWifi(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: userEpisodeOnlyOnWifiKey)
    }

    public class func syncingEmail() -> String? {
        authenticationLock.withLock {
            guard !UserDefaults.standard.bool(forKey: incompleteCredentialWriteKey) else { return nil }
            return try? KeychainHelper.string(for: ServerConstants.Values.syncingEmailKey)
        }
    }

    public class func setSyncingEmail(email: String?) {
        if let email {
            KeychainHelper.save(string: email, key: ServerConstants.Values.syncingEmailKey, accessibility: kSecAttrAccessibleAfterFirstUnlock)
        } else {
            KeychainHelper.removeKey(ServerConstants.Values.syncingEmailKey)
        }
    }

    // The two methods below should only be used for migration purposes, it's the old way of storing email addresses we don't use anymore
    public class func syncingEmailLegacy() -> String? {
        UserDefaults.standard.string(forKey: ServerConstants.UserDefaults.syncingEmailLegacy)
    }

    public class func removeLegacySyncingEmail() {
        UserDefaults.standard.removeObject(forKey: ServerConstants.UserDefaults.syncingEmailLegacy)
    }

    public class func saveSyncingPassword(_ password: String) {
        KeychainHelper.save(string: password, key: ServerConstants.Values.syncingPasswordKey, accessibility: kSecAttrAccessibleAfterFirstUnlock)
    }

    public class func syncingPassword() -> String? {
        authenticationLock.withLock {
            guard !UserDefaults.standard.bool(forKey: incompleteCredentialWriteKey) else { return nil }
            return try? KeychainHelper.string(for: ServerConstants.Values.syncingPasswordKey)
        }
    }

    public class func lastRefreshStartTime() -> Date? {
        UserDefaults.standard.object(forKey: ServerConstants.UserDefaults.lastRefreshStartTime) as? Date
    }

    public class func lastRefreshEndTime() -> Date? {
        UserDefaults.standard.object(forKey: ServerConstants.UserDefaults.lastRefreshEndTime) as? Date
    }

    public class func clearLastSyncTime() {
        UserDefaults.standard.removeObject(forKey: ServerConstants.UserDefaults.lastSyncTime)
    }

    public class var lastSyncTime: Date? {
        UserDefaults.standard.object(forKey: ServerConstants.UserDefaults.lastSyncTime) as? Date
    }

    // Push Token
    public class func pushToken() -> String? {
        UserDefaults.standard.string(forKey: ServerConstants.UserDefaults.pushToken)
    }

    public class func setPushToken(token: String) {
        UserDefaults.standard.set(token, forKey: ServerConstants.UserDefaults.pushToken)
    }

    public class func removePushToken() {
        UserDefaults.standard.removeObject(forKey: ServerConstants.UserDefaults.pushToken)
    }

    // MARK: - Auto add to Up Next Limit

    public static let autoAddLimitKey = "AutoAddToUpNextLimit"
    public class func autoAddToUpNextLimit() -> Int {
        UserDefaults.standard.integer(forKey: autoAddLimitKey)
    }

    public class func setAutoAddToUpNextLimit(_ limit: Int) {
        UserDefaults.standard.setValue(limit, forKey: autoAddLimitKey)
    }

    public static let onAutoAddLimitReachedKey = "AutoAddLimitReachedKey"
    public class func onAutoAddLimitReached() -> AutoAddLimitReachedAction {
        let storedValue = UserDefaults.standard.integer(forKey: onAutoAddLimitReachedKey)

        return AutoAddLimitReachedAction(rawValue: Int32(storedValue)) ?? .stopAdding
    }

    public class func setOnAutoAddLimitReached(action: AutoAddLimitReachedAction) {
        UserDefaults.standard.setValue(action.rawValue, forKey: onAutoAddLimitReachedKey)
    }

    public class func syncSettings() {
        guard SyncManager.isUserLoggedIn(), ServerSettings.marketingOptInNeedsSyncing() || ServerSettings.audioOnlyNeedsSyncing() || ServerSettings.disableAiChaptersNeedsSyncing() || SubscriptionHelper.subscriptionGiftAcknowledgementNeedsSyncing() else { return }

        ApiServerHandler.shared.syncSettings()
    }
}

// MARK: - Authentication Support

public extension ServerSettings {
    class var userId: String? {
        get {
            UserDefaults.standard.string(forKey: ServerConstants.UserDefaults.userId)
        }

        set {
            UserDefaults.standard.set(newValue, forKey: ServerConstants.UserDefaults.userId)
        }
    }

    class var syncingV2Token: String? {
        get {
            authenticationLock.withLock {
                guard !UserDefaults.standard.bool(forKey: incompleteCredentialWriteKey) else { return nil }
                return try? KeychainHelper.string(for: ServerConstants.Values.syncingV2TokenKey)
            }
        }

        set {
            KeychainHelper.save(string: newValue, key: ServerConstants.Values.syncingV2TokenKey, accessibility: kSecAttrAccessibleAfterFirstUnlock)
        }
    }

    class func refreshToken() throws -> String? {
        try authenticationLock.withLock {
            guard !UserDefaults.standard.bool(forKey: incompleteCredentialWriteKey) else { return nil }
            return try KeychainHelper.string(for: ServerConstants.Values.refreshTokenKey).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    class func setRefreshToken(_ newValue: String?) {
        KeychainHelper.save(string: newValue, key: ServerConstants.Values.refreshTokenKey, accessibility: kSecAttrAccessibleAfterFirstUnlock)
    }
}

// MARK: - Live Analytics Debugging

public extension ServerSettings {
    private static let liveAnalyticsUrlKey = "SJLiveAnalyticsUrl"

    /// URL for streaming analytics events to a remote debugging endpoint.
    /// This is set by the server and enables live analytics debugging when non-empty.
    class var liveAnalyticsUrl: String? {
        get {
            UserDefaults.standard.string(forKey: liveAnalyticsUrlKey)
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: liveAnalyticsUrlKey)
            } else {
                UserDefaults.standard.removeObject(forKey: liveAnalyticsUrlKey)
            }
        }
    }
}


/// A request's right to change the current session. Created before networking.
public struct AuthenticationAttempt {
    fileprivate let id = UUID()
    fileprivate let generation: Int
    fileprivate let email: String?
    fileprivate let uuid: String?
    fileprivate let explicit: Bool
}

public extension ServerSettings {
    private static let authenticationLock = NSRecursiveLock()
    private static var authenticationGeneration = 0
    private static var explicitAuthentication: UUID?
    private static var committedAuthentication: UUID?
    private static let incompleteCredentialWriteKey = "AurisIncompleteCredentialWrite"

    private static var passwordSessionMigration: (generation: Int, retryAfter: Date, inFlight: Bool)?

    /// Shared across credential-provider instances. The first attempt remains synchronous;
    /// failed or concurrent lookups cannot repeat that network wait for the same session.
    static func refreshPasswordSessionIfNeeded(now: Date = Date(), acquire: (() -> Void)? = nil) {
        let generation: Int? = authenticationLock.withLock {
            guard (try? refreshToken()) == nil, syncingEmail() != nil, syncingPassword() != nil else { return nil }
            if let previous = passwordSessionMigration, previous.generation == authenticationGeneration,
               previous.inFlight || now < previous.retryAfter { return nil }
            passwordSessionMigration = (authenticationGeneration, now.addingTimeInterval(60), true)
            return authenticationGeneration
        }
        guard let generation else { return }
        defer {
            authenticationLock.withLock {
                if passwordSessionMigration?.generation == generation { passwordSessionMigration?.inFlight = false }
            }
        }
        // Main-state lookup and networking must never run under authenticationLock.
        if let acquire { acquire() }
        else { _ = TokenHelper.shared.acquireToken(onlyIfMissingRefresh: true) }
    }

    static func beginAuthentication(email: String? = nil, explicit: Bool = true) -> AuthenticationAttempt? {
        authenticationLock.withLock {
            if !explicit, explicitAuthentication != nil { return nil }
            if explicit { authenticationGeneration += 1 }
            let attempt = AuthenticationAttempt(generation: authenticationGeneration,
                email: explicit ? email : syncingEmail(), uuid: explicit ? nil : userId, explicit: explicit)
            if explicit { explicitAuthentication = attempt.id }
            return attempt
        }
    }

    static func finishAuthentication(_ attempt: AuthenticationAttempt) {
        authenticationLock.withLock {
            if explicitAuthentication == attempt.id { explicitAuthentication = nil }
        }
    }

    /// The existing two keychain items are not a crash-atomic pair. A persisted marker makes
    /// a failed rollback unavailable to readers. This is not a durable cross-process
    /// transaction: a crash before the defaults marker persists can still interrupt the pair.
    /// `write` is injectable so controls can exercise failures without changing user credentials.
    static func commitAuthentication(_ response: AuthenticationResponse, for attempt: AuthenticationAttempt,
                                     password: String? = nil,
                                     read: (String) throws -> String? = { try KeychainHelper.string(for: $0) },
                                     write: ((String?, String) -> Bool)? = nil,
                                     defaults: UserDefaults = .standard) -> Bool {
        authenticationLock.withLock {
            guard attempt.generation == authenticationGeneration else {
                FileLog.shared.addMessage("Authentication response rejected: superseded request")
                return false
            }
            // A renewal may omit unchanged identity fields. Only its captured verified account
            // supplies those fields; an explicit login still has to return its full identity.
            guard let access = response.token, !access.isEmpty,
                  let email = response.email ?? (attempt.explicit ? nil : attempt.email), !email.isEmpty,
                  let uuid = response.uuid ?? (attempt.explicit ? nil : attempt.uuid), !uuid.isEmpty,
                  attempt.email == nil || attempt.email?.lowercased() == email.lowercased(),
                  attempt.uuid == nil || attempt.uuid == uuid else {
                FileLog.shared.addMessage("Authentication response rejected: missing credentials or account mismatch")
                return false
            }
            let refresh = response.refreshToken.flatMap { $0.isEmpty ? nil : $0 }
            guard !attempt.explicit || refresh != nil else { return false }
            let keys = [ServerConstants.Values.refreshTokenKey, ServerConstants.Values.syncingV2TokenKey]
                + (attempt.explicit ? [ServerConstants.Values.syncingEmailKey, ServerConstants.Values.syncingPasswordKey] : [])
            let previous: [String?]
            do { previous = try keys.map(read) } catch { return false }
            guard let finalRefresh = refresh ?? previous[0], !finalRefresh.isEmpty else { return false }
            let values: [String?] = [finalRefresh, access] + (attempt.explicit ? [email, password] : [])
            let save = write ?? { KeychainHelper.save(string: $0, key: $1, accessibility: kSecAttrAccessibleAfterFirstUnlock) }
            let previouslyUnavailable = defaults.bool(forKey: incompleteCredentialWriteKey)
            defaults.set(true, forKey: incompleteCredentialWriteKey)
            for (key, value) in zip(keys, values) {
                guard save(value, key) else {
                    var restored = true
                    for (oldKey, oldValue) in zip(keys, previous) {
                        if !save(oldValue, oldKey) { restored = false }
                    }
                    if restored { defaults.set(previouslyUnavailable, forKey: incompleteCredentialWriteKey) }
                    return false
                }
            }
            if attempt.explicit { defaults.set(uuid, forKey: ServerConstants.UserDefaults.userId) }
            defaults.set(false, forKey: incompleteCredentialWriteKey)
            authenticationGeneration += 1
            explicitAuthentication = nil
            committedAuthentication = attempt.id
            return true
        }
    }

    /// Nonblocking observation for a notification reentry control; never waits on a failed lock.
    internal static func authenticationLockAvailableForTesting() -> Bool {
        guard authenticationLock.try() else { return false }
        authenticationLock.unlock()
        return true
    }

    static func committedAuthenticationID() -> UUID? {
        authenticationLock.withLock { committedAuthentication }
    }

    @discardableResult
    static func withCommittedAuthenticationID(_ id: UUID?, _ action: () -> Void) -> Bool {
        authenticationLock.withLock {
            guard let id, committedAuthentication == id else { return false }
            action()
            return true
        }
    }

    /// Delayed success/UI effects must still belong to this exact committed login.
    @discardableResult
    static func withCommittedAuthentication(_ attempt: AuthenticationAttempt, _ action: () -> Void) -> Bool {
        authenticationLock.withLock {
            guard committedAuthentication == attempt.id else { return false }
            action()
            return true
        }
    }

    /// Signout and account-field clears share the same lock as commits.
    @discardableResult
    static func invalidateAuthentication(defaults: UserDefaults = .standard, _ action: () -> Void) -> AuthenticationAttempt {
        authenticationLock.withLock {
            authenticationGeneration += 1
            explicitAuthentication = nil
            committedAuthentication = nil
            defaults.set(true, forKey: incompleteCredentialWriteKey)
            action()
            return AuthenticationAttempt(generation: authenticationGeneration, email: nil, uuid: nil, explicit: false)
        }
    }

    /// Successful clears leave the existing registration/watch restore setters usable.
    /// Failed clears retain the unavailable marker instead of exposing leftover credentials.
    static func clearAuthentication(defaults: UserDefaults = .standard,
                                    remove: (String) -> Bool = { KeychainHelper.removeKey($0) }) {
        invalidateAuthentication(defaults: defaults) {
            let keys = [ServerConstants.Values.syncingEmailKey, ServerConstants.Values.syncingPasswordKey,
                        ServerConstants.Values.syncingV2TokenKey, ServerConstants.Values.refreshTokenKey,
                        ServerConstants.Values.appleAuthUserIDKey]
            var cleared = true
            for key in keys {
                if !remove(key) { cleared = false }
            }
            if cleared { defaults.set(false, forKey: incompleteCredentialWriteKey) }
        }
    }

    static func ifAuthenticationIsCurrent(_ attempt: AuthenticationAttempt, _ action: () -> Void) {
        authenticationLock.withLock {
            guard attempt.generation == authenticationGeneration else { return }
            action()
        }
    }

    static func invalidateAccessToken(_ rejected: String?) {
        authenticationLock.withLock {
            guard let rejected, syncingV2Token == rejected else { return }
            KeychainHelper.removeKey(ServerConstants.Values.syncingV2TokenKey)
        }
    }
}
