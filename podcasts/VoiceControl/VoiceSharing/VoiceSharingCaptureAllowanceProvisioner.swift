import Foundation
import PocketCastsUtils

/// The minimal CONNECTED capture entry (scope correction 2026-11-03): one real
/// allowance request whose validated response becomes the collector's admission
/// authority. Memory-only — absent a valid installed response there is no
/// authority and capture fails closed through the existing admission path.
///
/// Fail-closed doctrine: an unavailable or refused outcome installs nothing and
/// surfaces its typed cause through FileLog; an installed batch issued under a
/// different enrollment epoch never admits (the authority is rebuilt with the
/// CURRENT stamp and epoch on every read, so an epoch move or account switch
/// invalidates the installed batch without any purge choreography).
final class VoiceSharingCaptureAllowanceProvisioner {
    private let client: VoiceSharingCaptureAllowanceClient
    private let accountProvider: () -> String?
    private let enrollmentEpochProvider: () -> String?
    private let stampProvider: () -> VoiceSharingCaptureStamp?
    private let log: (String) -> Void
    /// Durable accounting. Required to decide whether a returned batch is NEW capacity or one this
    /// device already holds, which is the difference between provisioning and replaying.
    private let ledger: VoiceSharingCaptureLedger
    /// Where the CURRENT allocation request identity is persisted, per account and enrollment epoch.
    private let requestIdentityRoot: URL
    private let synchronize: (URL, Bool) throws -> Void

    private let lock = NSLock()
    private var installedResponse: VoiceSharingCaptureAllowanceResponse?
    /// The account the installed response belongs to; an account switch invalidates.
    private var installedAccount: String?

    init(client: VoiceSharingCaptureAllowanceClient,
         accountProvider: @escaping () -> String?,
         enrollmentEpochProvider: @escaping () -> String?,
         stampProvider: @escaping () -> VoiceSharingCaptureStamp?,
         ledger: VoiceSharingCaptureLedger,
         requestIdentityRoot: URL,
         synchronize: @escaping (URL, Bool) throws -> Void = { _, _ in },
         log: @escaping (String) -> Void = { FileLog.shared.addMessage("[VoiceSharing] \($0)") }) {
        self.client = client
        self.accountProvider = accountProvider
        self.enrollmentEpochProvider = enrollmentEpochProvider
        self.stampProvider = stampProvider
        self.ledger = ledger
        self.requestIdentityRoot = requestIdentityRoot
        self.synchronize = synchronize
        self.log = log
    }

    // MARK: - Persisted allocation request identity

    /// The identity of the CURRENT allocation request for this account and enrollment epoch. It is
    /// deliberately NOT one request forever: exhaustion and a server-confirmed expired window discard
    /// it. It is also deliberately not per-process: a restart must replay it.
    private func fileURL(account: String, epoch: String) -> URL {
        let digest = VoiceSharingCaptureAuthorization.digest(account + "\u{0}" + epoch)
        return requestIdentityRoot.appendingPathComponent(digest, isDirectory: false)
            .appendingPathExtension("request")
    }

    private func existingRequestID(account: String, epoch: String) -> String? {
        let url = fileURL(account: account, epoch: epoch)
        guard let data = try? Data(contentsOf: url),
              data.count <= 64,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: value) != nil else { return nil }
        return value
    }

    private func mintRequestID(account: String, epoch: String) -> String? {
        let url = fileURL(account: account, epoch: epoch)
        let value = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: requestIdentityRoot, withIntermediateDirectories: true)
            guard let data = value.data(using: .utf8) else { return nil }
            let temporary = url.appendingPathExtension("next")
            try? FileManager.default.removeItem(at: temporary)
            try data.write(to: temporary, options: .withoutOverwriting)
            try synchronize(temporary, false)
            guard rename(temporary.path, url.path) == 0 else { return nil }
            try synchronize(url.deletingLastPathComponent(), true)
        } catch {
            return nil
        }
        return value
    }

    private func discardRequestID(account: String, epoch: String) {
        try? FileManager.default.removeItem(at: fileURL(account: account, epoch: epoch))
    }

    /// Sync read for the collector's admission path (`currentAuthorization`).
    /// Rebuilt from the installed response against the CURRENT account, epoch
    /// and consent stamp — nothing stale can slip through a lifecycle move.
    func currentAuthorization() -> VoiceSharingCaptureAuthorization? {
        lock.lock()
        let response = installedResponse
        let account = installedAccount
        lock.unlock()
        guard let response, let account, accountProvider() == account,
              response.enrollmentEpoch == enrollmentEpochProvider(),
              let stamp = stampProvider() else { return nil }
        return VoiceSharingCaptureAllowanceInstallation.admissionAuthority(
            account: account, response: response, consent: stamp)
    }

    /// One real request. `issued` installs; `replayed` also admits (its ledger
    /// reopens only if intact — reviewer 80ef8b5f.5). Every other outcome is
    /// surfaced and installs nothing.
    func provision() async {
        if currentAuthorization() != nil { return } // installed — no second request
        guard let account = accountProvider(), !account.isEmpty else {
            log("capture allowance provision skipped: no account identity")
            return
        }
        guard let epoch = enrollmentEpochProvider(), !epoch.isEmpty else {
            log("capture allowance provision skipped: no enrollment epoch")
            return
        }
        // A RESTART or a freshness refresh REPLAYS this identity: the server resolves the same
        // persisted batch and charges no new capacity. Only a genuinely exhausted batch or a
        // server-confirmed expired accounting window mints a new one, and that happens by
        // discarding the identity ONLY after such a refusal — never merely because the process
        // started. Anything else would let twelve launches buy twelve batches out of one day's
        // budget, which is exactly what this device did before this fix.
        let persisted = existingRequestID(account: account, epoch: epoch)
        guard let requestID = persisted ?? mintRequestID(account: account, epoch: epoch),
              let request = VoiceSharingCaptureAllowanceRequest(requestID: requestID,
                                                               enrollmentEpoch: epoch) else {
            log("capture allowance provision skipped: invalid request inputs")
            return
        }
        let outcome = await client.perform(request)
        switch outcome {
        case .accepted(let response):
            guard let verifiedFirstProvisioning = VoiceSharingCaptureProvisioningAuthority(
                verifiedFirstProvisioningAccount: account, establishedWindow: response.windowID,
                batchId: response.batchID,
                expiredOnFreshness: response.validForMSRemaining <= 0) else {
                log("capture allowance response invalid for admission; nothing installed")
                return
            }
            guard VoiceSharingCaptureAllowanceInstallation.admissionAuthority(
                account: account, response: response,
                consent: stampProvider() ?? VoiceSharingCaptureStamp(session: nil, epoch: epoch,
                                                                     policyGeneration: 0)) != nil else {
                // A frozen request identity must not block forever: if the response cannot be
                // admitted, it will not admit on a retry either.
                discardRequestID(account: account, epoch: epoch)
                log("capture allowance response invalid for admission; nothing installed")
                return
            }
            // NEW capacity is established only when this device holds no ledger for the batch. A batch
            // this device already accounts for is ADOPTED, so its usage survives the restart; and a
            // REPLAY whose ledger is missing REFUSES rather than recreating unused capacity.
            let established: Bool
            if ledger.adoptExisting(verifiedFirstProvisioning) {
                established = true
            } else if response.disposition == .issued {
                established = ledger.provision(verifiedFirstProvisioning)
            } else {
                established = false
            }
            guard established else {
                // The batch exists on the server but this device holds no intact accounting for it.
                // Refuse, and keep the identity: a replay is exactly what must keep refusing rather
                // than ever reconstruct unused capacity.
                log("capture allowance ledger unavailable for batch \(response.batchID); nothing installed")
                return
            }
            lock.lock()
            installedResponse = response
            installedAccount = account
            lock.unlock()
            log("capture allowance installed: batch \(response.batchID) (epoch \(response.enrollmentEpoch), \(response.disposition.rawValue))")
        case .refused(let refusal):
            // Only these two outcomes justify asking for a DIFFERENT batch: the batch has no capacity
            // left, or the server says its accounting window is over. Local expiry is not one of them.
            if refusal.mintsNewAllocation {
                discardRequestID(account: account, epoch: epoch)
            }
            log("capture allowance REFUSED: \(refusal)")
        case .unavailable:
            // Unreachable server proves nothing about the batch; the identity is kept.
            log("capture allowance unavailable; nothing installed")
        }
    }
}
