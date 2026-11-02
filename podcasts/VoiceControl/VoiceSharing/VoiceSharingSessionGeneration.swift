import Foundation

/// Non-secret, in-memory lifecycle generation for account-scoped work.
///
/// Design (per @spec, DM f5a9275f): a fresh UUID minted when a session is established, rotated on real
/// sign-in / sign-out / account switch, and deliberately STABLE across access- and refresh-token renewal.
/// There is no credential-derived digest and nothing persisted: after a relaunch the process starts a new
/// lifecycle, membership is re-read authoritatively, and an old account mutation is never auto-replayed.
///
/// Why operations need this at all:
/// * A stable user id survives sign-out followed by signing back into the SAME account, so it cannot see
///   the one transition that must invalidate an outstanding mutation.
/// * A rotating credential would read routine token maintenance as a logout and wrongly refuse work the
///   user already started — so credentials are not used as identity here, and none of their content is
///   ever retained in an operation body, queue metadata, logs, or diagnostics.
final class VoiceSharingSessionGeneration {
    static let shared = VoiceSharingSessionGeneration()

    private let lock = NSLock()
    private var current: String?

    init() {}

    /// The current lifecycle generation, or nil when there is no authenticated session to act under.
    func currentGeneration() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Establishes a NEW lifecycle (sign-in, account switch, first readable session after launch) and
    /// returns its label. Anything begun under the previous label becomes stale immediately.
    @discardableResult
    func beginNewLifecycle() -> String {
        let label = UUID().uuidString.lowercased()
        lock.lock()
        current = label
        lock.unlock()
        return label
    }

    /// Ends the lifecycle (sign-out). Operations begun under any previous label can no longer run.
    func clear() {
        lock.lock()
        current = nil
        lock.unlock()
    }

    /// Ensures a lifecycle exists without rotating an existing one. Returns the current or newly minted
    /// label. Used where the app discovers it is signed in but has no generation yet (cold start).
    @discardableResult
    func ensureLifecycle() -> String {
        lock.lock()
        if let current {
            lock.unlock()
            return current
        }
        let label = UUID().uuidString.lowercased()
        current = label
        lock.unlock()
        return label
    }
}
