import CryptoKit
import Darwin
import Foundation

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
}

struct VoiceSharingCaptureAuthorization: Equatable, VoiceSharingCaptureAccountScope {
    let accountDigest: String
    let accountBinding: String
    let window: String
    let limits: VoiceSharingCaptureLimits
    let consent: VoiceSharingCaptureStamp

    init?(account: String, establishedWindow: String?, limits: VoiceSharingCaptureLimits?, consent: VoiceSharingCaptureStamp) {
        guard !account.isEmpty, account.utf8.count <= 512,
              let establishedWindow, !establishedWindow.isEmpty, establishedWindow.utf8.count <= 512,
              let limits else { return nil }
        accountDigest = Self.digest(account)
        accountBinding = Self.digest("auris-capture-allowance-account-v1:" + account)
        window = establishedWindow
        self.limits = limits
        self.consent = consent
    }

    fileprivate static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Separate capability supplied only by trusted first-provisioning authority, never by normal admission.
/// No production issuer exists. Synthetic controls construct this explicitly to establish their fixtures.
struct VoiceSharingCaptureProvisioningAuthority: VoiceSharingCaptureAccountScope {
    let accountDigest: String
    let accountBinding: String
    let window: String

    /// Caller must have independent first-provisioning proof; a normal admission snapshot is insufficient.
    init?(verifiedFirstProvisioningAccount account: String, establishedWindow: String) {
        guard !account.isEmpty, account.utf8.count <= 512,
              !establishedWindow.isEmpty, establishedWindow.utf8.count <= 512 else { return nil }
        accountDigest = VoiceSharingCaptureAuthorization.digest(account)
        accountBinding = VoiceSharingCaptureAuthorization.digest("auris-capture-allowance-account-v1:" + account)
        window = establishedWindow
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
    private let worker = DispatchQueue(label: "fm.auris.voicesharing.capture-allowance", qos: .utility)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var preparing = false
    private var token: VoiceSharingCaptureAuthorization?

    init(ledger: VoiceSharingCaptureLedger, currentAuthorization: @escaping () -> VoiceSharingCaptureAuthorization?) {
        self.ledger = ledger
        self.currentAuthorization = currentAuthorization
    }

    func take(for stamp: VoiceSharingCaptureStamp) -> VoiceSharingCaptureReservation? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        // Authority comparison and single-use consumption are one short memory decision.
        guard let prepared = token else { return nil }
        token = nil
        guard prepared.consent == stamp, currentAuthorization() == prepared else { return nil }
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
            // Validation precedes ledger creation, lock acquisition, and every durable charge.
            let charged = authority.map { self.ledger.charge($0) } ?? false
            self.lock.lock()
            defer { self.lock.unlock() }
            self.preparing = false
            guard charged, let authority, self.generation == startedGeneration,
                  self.currentAuthorization() == authority else { return }
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
        access(authority, limits: nil)
    }

    private func access<Scope: VoiceSharingCaptureAccountScope>(_ authority: Scope, limits: VoiceSharingCaptureLimits?) -> Bool {
        guard Self.processLock.try() else { return false }
        defer { Self.processLock.unlock() }
        do { return try chargeLocked(authority, limits: limits) } catch { return false }
    }

    private func chargeLocked<Scope: VoiceSharingCaptureAccountScope>(_ authority: Scope, limits: VoiceSharingCaptureLimits?) throws -> Bool {
        let firstProvisioning = limits == nil
        let directory = root.appendingPathComponent(authority.accountDigest, isDirectory: true)
        // Ordinary admission/recovery must not mistake lost accounting for first use.
        if firstProvisioning { try createDirectoriesDurably(directory) }
        let lockURL = directory.appendingPathComponent("claim.lock")
        var created = false
        var descriptor: Int32
        if firstProvisioning {
            descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            if descriptor >= 0 { created = true }
        } else {
            descriptor = open(lockURL.path, O_RDWR | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        // Never infer initializer ownership from an earlier directory check; re-read under both locks.
        let names = try boundedNames(directory)
        let allowed: Set<String> = ["claim.lock", "genesis.json", "usage.json", "intent.json"]
        guard names.isSubset(of: allowed) else { throw Failure.unavailable }
        let genesisURL = directory.appendingPathComponent("genesis.json")
        let usageURL = directory.appendingPathComponent("usage.json")
        let intentURL = directory.appendingPathComponent("intent.json")
        let genesis: Genesis
        if created {
            guard names == ["claim.lock"] else { throw Failure.unavailable }
            try synchronize(lockURL, false)
            try synchronize(directory, true)
            try synchronize(root, true)
            try barrier(.claimDurable)
            let identity = Identity(schema: 1, account: authority.accountDigest, binding: authority.accountBinding,
                                    window: authority.window, incarnation: UUID().uuidString)
            try write(Genesis(identity: identity, established: false), to: genesisURL)
            try barrier(.genesisInitializing)
            try write(Usage(identity: identity, records: 0, bytes: 0, transaction: nil), to: usageURL)
            try barrier(.initialUsage)
            genesis = Genesis(identity: identity, established: true)
            try write(genesis, to: genesisURL)
            try barrier(.genesisEstablished)
            return true
        } else {
            genesis = try read(Genesis.self, from: genesisURL)
        }
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
        guard let limits else { throw Failure.unavailable }
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

    private static func sync(_ url: URL, _ directory: Bool) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Failure.unavailable }
    }
}
