import CryptoKit
import Darwin
import Foundation
import PocketCastsUtils

/// Capture admission only. These are not transferred-byte counters or a replacement for server quotas.
struct VoiceSharingCaptureLimits: Equatable {
    let dailyRecords: UInt64
    let dailyBytes: UInt64
    let clipSamples: Int
    let metadataBytes: Int
    let reservationBytes: UInt64

    init?(dailyRecords: UInt64, dailyBytes: UInt64,
          compiledRecordsCeiling: UInt64?, compiledBytesCeiling: UInt64?,
          clipSamples: Int, metadataBytes: Int, compiledClipSamples: Int, compiledMetadataBytes: Int) {
        guard let compiledRecordsCeiling, let compiledBytesCeiling,
              dailyRecords > 0, dailyRecords <= compiledRecordsCeiling,
              dailyBytes > 0, dailyBytes <= compiledBytesCeiling,
              clipSamples > 0, clipSamples <= compiledClipSamples,
              metadataBytes > 0, metadataBytes <= compiledMetadataBytes else { return nil }
        let (audio, audioOverflow) = UInt64(clipSamples).multipliedReportingOverflow(by: 2)
        let (wav, wavOverflow) = audio.addingReportingOverflow(44)
        let (reservation, reservationOverflow) = wav.addingReportingOverflow(UInt64(metadataBytes))
        guard !audioOverflow, !wavOverflow, !reservationOverflow, reservation <= dailyBytes else { return nil }
        self.dailyRecords = dailyRecords
        self.dailyBytes = dailyBytes
        self.clipSamples = clipSamples
        self.metadataBytes = metadataBytes
        reservationBytes = reservation
    }
}

struct VoiceSharingCaptureStamp: Equatable {
    let session: String?
    let epoch: String
    let policyGeneration: Int
}

/// Construct off the callback from an established authority. There is no production window source yet.
protocol VoiceSharingCaptureAccountScope {
    var accountDigest: String { get }
    var accountBinding: String { get }
    var window: String { get }
    /// Per-batch durable accounting identity (spec: persist consumption per account AND batch).
    var batchId: String { get }
}

struct VoiceSharingCaptureAuthorization: Equatable, VoiceSharingCaptureAccountScope {
    let accountDigest: String
    let accountBinding: String
    let window: String
    let batchId: String
    let limits: VoiceSharingCaptureLimits
    let consent: VoiceSharingCaptureStamp
    /// Monotonic instant this batch stops admitting: the ORIGINAL request start plus the server's
    /// `valid_for_ms`. Carried into admission because the policy lease is an INDEPENDENT lifetime —
    /// a short allowance under a live lease stayed usable past its own deadline when nothing but a
    /// timer watched expiry (reviewer on the dependency set), and capture must refuse at that
    /// boundary without relying on a timer having fired.
    let deadlineMonotonicMS: Int

    init?(account: String, establishedWindow: String?, batchId: String?, limits: VoiceSharingCaptureLimits?, consent: VoiceSharingCaptureStamp,
          deadlineMonotonicMS: Int = Int.max) {
        guard !account.isEmpty, account.utf8.count <= 512,
              let establishedWindow, !establishedWindow.isEmpty, establishedWindow.utf8.count <= 512,
              let batchId, Self.isValidBatchId(batchId),
              let limits else { return nil }
        accountDigest = Self.digest(account)
        accountBinding = Self.digest("auris-capture-allowance-account-v1:" + account)
        window = establishedWindow
        self.batchId = batchId
        self.limits = limits
        self.consent = consent
        self.deadlineMonotonicMS = deadlineMonotonicMS
    }

    /// Admission lifetime check. `now` is monotonic; a monotonic clock that moved BACKWARD reads as
    /// elapsed (fail closed) rather than granting a fresh interval.
    func isLive(atMonotonicMS now: Int) -> Bool { now < deadlineMonotonicMS }

    /// Opaque server-issued UUIDs only — never a caller-chosen label.
    static func isValidBatchId(_ value: String) -> Bool { UUID(uuidString: value) != nil }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Separate capability supplied only by trusted first-provisioning authority, never by normal admission.
/// No production issuer exists. Synthetic controls construct this explicitly to establish their fixtures.
struct VoiceSharingCaptureProvisioningAuthority: VoiceSharingCaptureAccountScope {
    let accountDigest: String
    let accountBinding: String
    let window: String
    let batchId: String

    /// Set only when the server's own freshness interval for THIS batch has already elapsed. It is the
    /// sole condition under which an existing zero-usage ledger may be re-established instead of
    /// adopted: expiry is not permission, so re-establishing grants no capacity the batch did not
    /// have, while adoption would keep charging captures to a batch the server no longer honours.
    let expiredOnFreshness: Bool

    /// Caller must have independent first-provisioning proof; a normal admission snapshot is insufficient.
    init?(verifiedFirstProvisioningAccount account: String, establishedWindow: String, batchId: String,
          expiredOnFreshness: Bool = false) {
        guard !account.isEmpty, account.utf8.count <= 512,
              !establishedWindow.isEmpty, establishedWindow.utf8.count <= 512,
              VoiceSharingCaptureAuthorization.isValidBatchId(batchId) else { return nil }
        self.expiredOnFreshness = expiredOnFreshness
        accountDigest = VoiceSharingCaptureAuthorization.digest(account)
        accountBinding = VoiceSharingCaptureAuthorization.digest("auris-capture-allowance-account-v1:" + account)
        window = establishedWindow
        self.batchId = batchId
    }
}

struct VoiceSharingCaptureReservation {
    let clipSamples: Int
    let metadataBytes: Int
}

protocol VoiceSharingCaptureAdmitting: AnyObject {
    /// Memory-only and nonwaiting; no PCM may be retained until this succeeds.
    func take(for stamp: VoiceSharingCaptureStamp) -> VoiceSharingCaptureReservation?
    func requestPreparation()
    func invalidate()
}

/// One prepaid token and one worker, not a pool. No collector lock is held by the storage path.
final class VoiceSharingCaptureAllowance: VoiceSharingCaptureAdmitting {
    private let ledger: VoiceSharingCaptureLedger
    /// Memory-only current authority. Missing production values/window return nil before storage work.
    private let currentAuthorization: () -> VoiceSharingCaptureAuthorization?
    /// Told when a charge is refused for lack of capacity. Consumption happens between policy exchanges,
    /// so this is the only way capture keeps going without waiting for a lease turnover.
    private let capacityExhausted: () -> Void
    private let worker = DispatchQueue(label: "fm.auris.voicesharing.capture-allowance", qos: .utility)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var preparing = false
    private var token: VoiceSharingCaptureAuthorization?

    /// Monotonic milliseconds, injectable so a control can step past a deadline without waiting.
    private let monotonicNowMS: () -> Int

    init(ledger: VoiceSharingCaptureLedger,
         currentAuthorization: @escaping () -> VoiceSharingCaptureAuthorization?,
         capacityExhausted: @escaping () -> Void = {},
         monotonicNowMS: @escaping () -> Int = { Int(ProcessInfo.processInfo.systemUptime * 1000) }) {
        self.ledger = ledger
        self.currentAuthorization = currentAuthorization
        self.capacityExhausted = capacityExhausted
        self.monotonicNowMS = monotonicNowMS
    }

    func take(for stamp: VoiceSharingCaptureStamp) -> VoiceSharingCaptureReservation? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        // Authority comparison and single-use consumption are one short memory decision.
        guard let prepared = token else { return nil }
        token = nil
        // A batch past its own allowance deadline never admits, even while policy is still live and
        // even though the installed authority compares equal (it is the SAME batch).
        let live = prepared.isLive(atMonotonicMS: monotonicNowMS())
        guard live, prepared.consent == stamp, currentAuthorization() == prepared else {
            // An EXPIRED authority that still matched everything else is not a spent batch: it is an
            // allowance that ran out, and only the producer can replace it. Refusing without waking it
            // would leave capture closed until the next policy exchange.
            if !live { capacityExhausted() }
            return nil
        }
        return .init(clipSamples: prepared.limits.clipSamples, metadataBytes: prepared.limits.metadataBytes)
    }

    func requestPreparation() {
        guard lock.try() else { return }
        guard !preparing, token == nil else { lock.unlock(); return }
        preparing = true
        let startedGeneration = generation
        lock.unlock()
        worker.async { [weak self] in
            guard let self else { return }
            let authority = self.currentAuthorization()
            // ONE rule: no ledger capacity is consumed by an admission that could not have been
            // granted. An installed authority past its own allowance deadline is exactly that case —
            // it would charge the batch and then refuse at `take`, silently burning capacity. So the
            // lifetime check comes before the durable charge, and an expired allowance is a request
            // for another allocation like any other refusal: the producer is woken, and the resulting
            // refresh REUSES the persisted request identity, so the replay costs no new batch.
            let live = authority.map { $0.isLive(atMonotonicMS: self.monotonicNowMS()) } ?? false
            if !live {
                // No installed authority, or one whose allowance interval has ended: capture is
                // refused, and the producer is the only thing that can change that. Without this, an
                // expired allowance waits for the next policy exchange — potentially hours — before it
                // can be refreshed.
                self.capacityExhausted()
            }
            // Validation precedes ledger creation, lock acquisition, and every durable charge.
            let charged = live ? (authority.map { self.ledger.charge($0) } ?? false) : false
            self.lock.lock()
            defer { self.lock.unlock() }
            self.preparing = false
            guard charged, let authority, self.generation == startedGeneration,
                  self.currentAuthorization() == authority else {
                // Any refusal while an authority is EXPECTED is a request for another allocation: the
                // batch is spent, or there is no installed authority at all (expired, never installed,
                // or not yet fetched). Capture stays refused either way — only the producer is woken.
                self.lock.unlock()
                self.capacityExhausted()
                self.lock.lock()
                return
            }
            self.token = authority
        }
    }

    func invalidate() {
        lock.lock()
        generation &+= 1
        token = nil
        lock.unlock()
    }

    /// Joins only the worker, for deterministic controls; never called by admission/capture.
    func waitForPreparationForTesting() { worker.sync {} }
}

/// A bounded, content-free ledger outside purgeable contribution content. No rollover is implemented.
final class VoiceSharingCaptureLedger {
    enum Barrier: String {
        case claimDurable, genesisInitializing, initialUsage, genesisEstablished
        case intentDurable, usageRenamed, usageDurable, intentSettled
    }

    private struct Envelope<Value: Codable>: Codable {
        let payload: Value
        let sha256: String
    }

    private struct Identity: Codable, Equatable {
        let schema: Int
        let account: String
        let binding: String
        let window: String
        let incarnation: String
    }

    private struct Genesis: Codable {
        let identity: Identity
        let established: Bool
    }

    private struct Usage: Codable, Equatable {
        let identity: Identity
        let records: UInt64
        let bytes: UInt64
        let transaction: String?
    }

    private struct Intent: Codable {
        let transaction: String
        let before: Usage
        let target: Usage
    }

    private enum Failure: Error { case unavailable }
    /// One bounded process-wide exclusion also covers separate opens/instances; flock adds process isolation.
    private static let processLock = NSLock()

    /// What this batch was issued with. A response may lower the compiled ceiling, never raise it, so
    /// exhaustion is judged against the batch's OWN caps — a batch capped lower is spent sooner, and
    /// judging it against the compiled ceiling would leave the client replaying a batch it cannot use.
    struct BatchCaps: Equatable {
        let records: UInt64
        let bytes: UInt64
    }
    private static let maximumDocumentBytes = 8 * 1024
    private let root: URL
    private let synchronize: (URL, Bool) throws -> Void
    private let barrier: (Barrier) throws -> Void

    init(root: URL, synchronize: @escaping (URL, Bool) throws -> Void = VoiceSharingCaptureLedger.sync,
         barrier: @escaping (Barrier) throws -> Void = { _ in }) {
        self.root = root
        self.synchronize = synchronize
        self.barrier = barrier
    }

    func charge(_ authority: VoiceSharingCaptureAuthorization) -> Bool {
        access(authority, limits: authority.limits)
    }

    /// Initializes zero accounting only; never charges or issues a capture reservation.
    func provision(_ authority: VoiceSharingCaptureProvisioningAuthority) -> Bool {
        access(authority, limits: nil, createIfMissing: true,
               expiredOnFreshness: authority.expiredOnFreshness)
    }

    /// A batch about to be installed that already has durable accounting takes that accounting over
    /// instead of being charged as new capacity. Returns false when this batch has no ledger at all —
    /// the caller must then establish one explicitly, because a REPLAY of a batch whose accounting was
    /// lost must refuse rather than fabricate a full fresh allowance.
    func adoptExisting(_ authority: VoiceSharingCaptureProvisioningAuthority) -> Bool {
        let directory = root.appendingPathComponent(authority.accountDigest, isDirectory: true)
            .appendingPathComponent(authority.batchId, isDirectory: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        // `limits == nil` re-opens the ledger, settling any interrupted transaction and confirming its
        // identity, without adding a record. `access` owns the process lock; taking it here as well
        // would make every adoption fail against its own lock.
        return access(authority, limits: nil)
    }

    /// True only when this device's durable accounting for the batch is intact and fully consumed.
    /// This is the client-side proof of exhaustion the allocation rules require before asking the
    /// server for another batch: the server keeps no per-batch usage record, so a replayed `200` shows
    /// the same caps however much of the batch was spent, and only this ledger can prove the batch is
    /// used up. Any doubt — no ledger, corrupt accounting, an interrupted transaction — answers false,
    /// because minting on doubt reserves capacity that is never used.
    func isExhausted(_ authority: VoiceSharingCaptureProvisioningAuthority, caps: BatchCaps) -> Bool {
        guard Self.processLock.try() else { return false }
        defer { Self.processLock.unlock() }
        let directory = root.appendingPathComponent(authority.accountDigest, isDirectory: true)
            .appendingPathComponent(authority.batchId, isDirectory: true)
        // An `intent.json` means a charge is still in flight: its outcome is unproven, so nothing is
        // proven exhausted either. A SETTLED usage legitimately keeps the last transaction id, so the
        // usage field is not evidence of an interruption — only the intent file is.
        guard let names = try? boundedNames(directory), !names.contains("intent.json") else { return false }
        let allowed: Set<String> = ["init.lock", "claim.lock", "genesis.json", "usage.json"]
        guard names.isSubset(of: allowed), names.contains("usage.json"), names.contains("genesis.json"),
              let genesis = try? read(Genesis.self, from: directory.appendingPathComponent("genesis.json")),
              let usage = try? read(Usage.self, from: directory.appendingPathComponent("usage.json")),
              genesis.established, matches(genesis.identity, authority), usage.identity == genesis.identity,
              usage.records > 0 else { return false }
        guard caps.records > 0, caps.bytes > 0 else { return false }
        return usage.records >= caps.records || usage.bytes >= caps.bytes
    }

    private func access<Scope: VoiceSharingCaptureAccountScope>(
        _ authority: Scope, limits: VoiceSharingCaptureLimits?, createIfMissing: Bool = false,
        expiredOnFreshness: Bool = false
    ) -> Bool {
        guard Self.processLock.try() else { return false }
        defer { Self.processLock.unlock() }
        do {
            return try chargeLocked(authority, limits: limits, createIfMissing: createIfMissing,
                                    expiredOnFreshness: expiredOnFreshness)
        } catch { return false }
    }

    private func chargeLocked<Scope: VoiceSharingCaptureAccountScope>(
        _ authority: Scope, limits: VoiceSharingCaptureLimits?, createIfMissing: Bool = false,
        expiredOnFreshness: Bool = false
    ) throws -> Bool {
        let firstProvisioning = limits == nil

        // Consumption is persisted PER account and batch (spec): distinct directory per batch so a
        // refreshed batch reopens its own ledger and a different batch can never reuse its usage.
        let directory = root.appendingPathComponent(authority.accountDigest, isDirectory: true)
            .appendingPathComponent(authority.batchId, isDirectory: true)
        // Ordinary admission/recovery must not mistake lost accounting for first use; only an explicit
        // provisioning call may create the batch's directory, and it may establish accounting only for
        // a batch that has none (a touched or ambiguous ledger is never re-established).
        if createIfMissing { try createDirectoriesDurably(directory) }

        let lockURL = directory.appendingPathComponent("claim.lock")
        var descriptor: Int32
        if createIfMissing {
            descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        } else {
            descriptor = open(lockURL.path, O_RDWR | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        // The lock FILE may pre-exist on a restart: O_CREAT above opens it either way.
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        // Never infer initializer ownership from an earlier directory check; re-read under both locks.
        let names = try boundedNames(directory)
        let allowed: Set<String> = ["init.lock", "claim.lock", "genesis.json", "usage.json", "intent.json"]
        guard names.isSubset(of: allowed) else { throw Failure.unavailable }
        let genesisURL = directory.appendingPathComponent("genesis.json")
        let usageURL = directory.appendingPathComponent("usage.json")
        let intentURL = directory.appendingPathComponent("intent.json")
        var existing: Genesis?
        var establish = false
        if createIfMissing {
            // Ownership is a property of TAKING the start lock, never of the directory listing: the
            // claim lock always exists here (just created, or already present on a restart), so the
            // listing cannot distinguish a fresh ledger from a restart over a committed one.
            let initURL = directory.appendingPathComponent("init.lock")
            let initializer = open(initURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            // `access` cannot classify "no ledger yet" as anything but failure, so a genuinely NEW
            // batch's zero-usage ledger is established here rather than reported as lost accounting.
            // A ledger that has been touched (or is ambiguous) is not re-established.
            if initializer >= 0 {
                close(initializer)
                guard names == ["claim.lock"] else { throw Failure.unavailable }
                establish = true
            } else if errno == EEXIST, names.contains("genesis.json") {
                let current = try read(Genesis.self, from: genesisURL)
                existing = current
                establish = try isUntouched(genesis: current, usage: try read(Usage.self, from: usageURL),
                                            names: names, authority: authority)
            } else {
                throw Failure.unavailable
            }
        }
        if establish {
            if let prior = existing {
                // Re-establishing an UNTOUCHED ledger (zero records, zero bytes, no interrupted
                // transaction) is safe because it grants no capacity the batch did not already hold.
                // Any consumed or ambiguous state refuses: missing or corrupt accounting must never
                // reconstruct unused capacity.
                try write(Genesis(identity: prior.identity, established: false), to: genesisURL)
                try barrier(.genesisInitializing)
            }
            try synchronize(lockURL, false)
            try synchronize(directory, true)
            try synchronize(root, true)
            try barrier(.claimDurable)
            let identity: Identity
            if let existing {
                identity = existing.identity
            } else {
                identity = Identity(schema: 1, account: authority.accountDigest, binding: authority.accountBinding,
                                    window: authority.window, incarnation: UUID().uuidString)
            }
            try write(Genesis(identity: identity, established: false), to: genesisURL)
            try barrier(.genesisInitializing)
            try write(Usage(identity: identity, records: 0, bytes: 0, transaction: nil), to: usageURL)
            try barrier(.initialUsage)
            let established = Genesis(identity: identity, established: true)
            try write(established, to: genesisURL)
            try barrier(.genesisEstablished)
            return true
        }
        let genesis = try read(Genesis.self, from: genesisURL)
        guard genesis.established, matches(genesis.identity, authority) else { throw Failure.unavailable }
        var usage = try read(Usage.self, from: usageURL)
        guard usage.identity == genesis.identity else { throw Failure.unavailable }
        if names.contains("intent.json") {
            let intent = try read(Intent.self, from: intentURL)
            let (nextRecords, overflow) = intent.before.records.addingReportingOverflow(1)
            guard !overflow, intent.before.identity == genesis.identity,
                  intent.target.identity == genesis.identity,
                  UUID(uuidString: intent.transaction) != nil,
                  intent.target.transaction == intent.transaction,
                  intent.target.records == nextRecords, intent.target.bytes > intent.before.bytes,
                  usage == intent.before || usage == intent.target else { throw Failure.unavailable }
            // Conservatively retain the full old charge, even when no old token was issued.
            // Recovery must confirm durability before settling; it never grants that process's token.
            try write(intent.target, to: usageURL)
            try removeIntent(intentURL, directory: directory)
            usage = intent.target
        }
        // A recovery/refresh opener names no limits: it reopens the batch's accounting (settling any
        // interrupted transaction) and consumes nothing.
        guard let limits else { return true }
        let (records, recordOverflow) = usage.records.addingReportingOverflow(1)
        let (bytes, byteOverflow) = usage.bytes.addingReportingOverflow(limits.reservationBytes)
        guard !recordOverflow, !byteOverflow,
              records <= limits.dailyRecords, bytes <= limits.dailyBytes else { return false }
        let transaction = UUID().uuidString
        let target = Usage(identity: genesis.identity, records: records, bytes: bytes, transaction: transaction)
        try write(Intent(transaction: transaction, before: usage, target: target), to: intentURL)
        try barrier(.intentDurable)
        try write(target, to: usageURL, afterRename: { try self.barrier(.usageRenamed) })
        try barrier(.usageDurable)
        try removeIntent(intentURL, directory: directory)
        try barrier(.intentSettled)
        return true
    }

    /// True only for a ledger with this authority's identity and NO consumed capacity and no
    /// interrupted transaction. Anything else is uncertainty, which refuses.
    private func isUntouched<Scope: VoiceSharingCaptureAccountScope>(
        genesis: Genesis, usage: Usage, names: Set<String>, authority: Scope) throws -> Bool {
        guard genesis.established, matches(genesis.identity, authority),
              usage.identity == genesis.identity,
              usage.records == 0, usage.bytes == 0, usage.transaction == nil,
              !names.contains("intent.json") else { return false }
        let allowed: Set<String> = ["init.lock", "claim.lock", "genesis.json", "usage.json"]
        return names.isSubset(of: allowed)
    }

    /// Batch binding is enforced by AREA: the distinct batch directory scopes the whole ledger,
    /// so the persisted identity itself needs no batch field — the format is byte-compatible
    /// with the pre-batch ledger.
    private func matches<Scope: VoiceSharingCaptureAccountScope>(_ identity: Identity, _ authority: Scope) -> Bool {
        identity.schema == 1 && identity.account == authority.accountDigest && identity.binding == authority.accountBinding
            && identity.window == authority.window && UUID(uuidString: identity.incarnation) != nil
    }

    private func createDirectoriesDurably(_ directory: URL) throws {
        var missing: [URL] = []
        var cursor = directory
        while true {
            var info = stat()
            if lstat(cursor.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unavailable }
                break
            }
            guard errno == ENOENT, cursor.path != "/" else { throw Failure.unavailable }
            missing.append(cursor)
            cursor.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for created in missing.reversed() {
            var info = stat()
            guard lstat(created.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unavailable }
            try synchronize(created, true)
            try synchronize(created.deletingLastPathComponent(), true)
        }
    }

    private func boundedNames(_ directory: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { throw Failure.unavailable }
        var names = Set<String>()
        while let name = enumerator.nextObject() as? String {
            guard names.count < 4 else { throw Failure.unavailable }
            names.insert(name)
        }
        return names
    }

    private func read<Value: Codable>(_ type: Value.Type, from url: URL) throws -> Value {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.unavailable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= Self.maximumDocumentBytes,
              let data = try file.read(upToCount: Self.maximumDocumentBytes + 1),
              data.count <= Self.maximumDocumentBytes else { throw Failure.unavailable }
        let envelope = try JSONDecoder().decode(Envelope<Value>.self, from: data)
        let payload = try canonical(envelope.payload)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        // Checksum catches numeric/string corruption too; exact own encoding rejects duplicate/extra keys.
        guard digest == envelope.sha256, try canonical(envelope) == data else { throw Failure.unavailable }
        return envelope.payload
    }

    private func encode<Value: Codable>(_ value: Value) throws -> Data {
        let payload = try canonical(value)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return try canonical(Envelope(payload: value, sha256: digest))
    }

    private func canonical<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumDocumentBytes else { throw Failure.unavailable }
        return data
    }

    private func write<Value: Codable>(_ value: Value, to destination: URL, afterRename: () throws -> Void = {}) throws {
        let temporary = destination.appendingPathExtension("next")
        let data = try encode(value)
        // A leftover temporary file is uncertainty evidence, never overwritten on a fresh attempt.
        try data.write(to: temporary, options: .withoutOverwriting)
        try synchronize(temporary, false)
        guard rename(temporary.path, destination.path) == 0 else { throw Failure.unavailable }
        try afterRename()
        try synchronize(destination, false)
        try synchronize(destination.deletingLastPathComponent(), true)
    }

    private func removeIntent(_ url: URL, directory: URL) throws {
        try FileManager.default.removeItem(at: url)
        try synchronize(directory, true)
    }

    /// Durable synchronization of a file or a directory entry. Shared with the allocation request
    /// identity so both are written with the same guarantee: a crash after the server charged us must
    /// never lose the identity that charge belongs to.
    static func sync(_ url: URL, _ directory: Bool) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Failure.unavailable }
    }
}
