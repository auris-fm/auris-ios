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
    /// Serializes request-identity creation; distinct from `lock`, which guards the installed response.
    private let identityLock = NSLock()
    private var installedResponse: VoiceSharingCaptureAllowanceResponse?
    /// The account the installed response belongs to; an account switch invalidates.
    private var installedAccount: String?
    /// The batch and window each persisted identity was last issued for, so exhaustion can be judged
    /// against the accounting of THAT batch rather than the newest one.
    private var issuedBatchByRequestID: [String: String] = [:]
    private var issuedWindowByRequestID: [String: String] = [:]

    init(client: VoiceSharingCaptureAllowanceClient,
         accountProvider: @escaping () -> String?,
         enrollmentEpochProvider: @escaping () -> String?,
         stampProvider: @escaping () -> VoiceSharingCaptureStamp?,
         ledger: VoiceSharingCaptureLedger,
         requestIdentityRoot: URL,
         synchronize: @escaping (URL, Bool) throws -> Void = { try VoiceSharingCaptureLedger.sync($0, $1) },
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

    /// An identity is usable only when it is both readable AND confirmed durable. A file whose
    /// directory entry was never successfully fsynced (a crash after `link`, or a failed directory
    /// sync) may not survive a restart, so sending it would take a charge the device cannot reconstruct.
    private func existingRequestID(account: String, epoch: String) -> String? {
        let url = fileURL(account: account, epoch: epoch)
        guard let data = try? Data(contentsOf: url),
              data.count <= 64,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: value) != nil else { return nil }
        // Re-confirm durability on every read, not just after creation: this is also the repair path for
        // an identity whose directory sync failed after it was linked.
        do {
            try synchronize(url, false)
            try synchronize(url.deletingLastPathComponent(), true)
        } catch {
            return nil
        }
        return value
    }

    /// The single serialized identity decision: keep, advance, or mint. Returns the identity this device
    /// will send, and the result is durable BEFORE the request leaves — a crash after the server charged
    /// the request must never lose the identity that charge belongs to.
    ///
    /// Advancing happens here and only here: the current identity is replaced by a NEW one exactly when
    /// its own batch is proven exhausted in the durable ledger. Everything is decided against the
    /// expected current identity under one lock, so two overlapping provisions cannot each advance and
    /// each charge a batch.
    private func nextRequestIDForSending(account: String, epoch: String) -> String? {
        identityLock.lock()
        defer { identityLock.unlock() }
        if let existing = existingRequestID(account: account, epoch: epoch) {
            guard let consumed = consumedBatch(forRequestID: existing, account: account, epoch: epoch)
            else { return existing } // no proof of exhaustion: replay this identity
            log("capture allowance batch \(consumed) is exhausted in the durable ledger; advancing")
            discardRequestIDLocked(account: account, epoch: epoch)
            clearInstallation()
        }
        let url = fileURL(account: account, epoch: epoch)
        let value = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: requestIdentityRoot, withIntermediateDirectories: true)
            try synchronize(requestIdentityRoot, true)
            guard let data = value.data(using: .utf8) else { return nil }
            let temporary = url.appendingPathExtension("next")
            // A leftover temporary file is uncertainty evidence, never silently replaced.
            try data.write(to: temporary, options: .withoutOverwriting)
            try synchronize(temporary, false)
            // `link` fails with EEXIST rather than replacing: an identity that another writer already
            // installed WINS, and it is the one we then send.
            guard link(temporary.path, url.path) == 0 || errno == EEXIST else { return nil }
            try? FileManager.default.removeItem(at: temporary)
            try synchronize(requestIdentityRoot, true)
            // The exclusive link happened; confirm it is durable before this identity may be sent.
            try synchronize(url, false)
        } catch {
            return nil
        }
        return existingRequestID(account: account, epoch: epoch)
    }

    /// The batch the given identity was last issued for, when its durable accounting is intact AND
    /// fully consumed. Nil in every other case, including "unknown", so nothing is minted on doubt.
    ///
    /// The binding is read from DISK: a fresh process has no in-memory map, and the proof has to survive
    /// a restart — otherwise proven exhaustion before a restart would be forgotten and the client would
    /// stay capped at one batch per process lifetime.
    private func consumedBatch(forRequestID requestID: String, account: String, epoch: String) -> String? {
        guard let binding = existingBinding(account: account, epoch: epoch), binding.requestID == requestID
        else { return nil }
        lock.lock()
        let batch = issuedBatchByRequestID[requestID] ?? binding.batchID
        let window = issuedWindowByRequestID[requestID] ?? binding.windowID
        lock.unlock()
        guard let authority = VoiceSharingCaptureProvisioningAuthority(
            verifiedFirstProvisioningAccount: account, establishedWindow: window, batchId: batch),
            binding.maxRecords > 0, binding.maxBytes > 0 else { return nil }
        let caps = VoiceSharingCaptureLedger.BatchCaps(records: binding.maxRecords, bytes: binding.maxBytes)
        return ledger.isExhausted(authority, caps: caps) ? batch : nil
    }

    /// True when the batch behind the installed authority has no capacity left in the durable ledger.
    private func installedBatchIsExhausted() -> Bool {
        guard let authorization = currentAuthorization(),
              let binding = existingBinding(account: authorizationAccount() ?? "",
                                            epoch: authorization.consent.epoch),
              binding.batchID == authorization.batchId else { return false }
        let caps = VoiceSharingCaptureLedger.BatchCaps(records: binding.maxRecords, bytes: binding.maxBytes)
        let authority = VoiceSharingCaptureProvisioningAuthority(
            verifiedFirstProvisioningAccount: authorizationAccount() ?? "",
            establishedWindow: binding.windowID, batchId: authorization.batchId)
        guard let authority else { return false }
        return ledger.isExhausted(authority, caps: caps)
    }

    private func authorizationAccount() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return installedAccount
    }

    private func clearInstallation() {
        lock.lock()
        installedResponse = nil
        installedAccount = nil
        lock.unlock()
    }

    /// Drop an installed response that no longer produces an authority (account/epoch/policy moved).
    private func clearStaleInstallation() {
        lock.lock()
        let installed = installedResponse
        lock.unlock()
        guard installed != nil else { return }
        clearInstallation()
    }

    /// The durable record of what the current identity was issued for.
    private struct Binding: Codable {
        let requestID: String
        let batchID: String
        let windowID: String
        /// The caps THIS batch was issued with. Exhaustion is judged against them, not the compiled
        /// ceiling: a batch the server capped lower is spent sooner, and treating it as unspent would
        /// leave the client asking to replay a batch it cannot use.
        let maxRecords: UInt64
        let maxBytes: UInt64

        init(requestID: String, batchID: String, windowID: String, maxRecords: UInt64 = 0,
             maxBytes: UInt64 = 0) {
            self.requestID = requestID
            self.batchID = batchID
            self.windowID = windowID
            self.maxRecords = maxRecords
            self.maxBytes = maxBytes
        }

        init(from decoder: Decoder) throws {
            // A binding written before caps were recorded carries zeros: that is "unknown", and an
            // unknown cap must not authorize a mint.
            let container = try decoder.container(keyedBy: CodingKeys.self)
            requestID = try container.decode(String.self, forKey: .requestID)
            batchID = try container.decode(String.self, forKey: .batchID)
            windowID = try container.decode(String.self, forKey: .windowID)
            maxRecords = try container.decodeIfPresent(UInt64.self, forKey: .maxRecords) ?? 0
            maxBytes = try container.decodeIfPresent(UInt64.self, forKey: .maxBytes) ?? 0
        }
    }

    private func bindingURL(account: String, epoch: String) -> URL {
        fileURL(account: account, epoch: epoch).appendingPathExtension("binding")
    }

    private func existingBinding(account: String, epoch: String) -> Binding? {
        guard let data = try? Data(contentsOf: bindingURL(account: account, epoch: epoch)),
              data.count <= 512 else { return nil }
        return try? JSONDecoder().decode(Binding.self, from: data)
    }

    /// Records which batch an identity resolved to, durably, so a later process can judge that batch's
    /// exhaustion from the ledger alone.
    private func recordBinding(requestID: String, batchID: String, windowID: String,
                               maxRecords: UInt64, maxBytes: UInt64,
                               account: String, epoch: String) {
        guard let data = try? JSONEncoder().encode(
            Binding(requestID: requestID, batchID: batchID, windowID: windowID,
                    maxRecords: maxRecords, maxBytes: maxBytes)) else { return }
        let url = bindingURL(account: account, epoch: epoch)
        let temporary = url.appendingPathExtension("next")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try synchronize(temporary, false)
            guard rename(temporary.path, url.path) == 0 else { return }
            try synchronize(url.deletingLastPathComponent(), true)
        } catch {
            // A binding that cannot be persisted only costs a replayed request later; it never grants
            // capacity, so it is not an admission decision.
        }
    }

    private func discardRequestID(account: String, epoch: String) {
        identityLock.lock()
        defer { identityLock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(account: account, epoch: epoch))
        try? FileManager.default.removeItem(at: bindingURL(account: account, epoch: epoch))
    }

    /// Discards only when the persisted identity is still the one the response answered. A stale
    /// response for a superseded identity is ignored: something newer already decided this account's
    /// identity, and the server's verdict on the old request no longer describes what is on disk.
    private func discardRequestID(ifCurrent requestID: String, account: String, epoch: String) {
        identityLock.lock()
        defer { identityLock.unlock() }
        guard existingRequestID(account: account, epoch: epoch) == requestID else {
            log("capture allowance: ignoring a verdict for a superseded request identity")
            return
        }
        discardRequestIDLocked(account: account, epoch: epoch)
    }

    /// A verdict for a SUPERSEDED accounting window answers a question nobody is waiting on any more.
    /// Whatever is installed now belongs to a newer window, so the old verdict must not clear it.
    private func clearSupersededInstallation(epoch: String) {
        lock.lock()
        let installedEpoch = installedResponse?.enrollmentEpoch
        lock.unlock()
        guard installedEpoch == nil || installedEpoch == epoch else { return }
        clearInstallation()
    }

    private func discardRequestIDLocked(account: String, epoch: String) {
        try? FileManager.default.removeItem(at: fileURL(account: account, epoch: epoch))
        try? FileManager.default.removeItem(at: bindingURL(account: account, epoch: epoch))
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
        // An installed authority with capacity left means there is nothing to do. An installed verdict
        // whose batch is EXHAUSTED does not: the client must be able to advance to the next batch within
        // the same process, not only after a restart.
        if currentAuthorization() != nil, !installedBatchIsExhausted() { return }
        if currentAuthorization() == nil { clearStaleInstallation() }
        guard let account = accountProvider(), !account.isEmpty else {
            log("capture allowance provision skipped: no account identity")
            return
        }
        guard let epoch = enrollmentEpochProvider(), !epoch.isEmpty else {
            log("capture allowance provision skipped: no enrollment epoch")
            return
        }
        // A RESTART or a freshness refresh REPLAYS this identity: the server resolves the same
        // persisted batch and charges no new capacity. Only the server's own confirmation that the
        // accounting window is over (410) mints a new one — never merely because the process started,
        // and never because of a local admission or transport failure. Anything else would let twelve
        // launches buy twelve batches out of one day's budget, which is exactly what this device did
        // before this fix.
        // ONE serialized decision: read the current identity, prove (or fail to prove) that its batch is
        // exhausted, and persist the replacement under the same lock. Split across lock boundaries, two
        // concurrent calls both observe the old batch and the later discard removes the identity the
        // first call just created — minting a second batch for one exhaustion event.
        guard let requestID = nextRequestIDForSending(account: account, epoch: epoch),
              let request = VoiceSharingCaptureAllowanceRequest(requestID: requestID,
                                                               enrollmentEpoch: epoch) else {
            log("capture allowance provision skipped: invalid request inputs")
            return
        }
        let outcome = await client.perform(request)
        // The window this response ANSWERS, which for a refusal is the one the request was sent under.
        let answeredEpoch = epoch
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
                // Local admission failed — a changed session or policy generation, or a response that
                // arrived under an old consent stamp. That says nothing about the batch, which the
                // server has already allocated and charged to this day's budget. Discarding the
                // identity here would abandon that allocation and charge a SECOND batch on the next
                // attempt, so the identity is kept and the refresh simply retries it.
                log("capture allowance response not admissible under current consent; nothing installed, identity kept")
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
            issuedBatchByRequestID[requestID] = response.batchID
            issuedWindowByRequestID[requestID] = response.windowID
            lock.unlock()
            recordBinding(requestID: requestID, batchID: response.batchID, windowID: response.windowID,
                          maxRecords: UInt64(response.batchMaxRecords),
                          maxBytes: UInt64(response.batchMaxBytes),
                          account: account, epoch: epoch)
            log("capture allowance installed: batch \(response.batchID) (epoch \(response.enrollmentEpoch), \(response.disposition.rawValue))")
        case .refused(let refusal):
            // Only these two outcomes justify asking for a DIFFERENT batch: the batch has no capacity
            // left, or the server says its accounting window is over. Local expiry is not one of them.
            // The discard is checked against the identity THIS response answered, under the identity
            // lock. A delayed `410` for a request sent before a replacement was minted must not delete
            // that replacement: two outstanding requests can both answer 410 around one advance, and an
            // unconditional discard would delete the ID the advance just created and mint a third.
            if refusal.mintsNewAllocation {
                discardRequestID(ifCurrent: requestID, account: account, epoch: epoch)
            }
            // A 503 says the SERVER failed, not that this device's identity or installation is wrong.
            // Keeping the existing installation matters as much as keeping the identity: a transient
            // outage during a refresh must not revoke the batch the device already holds, or a working
            // capture would be shut off by someone else's incident.
            if refusal == .serverUnavailable {
                log("capture allowance: server unavailable; keeping the current identity and installation")
                return
            }
            clearSupersededInstallation(epoch: answeredEpoch)
            log("capture allowance REFUSED: \(refusal)")
        case .unavailable:
            // Unreachable server proves nothing about the batch; the identity is kept.
            log("capture allowance unavailable; nothing installed")
        }
    }
}
