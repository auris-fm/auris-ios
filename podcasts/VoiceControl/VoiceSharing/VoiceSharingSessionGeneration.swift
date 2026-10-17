import Foundation
import CryptoKit

/// In-memory lifecycle generation that owns account-scoped work.
///
/// Why this exists instead of reusing a credential value:
/// * A refresh rotates the credential WITHOUT ending the session, so "credential changed" would read a
///   routine token rotation as a logout and wrongly refuse in-flight operations.
/// * A stable user id survives sign-out followed by signing back into the SAME account, so it cannot see
///   the one transition that must invalidate an outstanding mutation.
/// * Credentials are secrets. They must never be retained inside operation bodies, queue metadata, logs or
///   diagnostics — which is what storing a raw token as an identity marker would do.
///
/// So the generation is a NON-SECRET digest of session material: it changes when the authenticated session
/// changes (sign-in, sign-out, account switch), stays stable across a refresh of the same session, and
/// carries no recoverable credential content. Nothing but the digest is kept.
final class VoiceSharingSessionGeneration {
    static let shared = VoiceSharingSessionGeneration()

    private let lock = NSLock()
    private var current: String?

    /// Inputs whose change means "different authenticated session". Values are consumed to produce a
    /// digest and are never stored or returned.
    struct SessionMaterial {
        let accountIdentifier: String
        /// Opaque per-login factor: identical for every call within one login, different after a new
        /// sign-in. Production supplies a runtime nonce; a rotating refresh token must NOT be used here,
        /// because refresh rotation is not logout.
        let loginFactor: String
    }

    init() {}

    /// The current non-secret generation label, or nil when there is no authenticated session.
    func currentGeneration() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Records session material and returns the resulting generation. Callers hold only the digest.
    @discardableResult
    func update(with material: SessionMaterial?) -> String? {
        guard let material,
              !material.accountIdentifier.isEmpty,
              !material.loginFactor.isEmpty else {
            lock.lock(); current = nil; lock.unlock()
            return nil
        }
        let digest = Self.digest(account: material.accountIdentifier, loginFactor: material.loginFactor)
        lock.lock()
        current = digest
        lock.unlock()
        return digest
    }

    /// Marks the session over (sign-out). Any operation begun under a previous generation becomes stale.
    func clear() {
        lock.lock(); current = nil; lock.unlock()
    }

    /// Stable, non-reversible label. Salted with a per-process constant so two processes that observe the
    /// same account do not share labels, and so nothing about the inputs can be recovered from the output.
    static func digest(account: String, loginFactor: String) -> String {
        let input = Data("auris-voice-sharing-session-v1|\(account)|\(loginFactor)".utf8)
        return SHA256.hash(data: input).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
