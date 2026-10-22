import CryptoKit
import Foundation

/// Durable upload queue persistence (spec §Client queue and scheduling, docs commit 270dfa5 lineage).
///
/// Round-23 hardening after reviewer 97166adb on 21df32a45 — the four properties pinned by
/// VoiceSharingUploadQueueTests:
///
///   * **Complete-entry validation.** Marker presence alone is NOT readiness. A ready entry is a
///     directory holding regular, non-empty `metadata.json` and `audio.wav` plus `ready.marker`,
///     where the metadata declares the audio's SHA-256 digest and byte count and the actual audio
///     bytes match that declaration. Entries failing validation are removed as abandoned during
///     recovery and filtered from live listings — malformed or partial entries never become
///     upload work.
///   * **Finite persistence limits.** `prepare` enforces `maxQueueEntries` over preparation + ready
///     work and `maxEntryAudioBytes` per audio body, and cleans up its own directory if the
///     metadata write fails after the audio write. Uploader gating cannot bound what persists.
///   * **Durability ordering.** `finalize` synchronizes audio, metadata and the entry directory to
///     storage BEFORE the ready marker is published (atomic replace + sync), so the marker never
///     announces an entry whose bytes are not yet durable. The synchronization is routed through an
///     injected `synchronizer` seam; the ordering control pins marker publication strictly after
///     file/directory synchronization. (In-process controls cannot prove crash durability; they pin
///     the ORDER the platform mechanism must follow.)
///   * **One serialized queue owner.** All mutations run on an internal serial queue. Entries are
///     opaque `Entry` handles bound to this queue's root; a forged or foreign handle is refused by
///     every file-accessing method instead of being trusted by path.
///
/// Receipt handling, attempt gating, retry/backoff and network policy remain downstream uploader
/// concerns and are deliberately not here.
final class VoiceSharingUploadQueue {

    /// Per-entry audio ceiling. A compiled ceiling, NOT an approved activation value; the
    /// uploader validates against the spec's request/clip limits at attempt time.
    static let maxEntryAudioBytes = 16_000 * 2 * 60 * 2 // ≈ 60 s of 16 kHz mono s16le, doubled headroom

    /// Entry-count ceiling over preparation + ready work. Compiled ceiling, NOT an activation value.
    static let maxQueueEntries = 32

    /// Per-entry metadata ceiling (spec `max_metadata_bytes` is validated against a compiled
    /// ceiling; this is the ceiling, NOT an activation value).
    static let maxMetadataBytes = 64 * 1024

    /// Queue-age bound for ready entries. Entries older than this are removed at recovery and
    /// refuse publication — a compiled ceiling, NOT an activation value.
    static let maxEntryAge: TimeInterval = 48 * 60 * 60

    /// QUEUE-WIDE budgets. Per-entry bounds cannot bound the queue: N individually-legal entries
    /// still multiply. These are compiled defaults; like every other numeric limit here they are
    /// implementation bounds, NOT owner-approved activation values.
    struct AggregateLimits {
        let maxBytes: Int
        let maxRecords: Int

        static let `default` = AggregateLimits(
            maxBytes: VoiceSharingUploadQueue.maxQueueBytes,
            maxRecords: VoiceSharingUploadQueue.maxQueueEntries)
    }

    /// Durable proof of attempt ownership. `generation` is the FENCE: identity, not elapsed time,
    /// is what stops a stale owner from releasing or completing a successor's work.
    struct AttemptLease: Equatable {
        let generation: String
        let acquiredAt: Date
        let owner: Int32

        var jsonObject: [String: Any] {
            ["generation": generation,
             "acquiredAt": acquiredAt.timeIntervalSince1970,
             "owner": Int(owner)]
        }

        init(generation: String, acquiredAt: Date, owner: Int32) {
            self.generation = generation
            self.acquiredAt = acquiredAt
            self.owner = owner
        }

        init?(jsonObject: [String: Any]) {
            guard let generation = jsonObject["generation"] as? String,
                  UUID(uuidString: generation) != nil,
                  let acquiredAt = jsonObject["acquiredAt"] as? TimeInterval,
                  acquiredAt > 0, acquiredAt.isFinite,
                  let owner = jsonObject["owner"] as? Int,
                  owner >= 0
            else { return nil }
            self.generation = generation
            self.acquiredAt = Date(timeIntervalSince1970: acquiredAt)
            self.owner = Int32(clamping: owner)
        }
    }

    /// Attempt bounds. Compiled implementation defaults, NOT owner-approved activation values.
    struct AttemptLimits {
        let maxUploadAttempts: Int

        static let `default` = AttemptLimits(maxUploadAttempts: 5)
    }

    /// Upper bound on bytes this queue itself writes for one entry, excluding the caller's audio and
    /// metadata: `created.at` (a bounded decimal instant), `stage.publishing` (1 byte),
    /// `publication.failed` (1 byte), `ready.marker` (1 byte) and a temporary marker name. Reserving
    /// a fixed bound keeps admission arithmetic closed-form and independent of filename length.
    static let protocolOverheadBytes = 256

    /// Hard cap on directory entries examined during discovery. A cap checked AFTER an eager listing
    /// does not bound allocation, so listing itself goes through `listDirectoryBounded`, which stops
    /// at the cap and reports overflow. Exceeding it is a refusal: an entry directory that cannot be
    /// examined within the bound has unknowable usage.
    static let maxDirectoryEntries = 64

    /// The closed set of file names an entry directory may contain. Accounting and cleanup are
    /// defined over exactly these.
    /// The closed set of fixed file names an entry directory may contain.
    static let knownEntryNames: Set<String> = [
        attemptRecordName, attemptLeaseName,
        audioName, metadataName, createdName, readyMarkerName, stageName, failedName
    ]
    /// Prefix of this queue's own temporary marker names (`ready.marker.tmp-<UUID>`). A replacement
    /// that fails after writing the temporary can leave one behind, so it is part of the owned
    /// format and must be both accounted and cleanup-able rather than permanently blocking admission.
    ///
    /// Because the suffix is arbitrary, these names are NOT a finite set. They are recognised by
    /// prefix + well-formed UUID, and all work over them is budgeted.
    static let temporaryMarkerPrefix = "\(readyMarkerName).tmp-"

    /// Queue-wide byte budget. 32 entries x 60 s of 16 kHz mono PCM16 = 1920 s of audio, i.e. ~32
    /// minutes in total (32 entries x 60 s each), not a queue-wide 30-second window.
    static let maxQueueBytes = 32 * (16_000 * 2 * 60)

    enum PrepareError: Error, Equatable {
        case queueFull
        case audioTooLarge
        case metadataTooLarge
        /// The queue-wide byte budget would be exceeded. Distinct from per-entry `audioTooLarge`.
        case queueBytesExceeded
        /// Stored usage could not be determined, so admission is refused rather than assuming the
        /// unknown space is free.
        case accountingUnavailable
        /// An increment path was asked to spend an attempt the entry does not have.
        case attemptsExhausted
        /// Another owner holds the attempt lease.
        case leaseHeld
        /// A completion arrived from an owner that no longer holds the lease.
        case resultStale
        /// A retry reports a DIFFERENT outcome than the durably recorded pending settlement.
        case settlementConflict
        case expired
        /// The ready transition may have occurred but its final synchronization could not be
        /// confirmed. Distinct from every other case here, which are all known-uncommitted. Callers
        /// must reconcile (`reconcilePublication`) rather than assuming either outcome.
        case publicationUncertain
    }

    /// Opaque entry handle. Only names an entry under a root; every accessor validates that the
    /// handle belongs to THIS queue before touching the filesystem.
    struct Entry: Hashable {
        let root: URL
        let name: String
    }

    private static let readyMarkerName = "ready.marker"
    /// Write-once lifecycle stage, created BEFORE the marker is published. It is the discriminator
    /// that makes "marker present, no disqualifier" impossible to observe after a restart: an entry
    /// that reached publication always carries `stage.publishing`, and an entry that never did
    /// carries none. A truncated stage file is distinguishable from an absent one.
    private static let stageName = "stage.publishing"
    private static let audioName = "audio.wav"
    private static let metadataName = "metadata.json"
    /// The IMMUTABLE admission instant: written once at prepare, never refreshed by finalize or a
    /// retried publication. Queue age is measured from here, so a preparation held past the bound
    /// cannot gain a fresh lifetime by being published, and repeated finalize cannot extend it.
    private static let createdName = "created.at"
    /// Upper bound for the immutable instant's file. A timestamp is a short decimal string; anything
    /// larger is a corrupt or foreign object and must be refused without being read.
    /// Durable attempt record. Its PRESENCE means "an attempt started"; its CONTENT is the count. It
    /// is written before a request and never removed at request end, so attempts accumulate across
    /// process restarts as the spec requires.
    static let attemptRecordName = "attempts.json"
    static let maxCreationInstantBytes = 64
    /// Upper bound on the attempt record's size. A larger file is corrupt or foreign, and reading it
    /// to find out would let a hostile object drive allocation.
    static let maxAttemptRecordBytes = 64
    /// Name of the root-scoped lease for an in-flight attempt. It lives NEXT TO the entry (inside
    /// the entry directory, as `attempt.lease`) so a stale lease travels with its entry.
    static let attemptLeaseName = "attempt.lease"
    /// Number of fixed lock files. A stable hash maps every entry to exactly ONE of these, so the
    /// same entry always locks the same inode — mutual exclusion holds — while the namespace never
    /// grows. UUID-per-entry locks accumulated forever and, past the root's bounded discovery limit,
    /// permanently disabled admission. Hash collisions only over-serialize unrelated entries.
    static let leaseLockPoolSize = 16
    static let maxRootLockFiles = leaseLockPoolSize

    /// Root-level lease-lock file for an entry. Lives at the ROOT because entry directories are
    /// removed whole by recovery/exhaustion, which would invalidate the lock's inode. The name is
    /// drawn from a FIXED pool so lifetime entries cannot accumulate root artifacts.
    static func rootLeaseLockName(for entryName: String) -> String {
        "attempt.lock.\(stableLockIndex(for: entryName))"
    }

    /// Stable, dependency-free hash: FNV-1a over the entry name.
    static func stableLockIndex(for entryName: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in entryName.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Int(hash % UInt64(leaseLockPoolSize))
    }
    static let maxAttemptLeaseBytes = 256
    /// How long a lease is considered live without renewal. A killed owner cannot renew, so after
    /// this window another owner may reclaim. Compiled bound, NOT an activation value.
    /// App-private queue storage root (Application Support, per account-agnostic feature dir).
    /// Created lazily by callers; the queue itself requires the directory to exist at init.
    static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VoiceContributions", isDirectory: true)
    }

    static let attemptLeaseDuration: TimeInterval = 120
    /// Absolute ceiling on a stored attempt count. Compiled bound, NOT an activation value.
    static let maxUploadAttemptsCeiling = 1_000
    /// Present when publication failed and its cleanup could not complete. Such an entry is never
    /// exposed as ready, even if the ready marker survived.
    /// Present when this attempt definitively failed. Written BEFORE any removal attempt.
    private static let failedName = "publication.failed"

    let rootDirectory: URL
    private let fileManager: FileManager
    /// Storage-synchronization seam: fsync-equivalent for a file or directory path. Production
    /// default performs a real sync; controls inject a recorder to pin ordering.
    /// Testable time source for the immutable queue-age bound.
    private let clock: () -> Date
    private let synchronizer: (_ path: URL, _ isDirectory: Bool) throws -> Void
    private let failureRecordWriter: (URL) throws -> Void

    /// Whether the most recent refused publication could be disqualified DURABLY. `unavailable`
    /// means neither the failure record nor marker removal succeeded, so only this process knows the
    /// entry is unpublishable — a restart cannot be protected by in-memory state.
    /// Outcome of a publication attempt. The spec requires three distinct states: a generic thrown
    /// error must not erase the difference between "definitely not committed" and "may have
    /// committed".
    enum PublicationOutcome: Equatable {
        /// Durable success: the entry is ready and its readiness is confirmed on disk.
        case committed
        /// Known to precede the ready transition: the entry is not ready and never will be.
        case uncommitted
        /// The ready transition MAY have occurred but its final synchronization could not be
        /// confirmed. Neither success nor rejection: the same immutable identity must be reconciled
        /// under the queue owner before any attempt, and a fresh instance applies the same rules.
        case uncertain
    }

    /// Entries whose ready transition this instance could not confirm. An in-process HINT only: it
    /// is never treated as proof of non-publication, and reconciliation derives its verdict from
    /// durable state alone so a fresh instance reaches the same answer.
    private var uncertainEntriesLocked: Set<Entry> = []
    /// Injectable marker-installation seam. Exists so the atomic-replacement failure path (which may
    /// install the marker and still throw) is testable: FileManager's replacement API lives in an
    /// extension and cannot be overridden.
    private let markerReplacer: (URL, URL) throws -> URL?
    private var aggregateLimits: AggregateLimits
    private let attemptLimits: AttemptLimits
    /// In-flight ownership is deliberately IN-MEMORY ONLY: a live request belongs to the process
    /// that opened it, so a killed process cannot leave one behind. The durable file records that an
    /// attempt STARTED (so the count survives restart) but is never read as "still running".
    private var inFlightAttempts: [Entry: AttemptLease] = [:]

    /// Injectable directory listing. Exists so accounting failure is testable: FileManager's
    /// `contentsOfDirectory(at:includingPropertiesForKeys:)` is defined in an extension and cannot
    /// be overridden by a subclass.
    private let listDirectory: (URL, [URLResourceKey]) throws -> [URL]
    /// Bounded listing. Returns at most `maxDirectoryEntries` names along with whether more existed,
    /// so callers refuse on overflow instead of allocating an unbounded array first.
    private let listDirectoryBounded: (URL, [URLResourceKey], Int) throws -> (urls: [URL], overflowed: Bool)
    private let serialQueue = DispatchQueue(label: "fm.auris.voicesharing.uploadqueue")

    /// Creates the queue over `rootDirectory` and runs recovery: entries that are not complete
    /// (including abandoned preparation, foreign directories and malformed entries) are removed;
    /// complete ready entries are kept intact.
    init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init,
        synchronizer: @escaping (_ path: URL, _ isDirectory: Bool) throws -> Void = VoiceSharingUploadQueue.defaultSynchronizer,
        failureRecordWriter: @escaping (URL) throws -> Void = { try Data([0x01]).write(to: $0, options: .atomic) },
        markerReplacer: @escaping (URL, URL) throws -> URL? = {
            try FileManager.default.replaceItemAt($0, withItemAt: $1)
        },
        aggregateLimits: AggregateLimits = .default,
        attemptLimits: AttemptLimits = .default,
        listDirectory: @escaping (URL, [URLResourceKey]) throws -> [URL] = { url, keys in
            try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
        },
        listDirectoryBounded: @escaping (URL, [URLResourceKey], Int) throws
            -> (urls: [URL], overflowed: Bool) = VoiceSharingUploadQueue.defaultBoundedLister
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.clock = clock
        self.synchronizer = synchronizer
        self.failureRecordWriter = failureRecordWriter
        self.markerReplacer = markerReplacer
        self.aggregateLimits = aggregateLimits
        self.attemptLimits = attemptLimits
        self.listDirectory = listDirectory
        self.listDirectoryBounded = listDirectoryBounded
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // Serialize recovery with any future mutations; construction happens before the queue is
        // shared, but the same discipline keeps restart accounting on the owning queue.
        serialQueue.sync { recoverLocked() }
    }

    /// REAL synchronization: stat/open/fsync results are checked and failures THROW — a storage
    /// layer that cannot confirm durability must fail publication, not silently accept it.
    private static func defaultSynchronizer(path: URL, isDirectory: Bool) throws {
        var statBuffer = stat()
        guard stat(path.path, &statBuffer) == 0 else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                          userInfo: [NSFilePathErrorKey: path.path])
        }
        // Directories cannot be opened for writing; fsync them read-only via the descriptor.
        let fd = open(path.path, isDirectory ? O_RDONLY : O_WRONLY)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    // MARK: Preparation

    /// Writes audio and metadata into a new entry directory, enforcing the finite limits. The
    /// entry is NOT ready and never appears in `readyEntries()` until `finalize` marks it.
    /// A failure after the directory exists removes that directory — failed preparation leaves
    /// nothing behind.
    func prepare(metadata: Data, audio: Data) throws -> Entry {
        try serialQueue.sync {
            let name = UUID().uuidString
            let entryDirectory = rootDirectory.appendingPathComponent(name, isDirectory: true)
            do {
                guard audio.count <= Self.maxEntryAudioBytes else { throw PrepareError.audioTooLarge }
                guard metadata.count <= Self.maxMetadataBytes else { throw PrepareError.metadataTooLarge }
                // Aggregate admission is measured from what is ACTUALLY stored, not from a running
                // counter: a counter drifts the moment any write, removal or crash disagrees with
                // it, and the queue would then admit past its budget or refuse within it forever.
                let usage = try storedUsageLocked()
                guard usage.records < aggregateLimits.maxRecords else { throw PrepareError.queueFull }
                // Reserve the WHOLE entry footprint, not just the two caller-supplied blobs: prepare
                // writes `created.at`, finalize writes `stage.publishing` and a temporary marker, and
                // the completed entry carries `ready.marker`. Charging only audio+metadata would let
                // a budget equal to audio+metadata be exceeded by preparation itself.
                let incoming = audio.count + metadata.count + Self.protocolOverheadBytes
                guard usage.bytes + incoming <= aggregateLimits.maxBytes else {
                    throw PrepareError.queueBytesExceeded
                }
                try fileManager.createDirectory(at: entryDirectory, withIntermediateDirectories: true)
                try audio.write(to: entryDirectory.appendingPathComponent(Self.audioName), options: .atomic)
                try metadata.write(to: entryDirectory.appendingPathComponent(Self.metadataName), options: .atomic)
                // One immutable admission instant for the whole queue lifetime of this entry.
                let createdAt = String(clock().timeIntervalSince1970)
                try Data(createdAt.utf8).write(to: entryDirectory.appendingPathComponent(Self.createdName), options: .atomic)
                return Entry(root: rootDirectory, name: name)
            } catch {
                try? fileManager.removeItem(at: entryDirectory)
                throw error
            }
        }
    }

    /// Measured, NON-CONSUMING admission check for callers that must refuse before allocating
    /// (the contribution sink encodes its WAV copies only if the budget can carry the worst-case
    /// entry). `prepare` remains the exact authority at write time.
    func hasAdmissionAllowance(forBytes: Int) -> Bool {
        serialQueue.sync {
            guard let usage = try? storedUsageLocked() else { return false }
            return usage.bytes + forBytes <= aggregateLimits.maxBytes
                && usage.records < aggregateLimits.maxRecords
        }
    }

    /// Consent revocation between prepare and finalize: removes an UNREADY entry, releasing its
    /// charge. A ready entry is refused (publication goes through the settlement protocol, never
    /// an unowned delete), a foreign handle is a refusal, and a cleanup FAILURE throws with the
    /// entry left in place — retained, still charged, never silently "gone".
    @discardableResult
    func discardUnready(_ entry: Entry) throws -> Bool {
        try serialQueue.sync {
            guard entry.root == rootDirectory,
                UUID(uuidString: entry.name) != nil,
                !entry.name.contains("/")
            else { throw CocoaError(.fileNoSuchFile) }
            let directory = try validatedEntryDirectoryLocked(entry)
            switch Self.statKind(of: directory.appendingPathComponent(Self.readyMarkerName)) {
            case .present:
                return false
            case .failure:
                throw PrepareError.accountingUnavailable
            case .absent:
                break
            }
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                // Cleanup failure: the entry REMAINS (charged, unready). Never collapse into gone.
                throw PrepareError.accountingUnavailable
            }
            return true
        }
    }

    /// Consent revocation (withdrawal, sign-out, switch-off, lease loss): removes EVERY entry —
    /// ready, unready or disqualified — together with its root-level bookkeeping (settlement
    /// records). The stable lock pool and the root itself are NOT removed. In-memory attempt state
    /// is cleared under the serial queue. Removal failures leave the offending entry in place
    /// (still charged) and are counted in the result; they never abort the whole purge.
    /// Consent revocation purge — FAIL-EXPLICIT, bounded, durable (reviewer 5b1ba089):
    ///   * Bounded listing with explicit overflow: an unbounded or collapsed listing failure
    ///     REFUSES the purge (`nil` result) instead of masquerading as "nothing to remove".
    ///   * A settlement record is removed only AFTER its entry's removal SUCCEEDED — evidence
    ///     must never outlive-or-orphan wrongly: entry first, then its settlement proof.
    ///   * An entry whose removal FAILS is DISQUALIFIED in place (`publication.failed` disposal
    ///     intent): it can never serve after restart, and it stays charged.
    ///   * The root directory is synchronized AFTER the removals, so a crash cannot resurrect a
    ///     purged recording from a stale directory entry.
    func purgeAll() -> (removed: Int, retainedDisqualified: Int)? {
        serialQueue.sync {
            let listing: [URL]
            do {
                let (urls, overflowed) = try listDirectoryBounded(
                    rootDirectory, [.isDirectoryKey], Self.maxQueueEntries * 4)
                if overflowed { return nil }
                listing = urls
            } catch {
                // Listing failure is NOT "nothing to remove": refuse the purge explicitly.
                return nil
            }
            var removed = 0
            var retainedDisqualified = 0
            for item in listing {
                let name = item.lastPathComponent
                guard UUID(uuidString: name) != nil || Self.parseSettlementName(name) != nil else {
                    continue
                }
                if let settlementEntry = Self.parseSettlementName(name) {
                    // Settlement evidence: removed only when its entry is already gone; a
                    // settlement orphaned by a FAILED entry removal survives as evidence of the
                    // retained entry's disposition.
                    if listing.contains(where: { $0.lastPathComponent == settlementEntry }) {
                        retainedDisqualified += 1
                        continue
                    }
                }
                // MARK-THEN-REMOVE: an entry is DISQUALIFIED before any deletion attempt, so a
                // partially-failing recursive removal can never leave a half-damaged entry that
                // still qualifies (reviewer: failed purge must not damage or resurrect).
                if UUID(uuidString: name) != nil {
                    let intent = item.appendingPathComponent(Self.failedName)
                    do {
                        try failureRecordWriter(intent)
                        try synchronizer(item, true)
                    } catch {
                        // Cannot durably disqualify: refuse to touch the entry at all.
                        retainedDisqualified += 1
                        continue
                    }
                }
                do {
                    try fileManager.removeItem(at: item)
                    removed += 1
                } catch {
                    retainedDisqualified += 1
                }
            }
            inFlightAttempts.removeAll()
            uncertainEntriesLocked.removeAll()
            // Durability barrier: the ROOT listing must reflect the removals on storage.
            do { try synchronizer(rootDirectory, true) } catch { /* root still lists some removed entries; recovery's strict scan re-derives truth */ }
            return (removed, retainedDisqualified)
        }
    }

    /// Atomically marks a prepared entry ready AFTER its bytes are durable: audio and metadata are
    /// synchronized, then the entry directory is synchronized, and only then is the marker written
    /// (atomic replace) and synchronized. A crash before the marker leaves an unready entry that
    /// recovery removes.
    func finalize(_ entry: Entry) throws {
        try serialQueue.sync {
            let directory = try validatedEntryDirectoryLocked(entry)
            // Publication must not launder an over-age preparation into a fresh lifetime: the
            // creation instant is immutable, so an entry past the bound refuses publication.
            if let createdAt = creationInstantLocked(in: directory),
                clock().timeIntervalSince(createdAt) > Self.maxEntryAge {
                throw PrepareError.expired
            }
            let marker = directory.appendingPathComponent(Self.readyMarkerName)
            let stage = directory.appendingPathComponent(Self.stageName)
            // CAPACITY CHECK BEFORE GROWTH. Publication and repeated finalization both write files,
            // so the budget must be re-verified against actual stored bytes before those writes
            // happen — not assumed from the admission decision, which other entries may have
            // consumed in the meantime. Refusing here is the fail-closed direction: no bytes are
            // written for an entry the queue cannot afford.
            // `storedUsageLocked` already charges EVERY entry its protocol headroom (published or
            // not), so the current growth of THIS entry is already covered by that charge. What must
            // be re-verified is that the total still fits — the earlier admission decision may have
            // been overtaken by other entries.
            let usageBefore = try storedUsageLocked()
            guard usageBefore.bytes <= aggregateLimits.maxBytes else {
                throw PrepareError.queueBytesExceeded
            }
            // The lifecycle stage is recorded BEFORE publication begins, so that after any crash the
            // presence of this file means "publication was attempted and may not have completed".
            // Written with the plain (non-atomic) route so a crash HERE leaves nothing rather than a
            // half-written discriminator: an entry with no stage file and no marker never published.
            // Deliberately NOT routed through the injectable failure-record seam: this write is part
            // of the publication protocol, and letting failure injection suppress it would remove the
            // discriminator that the restart guarantee depends on.
            if !fileManager.fileExists(atPath: stage.path) {
                try Data([0x01]).write(to: stage, options: .atomic)
                // No post-write re-check is needed: admission reserved `protocolOverheadBytes`,
                // which strictly bounds every file this queue writes for an entry beyond the
                // caller's blobs (created.at ≈ 18 B, stage/marker/failure 1 B each). A re-check
                // that can never fire would be untested dead code, not a defence — so the
                // reservation is kept honest by `test_exactLimitAdmissionAccountsForProtocolOverhead`
                // measuring the real on-disk footprint instead.
            }
            // PUBLICATION PROTOCOL — one commit point, and the order is chosen so that the commit
            // point is the LAST fallible action.
            //
            // Spec (voice-recording-uploads.md): durability of the immutable bytes is established
            // BEFORE readiness; readiness is published atomically and its directory synchronization
            // confirmed before durable success is reported. A failure known to precede the ready
            // transition is uncommitted. A ready transition that may have occurred but whose final
            // synchronization cannot be confirmed is UNCERTAIN, not success and not rejection.
            //
            // The ordering exists because every design that clears a discriminator AFTER publishing
            // readiness leaves a window: removing that discriminator can succeed and its sync can
            // fail, returning the entry to "marker with no disqualifier". The stage file is therefore
            // cleared BEFORE the marker is published, and nothing fallible follows publication.
            try synchronizer(directory.appendingPathComponent(Self.audioName), false)
            try synchronizer(directory.appendingPathComponent(Self.metadataName), false)
            // created.at is recovery AUTHORITY (immutable age basis), so its contents must be durable
            // before readiness too; otherwise a restart can lose the very bound the entry relies on.
            try synchronizer(directory.appendingPathComponent(Self.createdName), false)
            try synchronizer(directory, true)

            // Clear the stage while the marker does NOT yet exist: the entry is then a plain
            // prepared entry, and a failure here is unambiguously uncommitted.
            try fileManager.removeItem(at: stage)
            try synchronizer(directory, true)

            let temporary = directory.appendingPathComponent("\(Self.readyMarkerName).tmp-\(UUID().uuidString)")
            try Data([0x01]).write(to: temporary, options: .atomic)
            do {
                _ = try markerReplacer(marker, temporary)
            } catch {
                // The replacement installs the marker and THEN throws (or throws after installing).
                // Whatever the reason, a marker may now exist, so this is a possible transition and
                // must not be classified as definitely-uncommitted.
                uncertainEntriesLocked.insert(entry)
                throw PrepareError.publicationUncertain
            }

            // THE COMMIT POINT. The marker now exists. The three synchronizations below are
            // CONFIRMATION work, and they are fallible: this is why the outcome is tri-state rather
            // than an absence of fallible steps. If confirmation cannot be completed we do not know
            // whether a later process will see the marker. That is `uncertain`, and it must be
            // REPORTED as such — never silently downgraded to success or to "definitely uncommitted".
            do {
                try synchronizer(marker, false)
                try synchronizer(directory, true)
                try synchronizer(rootDirectory, true)
            } catch {
                // Mark it uncertain IN PROCESS ONLY as a hint for this instance; it is deliberately
                // not proof of non-publication and is never consulted by reconciliation. A fresh
                // instance sees the same durable state and reaches the same verdict.
                uncertainEntriesLocked.insert(entry)
                throw PrepareError.publicationUncertain
            }
        }
    }

    /// Enumerates at most `limit` names and reports whether the directory holds more. Stops pulling
    /// from the enumerator at the cap, so allocation is bounded by `limit` rather than by directory
    /// size.
    /// A single step of enumeration: either a URL, or the error that stopped iteration.
    enum EnumerationStep {
        case url(URL)
        case failure(Error)
    }

    /// Injectable enumeration source. `nil` means "use the real FileManager enumerator". Exists so a
    /// MID-ENUMERATION error can be tested on this runner, where filesystem permissions do not
    /// reliably produce one.
    static let defaultEnumeratorSource: ((URL, [URLResourceKey]) -> AnySequence<EnumerationStep>)? = nil

    static let defaultBoundedLister: (URL, [URLResourceKey], Int) throws -> (urls: [URL], overflowed: Bool) =
        VoiceSharingUploadQueue.boundedLister(with: nil)

    /// Builds a bounded lister over an optional injected enumeration source. Shared by the default
    /// lister and by tests that need a mid-iteration failure.
    static func boundedLister(
        with source: ((URL, [URLResourceKey]) -> AnySequence<EnumerationStep>)?
    ) -> (URL, [URLResourceKey], Int) throws -> (urls: [URL], overflowed: Bool) {
        { directory, keys, limit in
            // ONE path: the injected source and the real enumerator both produce
            // `EnumerationStep` sequences that are processed by `boundedListing`.
            let steps = source?(directory, keys)
                ?? VoiceSharingUploadQueue.realSteps(directory, keys)
            return try boundedListing(over: steps, limit: limit)
        }
    }

    /// The production path over a step sequence: stops at the cap, and THROWS if iteration ended on
    /// an error rather than on the cap. A truncated listing is never reported as complete.
    static func boundedListing(
        over steps: AnySequence<EnumerationStep>, limit: Int
    ) throws -> (urls: [URL], overflowed: Bool) {
        var urls: [URL] = []
        for step in steps {
            switch step {
            case .url(let url):
                if urls.count >= limit { return (urls, true) }
                urls.append(url)
            case .failure(let error):
                throw error
            }
        }
        return (urls, false)
    }

    /// Adapts the REAL FileManager enumerator into the same `EnumerationStep` sequence that the
    /// injected control produces, so there is exactly ONE step-processing path. Errors from the
    /// enumerator are yielded as `.failure` rather than captured in a side channel: a control that
    /// supplies `.failure` therefore exercises the identical code that a real enumeration error
    /// takes, which a parallel implementation could not guarantee.
    static func realSteps(
        _ directory: URL, _ keys: [URLResourceKey]
    ) -> AnySequence<EnumerationStep> {
        // FileManager reports enumeration errors to the error HANDLER; `nextObject()` never yields an
        // Error object. So the handler must CAPTURE the error and the iterator must surface it as
        // `.failure` — discarding it here (as an earlier version did) silently loses unread storage.
        final class PendingError { var error: Error? }
        let pending = PendingError()
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                // Capture, then stop: continuing would keep skipping storage we could not read.
                pending.error = error
                return false
            })
        else {
            return AnySequence([.failure(CocoaError(.fileReadUnknown))])
        }
        return AnySequence { () -> AnyIterator<EnumerationStep> in
            AnyIterator {
                // Checked IMMEDIATELY after the read that may have triggered it, and before any URL
                // is yielded, so an error can never be reordered behind a later result.
                let object = enumerator.nextObject()
                if let error = pending.error {
                    pending.error = nil
                    return .failure(error)
                }
                guard let object else { return nil }
                // A non-URL element is not a name we can account for; refuse rather than substitute.
                guard let url = object as? URL else {
                    return .failure(CocoaError(.fileReadUnknown))
                }
                return .url(url)
            }
        }
    }


    // MARK: Attempt ownership

    /// Number of attempts already started for this entry. Read from durable state so the count
    /// survives process restarts.
    func attemptCount(for entry: Entry) throws -> Int {
        try serialQueue.sync { try attemptCountLocked(for: entry) }
    }

    /// Whether this process currently owns a live request for the entry.
    func isAttemptInFlight(_ entry: Entry) -> Bool {
        serialQueue.sync { inFlightAttempts[entry] != nil }
    }

    /// Whether the entry has attempts remaining.
    func isAttemptable(_ entry: Entry) throws -> Bool {
        try serialQueue.sync { try isAttemptableLocked(entry) }
    }

    /// Acquires single-request ownership and consumes one attempt. Returns `false` when another
    /// request owns the entry or its attempts are exhausted.
    @discardableResult
    func beginAttempt(_ entry: Entry) throws -> Bool {
        try serialQueue.sync {
            guard inFlightAttempts[entry] == nil else { return false }
            // Handle identity is checked BEFORE coverage (a foreign handle is a refusal, not a
            // coverage question). Clarification 7e9606b (spec c988cb1b): attempts must then honor
            // unknown coverage even for an already-held entry handle. The STRICT owner-wide
            // coverage authority is the same one the serving query uses: root listing AND every
            // entry's required state must be KNOWN, not merely the target entry's — another
            // entry's stat/read failure holds attempts for the whole owner.
            guard entry.root == rootDirectory,
                UUID(uuidString: entry.name) != nil,
                !entry.name.contains("/")
            else { throw CocoaError(.fileNoSuchFile) }
            let discovered = try strictOwnerCoverageLocked()
            guard discovered.contains(entry) else { return false }
            // EVERY non-dispatch path settles explicitly: a lease acquired here must never survive
            // a later refusal or throw, or the entry would be blocked by its own failed attempt.
            let lease = try acquireLeaseLocked(for: entry)
            guard let lease else { return false }
            do {
                // Ready/count checks run AFTER the claim so only the owner mutates shared state.
                guard try isAttemptableLocked(entry) else {
                    if isCompleteEntryLocked(at: entry),
                       try attemptCountLocked(for: entry) >= attemptLimits.maxUploadAttempts {
                        try? fileManager.removeItem(at: entryDirectoryLocked(for: entry))
                    }
                    releaseLeaseLocked(for: entry, owner: lease)
                    return false
                }
                try recordAttemptLocked(entry)
            } catch {
                releaseLeaseLocked(for: entry, owner: lease)
                throw error
            }
            inFlightAttempts[entry] = lease
            return true
        }
    }

    /// Releases single-request ownership. Only the CURRENT owner's release deletes the lease; a
    /// stale owner (whose lease was reclaimed after expiry) must not delete its successor's.

    /// Outcome of an upload attempt, applied atomically with ownership validation.
    enum AttemptOutcome: String {
        /// Delivered: the entry is removed and the lease released, atomically.
        case delivered
        /// Retryable failure: only the lease is released; the entry stays for the next attempt.
        case retryableFailure
        /// Permanent failure: the entry is removed (content-free terminal state).
        case abandoned
    }

    /// Applies an attempt result. The caller's lease is REVALIDATED under the entry's flock before
    /// anything happens: an intervening expiry/reclaim means this result is stale and must be
    /// refused — an old owner must not delete an entry a successor is now uploading.
    /// Durable record of WHICH settlement transition is pending for an entry. Written at the ROOT
    /// (outside removable scopes) BEFORE any mutation and removed only after the mutation is
    /// durably confirmed. This is what makes reconciliation exact: the absent lease/entry is
    /// reconciled as THIS transition, not merely as "some owner did something".
    static let settlementRecordName = "attempt.settlement"
    static func settlementRecordName(for entryName: String) -> String {
        "\(settlementRecordName).\(entryName).json"
    }
    static let maxSettlementRecordBytes = 256

    enum SettlementPhase: String {
        /// The transition is authorized but not yet durably completed.
        case pending
        /// The transition was applied AND its durability barrier succeeded.
        case confirmed
    }

    struct SettlementRecord {
        let generation: String
        let owner: Int32
        let outcome: AttemptOutcome
        var phase: SettlementPhase = .pending

        var jsonObject: [String: Any] {
            ["generation": generation,
             "owner": Int(owner),
             "outcome": outcome.rawValue,
             "phase": phase.rawValue]
        }

        /// Strict parse: malformed records are UNKNOWN pending state and must refuse settlement,
        /// never be treated as absent intent or overwritten by a fresh transition.
        static func parse(_ data: Data) -> SettlementRecord? {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let generation = obj["generation"] as? String,
                  let owner = obj["owner"] as? Int,
                  let outcomeRaw = obj["outcome"] as? String,
                  let outcome = AttemptOutcome(rawValue: outcomeRaw),
                  let phaseRaw = obj["phase"] as? String,
                  let phase = SettlementPhase(rawValue: phaseRaw),
                  Int32(exactly: owner) != nil else { return nil }
            return SettlementRecord(generation: generation, owner: Int32(exactly: owner)!,
                                    outcome: outcome, phase: phase)
        }

        func encoded() throws -> Data {
            let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
            guard data.count <= VoiceSharingUploadQueue.maxSettlementRecordBytes else {
                throw PrepareError.accountingUnavailable
            }
            return data
        }
    }

    /// Best-effort retirement of a settled record: the confirmed phase already made completion
    /// durable, so cleanup failure leaves a record reconciliation still accepts.
    private func clearSettlementBestEffort(for entryName: String) {
        let url = rootDirectory.appendingPathComponent(Self.settlementRecordName(for: entryName))
        try? fileManager.removeItem(at: url)
        try? synchronizer(rootDirectory, true)
    }

    /// Entry name encoded in a well-formed root settlement record name, else nil.
    static func parseSettlementName(_ fileName: String) -> String? {
        guard fileName.hasPrefix(settlementRecordName + "."),
              fileName.hasSuffix(".json") else { return nil }
        let entryName = String(fileName.dropFirst((settlementRecordName + ".").count)
            .dropLast(".json".count))
        guard UUID(uuidString: entryName) != nil else { return nil }
        return entryName
    }

    /// Recovery for settlement records whose owner is gone. PENDING records are NEVER touched:
    /// they are the only reconciliation state their owner or a fresh successor has. CONFIRMED
    /// records (completion already durable) are verified against on-disk state and retired.
    func recoverAbandonedSettlements() {
        guard let listed = try? listDirectoryBounded(
            rootDirectory, [.isDirectoryKey], Self.maxDirectoryEntries), !listed.overflowed else {
            return
        }
        for url in listed.urls {
            let entryName = Self.parseSettlementName(url.lastPathComponent)
            guard let entryName else { continue }
            let directory = rootDirectory.appendingPathComponent(entryName, isDirectory: true)
            switch Self.statKind(of: url) {
            case .absent, .failure:
                continue
            case .present:
                break
            }
            // Reviewer 737cba7c (2): read and validate the CURRENT record UNDER the entry lock,
            // with the same bounded/regular-file reader the apply path uses. A pre-lock read can
            // be stale: another owner may retire the old record and publish a new settlement
            // before this lock is obtained, and acting on the stale record could delete it.
            let lock = try? LeaseLock(entryName: entryName, rootDirectory: rootDirectory)
            guard let lock else { continue }
            defer { lock.close() }
            do { try lock.lockExclusive() } catch { continue }
            guard fileSizeIfRegularLocked(at: url).map({ $0.isRegular && $0.bytes > 0 && $0.bytes <= Self.maxSettlementRecordBytes }) == true,
                  let data = try? Data(contentsOf: url),
                  let record = SettlementRecord.parse(data) else {
                // Unknown pending state is NEVER deleted by recovery: only its owner path may
                // classify it. Leave it; applyAttemptResult will refuse with accountingUnavailable.
                continue
            }
            switch record.phase {
            case .pending:
                // The transition may not have been applied; the pending record is the ONLY thing
                // that lets its owner (or a fresh successor) reconcile the exact transition.
                // Recovery must NOT retire it — applyAttemptResult handles every pending case:
                // entry present (apply), entry absent (repeat the root barrier and complete).
                continue
            case .confirmed:
                // Completion is durable: verify state matches, then retire.
                let stateOK: Bool
                switch record.outcome {
                case .delivered, .abandoned:
                    stateOK = Self.statKind(of: directory) == .absent
                case .retryableFailure:
                    stateOK = Self.statKind(
                        of: directory.appendingPathComponent(Self.attemptLeaseName)) == .absent
                }
                guard stateOK else { continue }
                try? fileManager.removeItem(at: url)
                try? synchronizer(rootDirectory, true)
            }
        }
    }

    /// Whether the given owner token still holds the lease. Verify the
    /// durable state still matches the recorded outcome, then retire the record best-effort.
    private func reconcileConfirmedSettlement(
        _ record: SettlementRecord, entry: Entry, directory: URL) throws {
        switch record.outcome {
        case .delivered, .abandoned:
            guard Self.statKind(of: directory) == .absent else {
                // Confirmed says removed; state says present. Unexplainable: refuse.
                throw PrepareError.accountingUnavailable
            }
        case .retryableFailure:
            guard Self.statKind(of: directory.appendingPathComponent(Self.attemptLeaseName)) == .absent
            else {
                throw PrepareError.accountingUnavailable
            }
        }
        clearSettlementBestEffort(for: entry.name)
    }

    func applyAttemptResult(_ entry: Entry, lease: AttemptLease, outcome: AttemptOutcome) throws {
        // Boundary classification: any filesystem/barrier error inside means the settlement's
        // outcome is UNKNOWN. PrepareErrors thrown deliberately keep their meaning; raw I/O errors
        // become `.publicationUncertain`.
        do {
            try applyAttemptResultLocked(entry, lease: lease, outcome: outcome)
        } catch let error as PrepareError {
            throw error
        } catch {
            throw PrepareError.publicationUncertain
        }
    }

    private func applyAttemptResultLocked(
        _ entry: Entry, lease: AttemptLease, outcome: AttemptOutcome) throws {
        try serialQueue.sync {
            // Reviewer 4b02a457: handle validation is restored — this entry must belong to THIS
            // root and carry a name this queue could have minted, before any path is constructed.
            guard entry.root == rootDirectory,
                UUID(uuidString: entry.name) != nil,
                !entry.name.contains("/")
            else { throw CocoaError(.fileNoSuchFile) }

            let lock = try LeaseLock(entryName: entry.name, rootDirectory: rootDirectory)
            defer { lock.close() }
            try lock.lockExclusive()
            let directory = entryDirectoryLocked(for: entry)
            let settlementURL = rootDirectory.appendingPathComponent(
                Self.settlementRecordName(for: entry.name))

            enum IntentRead { case record(SettlementRecord); case absent; case unknown }
            // Reviewer 3aa2b731 (3): oversized, nonregular, unreadable or malformed intent is
            // UNKNOWN pending state — refuse, never treat as absent or overwrite as fresh.
            func readSettlement() throws -> IntentRead {
                switch Self.statKind(of: settlementURL) {
                case .absent:
                    return .absent
                case .failure:
                    return .unknown
                case .present:
                    // Reviewer 737cba7c (2): the reader checks the REGULAR-FILE kind too, not
                    // only the size bound.
                    guard let size = fileSizeIfRegularLocked(at: settlementURL),
                        size.isRegular, size.bytes > 0,
                        size.bytes <= Self.maxSettlementRecordBytes else {
                        return .unknown
                    }
                    guard let data = try? Data(contentsOf: settlementURL),
                          let record = SettlementRecord.parse(data) else {
                        return .unknown
                    }
                    return .record(record)
                }
            }
            // Reviewer 3aa2b731 (1): the intent file ITSELF is barrier-confirmed (file, then its
            // naming directory), not just the root.
            func writeSettlement(_ record: SettlementRecord) throws {
                let data = try record.encoded()
                try data.write(to: settlementURL, options: [.atomic])
                try synchronizer(settlementURL, false)
                try synchronizer(rootDirectory, true)
            }
            /// Reviewer 3aa2b731 (1): before every DESTRUCTIVE continuation on a recorded intent,
            /// re-confirm that the intent is durably in place (content re-read + file + root
            /// barriers, under the lock). An unconfirmed record must not authorize deletion.
            func confirmIntentDurability(_ expected: SettlementRecord) throws {
                let reread = try readSettlement()
                guard case .record(let live) = reread,
                      live.generation == expected.generation,
                      live.owner == expected.owner,
                      live.outcome == expected.outcome,
                      live.phase == expected.phase else {
                    throw PrepareError.publicationUncertain
                }
                try synchronizer(settlementURL, false)
                try synchronizer(rootDirectory, true)
            }
            /// Reviewer 3aa2b731 (2): clearing is two-phase. First REWRITE the record as
            /// `confirmed` and barrier it — that write is what makes completion durable and
            /// recoverable. Only then remove the record. If the final removal or its barrier
            /// fails, the confirmed record survives and retry/fresh-instance reconciliation
            /// still succeeds.
            func confirmPhase(_ record: SettlementRecord) throws {
                var confirmed = record
                confirmed.phase = .confirmed
                // Reviewer d28594ef: the atomic rewrite REPLACES the inode — fsyncing the
                // previous pending file proves nothing about the replacement. Every journal
                // rewrite synchronizes FILE first, then its naming directory. A file-barrier
                // failure retains the recovery state (the atomic temp either lands or not; the
                // record is re-readable either way) and refuses success.
                let data = try confirmed.encoded()
                try data.write(to: settlementURL, options: [.atomic])
                try synchronizer(settlementURL, false)
                try synchronizer(rootDirectory, true)
            }


            // Record the pending transition DURABLY before mutating anything. A crash between
            // this write and the mutation leaves the intent recoverable; a crash after mutation
            // but before confirmation leaves it reconcilable. The record binds generation, owner
            // AND outcome, so a retry can only complete the exact transition it started.
            let intentRead = try readSettlement()
            let recorded: SettlementRecord?
            switch intentRead {
            case .unknown:
                // Unknown pending state: refuse rather than guess or overwrite.
                throw PrepareError.accountingUnavailable
            case .record(let prior):
                // Reviewer 737cba7c (1): identity and outcome are checked BEFORE the phase
                // dispatch — a surviving confirmed record must not let a foreign token or a
                // contradictory outcome claim success.
                guard prior.generation == lease.generation else {
                    throw PrepareError.resultStale
                }
                guard prior.outcome == outcome else {
                    // Contradictory retry: the recorded transition says something else; a
                    // different outcome would claim a removal it never authorized.
                    throw PrepareError.settlementConflict
                }
                if prior.phase == .confirmed {
                    // The transition was applied and its durability barrier SUCCEEDED. Completion
                    // is durable; this call (and any later retry) just verifies and cleans up.
                    try reconcileConfirmedSettlement(prior, entry: entry, directory: directory)
                    inFlightAttempts.removeValue(forKey: entry)
                    return
                }
                // Reviewer 3aa2b731 (1): an UNCONFIRMED record must not authorize deletion until
                // its own durability is re-established under this lock.
                // Reviewer 737cba7c: an UNCONFIRMED record must not authorize deletion. The
                // barrier failure surfaces raw here (uncertain outcome) — an already-CONFIRMED
                // record never needs this re-confirmation, so a retry after the confirmed-phase
                // barrier failed is not blocked by "unknown intent durability".
                try confirmIntentDurability(prior)
                recorded = prior
            case .absent:
                // No pending record: this is a FRESH settlement, which requires the lease to be
                // live and owned by this caller. Absence without intent is NOT settled success.
                let current = leaseOwnerLocked(
                    at: directory.appendingPathComponent(Self.attemptLeaseName))
                guard Self.statKind(of: directory) == .present,
                    let held = current, held.generation == lease.generation
                else { throw PrepareError.resultStale }
                let fresh = SettlementRecord(
                    generation: lease.generation, owner: lease.owner, outcome: outcome)
                // If the intent cannot be durably recorded, the transition must not start:
                // uncertain, ownership retained, retry starts over from a live lease.
                try writeSettlement(fresh)
                recorded = fresh
            }
            guard let recorded else { throw PrepareError.accountingUnavailable }

            // A lock serializes transitions; it does NOT make failed filesystem operations succeed
            // or persist. Settlement failures propagate as UNCERTAIN and keep the intent record
            // (and the caller's ownership) so the exact transition can be retried.
            func confirmEntryRemovalDurability() throws {
                try synchronizer(rootDirectory, true)
            }
            func confirmLeaseRemovalDurability() throws {
                try synchronizer(directory, true)
            }
            /// Two-phase completion: first make the CONFIRMED phase durable (that write is the
            /// recoverable completion), then remove the record best-effort. A failure in the final
            /// removal leaves a confirmed record that reconciliation still accepts.
            func finishSettlement() throws {
                try confirmPhase(recorded)
                clearSettlementBestEffort(for: entry.name)
                inFlightAttempts.removeValue(forKey: entry)
            }

            switch Self.statKind(of: directory) {
            case .failure:
                throw PrepareError.publicationUncertain
            case .absent:
                // Pending ENTRY removal landed but was not confirmed: repeat the root barrier.
                do { try confirmEntryRemovalDurability() } catch {
                    throw PrepareError.publicationUncertain
                }
                try finishSettlement()
                return
            case .present:
                break
            }

            let leaseURL = directory.appendingPathComponent(Self.attemptLeaseName)
            let current = leaseOwnerLocked(at: leaseURL)
            if let held = current, held.generation != lease.generation {
                // A successor owns the entry now; our pending transition is obsolete.
                try? fileManager.removeItem(at: settlementURL)
                throw PrepareError.resultStale
            }
            if current == nil {
                switch Self.statKind(of: leaseURL) {
                case .failure:
                    throw PrepareError.publicationUncertain
                case .absent:
                    // Pending LEASE-only removal landed but was not confirmed: repeat the barrier.
                    guard recorded.outcome == .retryableFailure else {
                        throw PrepareError.resultStale
                    }
                    do { try confirmLeaseRemovalDurability() } catch {
                        throw PrepareError.publicationUncertain
                    }
                    try finishSettlement()
                    return
                case .present:
                    throw PrepareError.resultStale
                }
            }

            // The lease is live and ours: apply the recorded outcome.
            switch outcome {
            case .delivered, .abandoned:
                do {
                    try fileManager.removeItem(at: directory)
                    try confirmEntryRemovalDurability()
                } catch {
                    throw PrepareError.publicationUncertain
                }
                try finishSettlement()
            case .retryableFailure:
                do {
                    try fileManager.removeItem(at: leaseURL)
                    try confirmLeaseRemovalDurability()
                } catch {
                    throw PrepareError.publicationUncertain
                }
                try finishSettlement()
            }
        }
    }

    /// Whether the given owner token still holds the lease. A stale completion must check this
    /// before reporting a result: elapsed time alone does not prove the old writer died.
    func stillOwns(_ entry: Entry, lease: AttemptLease?) -> Bool {
        serialQueue.sync {
            guard let lease, let current = leaseOwnerLocked(
                at: entryDirectoryLocked(for: entry).appendingPathComponent(Self.attemptLeaseName))
            else { return false }
            return current.generation == lease.generation
        }
    }

    /// Releases single-request ownership. Does NOT remove the durable record: the attempt is spent.
    /// Releases single-request ownership. Only the CURRENT owner's release deletes the lease; a
    /// stale owner (whose lease was reclaimed after expiry) must not delete its successor's.
    func endAttempt(_ entry: Entry) {
        serialQueue.sync {
            let lease = inFlightAttempts.removeValue(forKey: entry)
            releaseLeaseLocked(for: entry, owner: lease)
        }
    }

    /// Records an attempt without taking ownership. Prefer `beginAttempt`, which does both atomically.
    func recordAttempt(_ entry: Entry) throws {
        try serialQueue.sync { try recordAttemptLocked(entry) }
    }

    /// `Entry.root` is the QUEUE root, not the entry's own directory. The attempt record must live
    /// inside the entry directory; at the queue root recovery would (correctly) delete it as a stray.
    private func attemptRecordURL(for entry: Entry) -> URL {
        entryDirectoryLocked(for: entry).appendingPathComponent(Self.attemptRecordName)
    }

    /// Reads the durable attempt count.
    ///
    /// Only a CONFIRMED ABSENCE means zero. A missing file is absence; an unreadable, oversized,
    /// malformed or negative record is NOT — treating those as zero would silently reset the retry
    /// budget and let an entry retry forever. They throw instead, so the caller must refuse.
    private func attemptCountLocked(for entry: Entry) throws -> Int {
        let directory = try validatedEntryDirectoryLocked(entry)
        let url = directory.appendingPathComponent(Self.attemptRecordName)
        // `fileExists` returns false for MANY failures, not just absence. Only ENOENT means "no
        // attempts yet"; any other error is unreadable storage and must refuse, otherwise a
        // permission fault would reset the retry budget.
        switch VoiceSharingUploadQueue.statKind(of: url) {
        case .absent:
            return 0
        case .failure:
            throw PrepareError.accountingUnavailable
        case .present:
            break
        }
        guard let size = fileSizeIfRegularLocked(at: url), size.isRegular,
              size.bytes > 0, size.bytes <= Self.maxAttemptRecordBytes
        else { throw PrepareError.accountingUnavailable }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict.count == 1,
              let value = dict["attempts"] as? Int,
              value >= 0, value <= Self.maxUploadAttemptsCeiling
        else { throw PrepareError.accountingUnavailable }
        return value
    }

    /// An entry may only be attempted when it is COMPLETE and READY. Attempting an entry mid-
    /// preparation would upload a record that does not exist yet, and would spend one of its
    /// attempts on a state the spec never permits to be exposed.
    private func isAttemptableLocked(_ entry: Entry) throws -> Bool {
        // Validate the handle FIRST: a foreign or malformed Entry is an error, not a "not ready"
        // answer, and its absence must never be reported as a benign false.
        _ = try validatedEntryDirectoryLocked(entry)
        guard isCompleteEntryLocked(at: entry) else { return false }
        return try attemptCountLocked(for: entry) < attemptLimits.maxUploadAttempts
    }

    /// Writes the attempt record and confirms its durability. Returns only after the record and its
    /// containing directory have been synchronized, so a crash cannot lose a counted attempt and let
    /// the entry be retried past its budget. Ambiguous persistence surfaces as `.publicationUncertain`
    /// for the attempt rather than permitting an uncounted request.
    private func recordAttemptLocked(_ entry: Entry) throws {
        let directory = try validatedEntryDirectoryLocked(entry)
        // Read-increment-write is a lost-update race across instances: two could read the same
        // count and both write the same "next", spending one attempt for two requests. The whole
        // transition serializes under the SAME per-entry flock the lease uses.
        let lock = try LeaseLock(entryName: entry.name, rootDirectory: rootDirectory)
        defer { lock.close() }
        try lock.lockExclusive()
        let current = try attemptCountLocked(for: entry)
        // Every increment path enforces the limit, not only `beginAttempt`.
        guard current < attemptLimits.maxUploadAttempts else {
            throw PrepareError.attemptsExhausted
        }
        let next = current + 1
        // Guard the arithmetic: an increment that cannot be represented is a corrupt record, not a
        // fresh start.
        guard next > current, next <= Self.maxUploadAttemptsCeiling else {
            throw PrepareError.accountingUnavailable
        }
        let url = directory.appendingPathComponent(Self.attemptRecordName)
        let data = try JSONSerialization.data(
            withJSONObject: ["attempts": next], options: [.sortedKeys])
        guard data.count <= Self.maxAttemptRecordBytes else {
            throw PrepareError.accountingUnavailable
        }
        do {
            try data.write(to: url, options: [.atomic])
            try synchronizer(url, false)
            try synchronizer(directory, true)
        } catch {
            // The write may or may not have landed. Do not hand out a request whose attempt is not
            // known to be counted.
            throw PrepareError.publicationUncertain
        }
    }

    /// Acquires the durable attempt lease. Succeeds when there is no lease, or when the existing one
    /// has EXPIRED (its owner died and cannot renew). Records `acquiredAt` so expiry is decided from
    /// durable state, not from this process's memory.
    private func acquireLeaseLocked(for entry: Entry) throws -> AttemptLease? {
        let directory = try validatedEntryDirectoryLocked(entry)
        let lease = directory.appendingPathComponent(Self.attemptLeaseName)
        // Serialize the whole read-decide-delete/create transition against other processes. Without
        // this, two expired reclaimers can both read the old generation and the later remover would
        // delete the first reclaimer's successor lease.
        let lock = try LeaseLock(entryName: entry.name, rootDirectory: rootDirectory)
        defer { lock.close() }
        try lock.lockExclusive()
        // Policy decision first (absent or expired), then an EXCLUSIVE OS CLAIM. `stat` then
        // `write` is check-then-act: two instances can both observe absence and both replace the
        // file. `O_CREAT|O_EXCL` is the atomic primitive — exactly one caller creates the file.
        if case .present = Self.statKind(of: lease) {
            guard let existing = leaseOwnerLocked(at: lease) else {
                // A lease we cannot parse cannot be safely stolen or trusted.
                throw PrepareError.accountingUnavailable
            }
            guard clock().timeIntervalSince(existing.acquiredAt) > Self.attemptLeaseDuration else {
                return nil
            }
            // Expired: remove the dead lease, but ONLY if it is still the same generation. If
            // another instance reclaimed it first, our removal must not delete their new lease.
            guard reclaimExpiredLeaseLocked(lease, expected: existing.generation) else {
                return nil
            }
        }
        return try claimLeaseLocked(at: lease, directory: directory)
    }

    /// Creates the lease with `O_CREAT|O_EXCL`, so only ONE caller can succeed even under a
    /// simultaneous race. Records a fresh owner token: identity, not elapsed time, is what fences.
    private func claimLeaseLocked(at lease: URL, directory: URL) throws -> AttemptLease {
        let token = AttemptLease(
            generation: UUID().uuidString,
            acquiredAt: clock(),
            owner: ProcessInfo.processInfo.processIdentifier)
        let payload = try JSONSerialization.data(
            withJSONObject: token.jsonObject, options: [.sortedKeys])
        let fd = lease.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        }
        guard fd >= 0 else {
            // `EEXIST` means someone else claimed it first: a refusal, not a failure.
            if errno == EEXIST { throw PrepareError.leaseHeld }
            throw PrepareError.publicationUncertain
        }
        do {
            let written = payload.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return write(fd, base, buffer.count)
            }
            close(fd)
            guard written == payload.count else { throw PrepareError.publicationUncertain }
            // An unconfirmed lease is not an owned lease.
            try synchronizer(lease, false)
            try synchronizer(directory, true)
        } catch {
            try? fileManager.removeItem(at: lease)
            throw PrepareError.publicationUncertain
        }
        return token
    }

    /// Removes an expired lease only when its generation still matches, so a concurrent reclaim
    /// cannot cause us to delete a successor's lease.
    private func reclaimExpiredLeaseLocked(_ lease: URL, expected: String) -> Bool {
        guard let current = leaseOwnerLocked(at: lease), current.generation == expected else {
            return false
        }
        return (try? fileManager.removeItem(at: lease)) != nil
    }

    /// Reads the lease owner token, bounded in size. Absence returns nil.
    private func leaseOwnerLocked(at lease: URL) -> AttemptLease? {
        guard case .present = Self.statKind(of: lease) else { return nil }
        guard let size = fileSizeIfRegularLocked(at: lease), size.isRegular,
              size.bytes > 0, size.bytes <= Self.maxAttemptLeaseBytes
        else { return nil }
        guard let data = try? Data(contentsOf: lease),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let token = AttemptLease(jsonObject: dict)
        else { return nil }
        return token
    }

    /// Fences a stale owner. A release from an owner that no longer holds the lease must not delete
    /// the successor's lease, and a stale completion must not be treated as current.
    private func releaseLeaseLocked(for entry: Entry, owner: AttemptLease?) {
        let directory = entryDirectoryLocked(for: entry)
        let lease = directory.appendingPathComponent(Self.attemptLeaseName)
        // An exact NONNIL owned token is required. A nil owner (an instance that never acquired)
        // must not remove whatever lease exists — that could delete another owner's lease. An
        // unknown or unreadable current identity is also refused: trust nothing we cannot confirm.
        guard let owner else { return }
        let lock = try? LeaseLock(entryName: entry.name, rootDirectory: rootDirectory)
        lock?.closeAfter { [self] in
            guard let current = leaseOwnerLocked(at: lease) else { return }
            guard current.generation == owner.generation else { return }
            try? fileManager.removeItem(at: lease)
            try? synchronizer(directory, true)
        }
    }

    /// Exclusive advisory lock over a STABLE per-entry file at the QUEUE ROOT. `flock(LOCK_EX)`
    /// serializes claim/reclaim/release across instances and processes.
    ///
    /// The file lives at the ROOT, not inside the entry directory: recovery and exhaustion remove
    /// entry directories whole, which would destroy the lock file and its inode — a re-created file
    /// is a different inode, and two instances would then lock different locks. The root scan in
    /// `recoverLocked` skips well-formed lock files for exactly this reason.
    ///
    /// The descriptor is opened once with a single `open(O_CREAT|O_RDWR)` (no exists-check race)
    /// and closed EXACTLY once: `close()` invalidates the stored descriptor, so `defer`/`closeAfter`
    /// and `deinit` cannot double-close — a reused descriptor number could otherwise close an
    /// unrelated file or socket.
    final class LeaseLock {
        private var fd: Int32

        init(entryName: String, rootDirectory: URL) throws {
            let url = rootDirectory.appendingPathComponent(
                VoiceSharingUploadQueue.rootLeaseLockName(for: entryName))
            fd = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return -1 }
                return open(path, O_CREAT | O_RDWR, 0o600)
            }
            guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        }

        /// Test-only non-blocking acquisition.
        func tryLockForTesting() throws {
            guard fd >= 0, !locked else { return }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileReadUnknown) }
            locked = true
        }

        func lockExclusive() throws {
            guard fd >= 0, !locked else {
                if locked { return }
                throw CocoaError(.fileReadUnknown)
            }
            guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileReadUnknown) }
            locked = true
        }

        /// Runs `body` under the exclusive lock, then releases and closes.
        func closeAfter(_ body: () -> Void) {
            do { try lockExclusive() } catch { close(); return }
            body()
            close()
        }

        func close() {
            let descriptor = fd
            fd = -1
            if locked { flock(descriptor, LOCK_UN) }
            locked = false
            if descriptor >= 0 { Darwin.close(descriptor) }
        }

        private var locked = false
        deinit { close() }
    }

    /// Releases the lease. Best-effort: an unreleased lease still expires, so a failure here costs a
    /// delay, not a permanently blocked entry.
    private func releaseLeaseLocked(for entry: Entry) {
        let directory = entryDirectoryLocked(for: entry)
        try? fileManager.removeItem(at: directory.appendingPathComponent(Self.attemptLeaseName))
        try? synchronizer(directory, true)
    }

    /// Reads a lease's acquisition instant, bounded in size.
    private func leaseInstantLocked(at url: URL) -> Date? {
        guard let size = fileSizeIfRegularLocked(at: url), size.isRegular,
              size.bytes > 0, size.bytes <= Self.maxAttemptLeaseBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let seconds = TimeInterval(text), seconds.isFinite, seconds > 0
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Test-only: acquires a lease and returns its owner token, so a control can later assert that
    /// a reclaimed lease is no longer owned by this token.
    func beginLeaseForTesting(_ entry: Entry) throws -> AttemptLease? {
        try serialQueue.sync {
            guard inFlightAttempts[entry] == nil else { return inFlightAttempts[entry] }
            let lease = try acquireLeaseLocked(for: entry)
            if let lease { inFlightAttempts[entry] = lease }
            return lease
        }
    }

    /// Test-only: tightens the budget of an existing instance. A second instance cannot be used to
    /// simulate consumed capacity because its construction runs recovery, which removes entries that
    /// are still preparing.
    func setAggregateLimitsForTesting(_ limits: AggregateLimits) {
        serialQueue.sync { aggregateLimits = limits }
    }

    // MARK: Publication reconciliation

    /// Re-establishes the full durability barrier for an entry that already has a marker. Used by
    /// reconciliation and by recovery: an entry is only exposed as ready once this succeeds.
    /// Throws when durability cannot be confirmed, which the caller maps to an uncertain outcome.
    private func confirmDurableLocked(directory: URL) throws {
        try synchronizer(directory.appendingPathComponent(Self.audioName), false)
        try synchronizer(directory.appendingPathComponent(Self.metadataName), false)
        try synchronizer(directory.appendingPathComponent(Self.createdName), false)
        try synchronizer(directory, true)
        try synchronizer(directory.appendingPathComponent(Self.readyMarkerName), false)
        try synchronizer(directory, true)
        try synchronizer(rootDirectory, true)
    }

    /// Reconciles an entry whose publication outcome is uncertain, under the SAME serialized owner
    /// that attempts publication. The spec requires this before any attempt, and requires the same
    /// rules on a fresh instance.
    ///
    /// The decision is made from durable state only, so it is identical in this process and after a
    /// restart:
    ///   * the immutable record must bind completely (canonical digest, WAV/audio binding, shape);
    ///   * the entry must be within its age and resource bounds;
    ///   * a marker whose namespace could not be confirmed is NOT trusted merely because it exists.
    ///
    /// A `stage.publishing` record means the transition was interrupted before it could be
    /// confirmed, so the entry is unavailable and removed by bounded cleanup. Otherwise an intact,
    /// fully validated entry is confirmed.
    @discardableResult
    func reconcilePublication(_ entry: Entry) -> PublicationOutcome {
        serialQueue.sync {
            let directory = entryDirectoryLocked(for: entry)
            guard fileManager.fileExists(atPath: directory.path) else { return .uncommitted }
            let marker = directory.appendingPathComponent(Self.readyMarkerName)
            let failed = directory.appendingPathComponent(Self.failedName)
            if fileManager.fileExists(atPath: failed.path) { return .uncommitted }
            guard fileManager.fileExists(atPath: marker.path) else { return .uncommitted }
            // Fully validate before exposing: the entry must still be the immutable record it claims
            // to be, within bounds. Anything less is not a confirmable publication.
            guard boundEntryLocked(at: entry) != nil else { return .uncommitted }
            // PRESENCE IS NOT CONFIRMATION. After an uncertain transition the marker may be visible
            // while its durability was never established, so reconciliation must re-establish the
            // same barrier: contents, the marker's own durability, its directory entry and the root
            // link. If that cannot be confirmed the entry stays withheld as uncertain.
            guard (try? confirmDurableLocked(directory: directory)) != nil else { return .uncertain }
            return .committed
        }
    }

    // MARK: Listing and access

    /// All complete, ready entries within the queue-age bound, in finalize order (marker mtime;
    /// name as the deterministic tiebreak).
    /// Clarification 7e9606b: discovery covers disposal/disqualification intents as well as
    /// audio/metadata, and UNKNOWN coverage must HOLD serving, not read as "nothing ready".
    /// This tri-state result distinguishes a genuinely empty queue from a root that could not be
    /// scanned: callers that cannot handle `.unknownCoverage` must not serve.
    enum ReadyDiscovery {
        case known([Entry])
        case unknownCoverage
    }

    /// THE strict owner-wide coverage authority: root listing, every entry's required state, AND
    /// every ready entry's durability confirmation must be KNOWN. Serving queries and attempt
    /// gates share this one implementation so neither can hold a weaker standard than the other.
    private func strictOwnerCoverageLocked() throws -> [Entry] {
        let all = try entriesStrictLocked()
        for entry in all {
            let state = try entryStateLocked(at: entry)
            // Reviewer 72e9362d: an unconfirmable READY marker is UNKNOWN coverage for the whole
            // owner — the attempt gate must hold exactly where the serving query holds. Entries
            // still being prepared (incomplete, no marker) are known-incomplete; durability
            // confirmation does not apply to them.
            if case .bound = state {
                try confirmDurableLocked(directory: entryDirectoryLocked(for: entry))
            }
        }
        return all
    }

    func readyEntriesReportingUnknownCoverage() -> ReadyDiscovery {
        serialQueue.sync {
            // Reviewer c4d5ecb4: coverage is ALL-OR-NOTHING for the owner. Any required check
            // whose outcome is UNKNOWN (listing failure, required-stat failure, required-file
            // read failure, unconfirmable durability) holds serving for the WHOLE root — one
            // inaccessible entry must not coexist with `.known(others)`.
            let all: [Entry]
            do { all = try strictOwnerCoverageLocked() } catch { return .unknownCoverage }
            var ready: [Entry] = []
            for entry in all {
                let state: EntryState
                do { state = try entryStateLocked(at: entry) } catch {
                    return .unknownCoverage
                }
                guard case .bound = state else { continue }
                // CONFIRMED durability was verified by strictOwnerCoverageLocked (part of the
                // shared authority); reaching here means it held.
                if Date().timeIntervalSince(modificationDateLocked(of: entryDirectoryLocked(for: entry).appendingPathComponent(Self.readyMarkerName))) <= Self.maxEntryAge {
                    ready.append(entry)
                }
            }
            return .known(ready.sorted { lhs, rhs in
                let lDate = modificationDateLocked(of: rootDirectory.appendingPathComponent(lhs.name))
                let rDate = modificationDateLocked(of: rootDirectory.appendingPathComponent(rhs.name))
                if lDate == rDate { return lhs.name < rhs.name }
                return lDate < rDate
            })
        }
    }

    func readyEntries() -> [Entry] {
        serialQueue.sync {
            entriesLocked()
                .filter { isCompleteEntryLocked(at: $0) }
                // Exposure also requires CONFIRMED durability, not just a structurally valid marker:
                // after an uncertain transition a marker may be visible without durable backing.
                .filter { (try? self.confirmDurableLocked(directory: self.entryDirectoryLocked(for: $0))) != nil }
                .filter { Date().timeIntervalSince(modificationDateLocked(of: entryDirectoryLocked(for: $0).appendingPathComponent(Self.readyMarkerName))) <= Self.maxEntryAge }
                .sorted { lhs, rhs in
                    let lDate = modificationDateLocked(of: rootDirectory.appendingPathComponent(lhs.name))
                    let rDate = modificationDateLocked(of: rootDirectory.appendingPathComponent(rhs.name))
                    if lDate == rDate { return lhs.name < rhs.name }
                    return lDate < rDate
                }
        }
    }

    func metadata(of entry: Entry) throws -> Data {
        try serialQueue.sync {
            try Data(contentsOf: try validatedEntryDirectoryLocked(entry).appendingPathComponent(Self.metadataName))
        }
    }

    func audio(of entry: Entry) throws -> Data {
        try serialQueue.sync {
            try Data(contentsOf: try validatedEntryDirectoryLocked(entry).appendingPathComponent(Self.audioName))
        }
    }

    /// Deletes the entire entry: audio, metadata and marker leave the disk.
    func remove(_ entry: Entry) throws {
        try serialQueue.sync {
            _ = try validatedEntryDirectoryLocked(entry)
            try fileManager.removeItem(at: entryDirectoryLocked(for: entry))
        }
    }

    // MARK: Internals (all called on serialQueue)

    private func entryDirectoryLocked(for entry: Entry) -> URL {
        rootDirectory.appendingPathComponent(entry.name, isDirectory: true)
    }

    /// A handle is honored only if it names a directory directly under THIS queue's root and its
    /// name is a single path component this queue could have minted.
    private func validatedEntryDirectoryLocked(_ entry: Entry) throws -> URL {
        guard entry.root == rootDirectory,
            UUID(uuidString: entry.name) != nil, // names this queue could have minted (uppercase UUID)
            !entry.name.contains("/")
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = entryDirectoryLocked(for: entry)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        return directory
    }

    /// Actual bytes and records currently stored, read from disk. Any file inside an entry
    /// directory counts, not just audio/metadata: a partial or stray file still consumes storage and
    /// the budget must account for it or the bound is fictional.
    /// Throws when usage cannot be determined. "Unknown" must never be treated as "free": a queue
    /// that cannot read its own storage is not trusted to admit more of it.
    private func storedUsageLocked() throws -> (bytes: Int, records: Int) {
        var bytes = 0
        var records = 0
        for entry in try entriesStrictLocked() {
            let directory = entryDirectoryLocked(for: entry)
            bytes += try chargeLocked(for: entry)
            records += 1
        }
        return (bytes, records)
    }

    /// The queue's OWNED on-disk format for one entry directory: a FLAT set of regular files drawn
    /// from a closed set of names. Accounting is therefore bounded by `knownNames.count` stat calls
    /// per entry, not by whatever happens to be in the directory.
    ///
    /// Anything else — nested directories, unknown files, symlinks — is outside the owned format and
    /// makes the footprint unknowable. That is a refusal, not an invitation to enumerate: an
    /// attacker-controlled or debris directory must not be able to inflate or hide usage.
    /// Charge that keeps the reservation HONEST for entries not yet published. A preparing entry has
    /// been admitted but will still grow (stage, marker) before it is published, and an uncertain one
    /// may be rewritten. Charging only its current footprint would let later admissions consume the
    /// headroom those entries still need, and a later finalize would then exceed the cap that
    /// admitted the newer entries. So an unpublished entry is charged its full bounded footprint.
    private func chargeLocked(for entry: Entry) throws -> Int {
        let directory = entryDirectoryLocked(for: entry)
        let physical = try entryFootprintLocked(at: directory)
        // EVERY entry holds the protocol headroom, published or not. A published entry can still be
        // finalized again, and each attempt may leave a temporary behind, so "already published"
        // does not mean "will not grow". Charging only physical bytes once a marker exists would let
        // another admission consume the space a later finalize needs.
        return physical + Self.protocolOverheadBytes
    }

    /// Removes this queue's own leftover `ready.marker.tmp-<UUID>` files.
    ///
    /// NOT bounded by a fixed name set: the UUID suffix permits arbitrarily many such names, so a
    /// bounded number of files can become an unbounded number of temporary names. Cleanup therefore
    /// operates under an explicit entry budget (below) and fails closed when it is exceeded, rather
    /// than claiming a bound it does not have.
    private func cleanupTemporaryMarkersLocked(in directory: URL) {
        // Bounded discovery of our own temporaries. If the directory overflows the cap we simply do
        // not clean: the files stay on disk, so they stay CHARGED by accounting, which is the
        // fail-closed direction. Cleanup never makes usage look smaller than it is.
        guard let listed = try? listDirectoryBounded(directory, [], Self.maxDirectoryEntries),
              !listed.overflowed else { return }
        for file in listed.urls {
            let name = file.lastPathComponent
            guard name.hasPrefix(Self.temporaryMarkerPrefix),
                  UUID(uuidString: String(name.dropFirst(Self.temporaryMarkerPrefix.count))) != nil
            else { continue }
            // A failed removal leaves the file in place, so its charge persists: correct, because the
            // bytes are still there. Never treat a failed cleanup as reclaimed space.
            try? fileManager.removeItem(at: file)
        }
    }

    /// Physical bytes of one entry directory, restricted to the owned format.
    private func entryFootprintLocked(at directory: URL) throws -> Int {
        // A read failure is UNKNOWABLE usage, not zero usage: surface it as the refusal case so the
        // caller cannot mistake "could not read" for "nothing stored".
        let contents: [URL]
        do {
            let listed = try listDirectoryBounded(
                directory, [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                Self.maxDirectoryEntries)
            guard !listed.overflowed else { throw PrepareError.accountingUnavailable }
            contents = listed.urls
        } catch {
            throw PrepareError.accountingUnavailable
        }
        var bytes = 0
        for file in contents {
            let name = file.lastPathComponent
            let isOwnedTemporary = name.hasPrefix(Self.temporaryMarkerPrefix)
                && UUID(uuidString: String(name.dropFirst(Self.temporaryMarkerPrefix.count))) != nil
            guard Self.knownEntryNames.contains(name) || isOwnedTemporary else {
                throw PrepareError.accountingUnavailable
            }
            let values: URLResourceValues
            do {
                values = try file.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            } catch {
                throw PrepareError.accountingUnavailable
            }
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  let size = values.fileSize, size >= 0 else {
                throw PrepareError.accountingUnavailable
            }
            bytes += size
        }
        return bytes
    }

    private func countEntriesLocked() -> Int {
        entriesLocked().count
    }

    private func entriesLocked() -> [Entry] {
        // Lenient variant for read paths that must not fail (recovery, listing). Accounting must NOT
        // use this: an unreadable root would then look like an empty queue.
        (try? entriesStrictLocked()) ?? []
    }

    /// Enumerates entry directories and PROPAGATES a root listing failure. Used by accounting: an
    /// unreadable root must refuse admission, never read as "nothing stored".
    private func entriesStrictLocked() throws -> [Entry] {
        let contents: [URL]
        do {
            // Bounded discovery: a root with more names than the cap cannot be accounted, so it is a
            // refusal. Checking a cap after an eager listing would not bound allocation.
            let listed = try listDirectoryBounded(rootDirectory, [], Self.maxDirectoryEntries)
            guard !listed.overflowed else { throw PrepareError.accountingUnavailable }
            contents = listed.urls
        } catch {
            throw PrepareError.accountingUnavailable
        }
        return contents
            .filter { $0.hasDirectoryPath }
            .map { Entry(root: rootDirectory, name: $0.lastPathComponent) }
    }

    /// The immutable admission instant recorded at prepare, or nil when absent/unparseable.
    ///
    /// Bounded read: the instant is a short decimal string, so an oversized file is a corrupt or
    /// foreign object, not a large time. Size is checked from attributes BEFORE the content is
    /// loaded, so a huge file cannot be read into memory to discover it is not a timestamp.
    private func creationInstantLocked(in directory: URL) -> Date? {
        let url = directory.appendingPathComponent(Self.createdName)
        guard let size = fileSizeIfRegularLocked(at: url),
            size.isRegular, size.bytes > 0, size.bytes <= Self.maxCreationInstantBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8),
            let seconds = TimeInterval(text), seconds.isFinite
        else { return nil }
        // BOTH representations must be present: an entry without its immutable instant cannot have
        // its lifetime bounded, so it is incomplete rather than "fresh".
        return Date(timeIntervalSince1970: seconds)
    }

    /// Complete-entry validation, FAIL-CLOSED, STAT-FIRST and BOUND:
    ///   * sizes and file kinds from attributes BEFORE any content is loaded;
    ///   * a recorded publication failure disqualifies the entry outright;
    ///   * the age bound uses the IMMUTABLE creation instant, never the marker's mtime;
    ///   * readiness requires the persisted envelope to BIND to the audio bytes through the shared
    ///     record/WAV authority (canonical record digest, capture/epoch identity, real PCM16 mono
    ///     16 kHz header) — not merely a matching digest field.
    // No in-process quarantine state exists. It cannot stand as evidence of non-publication: an
    // instance that remembers "I did not publish this" can disagree with a fresh instance that sees
    // the same durable state, and the contract requires both to agree. Ambiguity is therefore
    // expressed by `uncertainEntriesLocked` (a hint only) and resolved from disk.

    /// Reviewer c4d5ecb4: `fileExists`/`try?` collapse I/O failure into absence, so one
    /// inaccessible entry could coexist with `.known(otherEntries)`. The strict state read
    /// distinguishes: REQUIRED-check failure (unknown) throws; genuine absence or a durable
    /// disqualifier classifies the entry.
    private enum EntryState {
        case bound(VoiceSharingRecordBinding.BoundEntry)
        case disqualified
        case incomplete

        var flatBound: VoiceSharingRecordBinding.BoundEntry? {
            if case .bound(let b) = self { return b }
            return nil
        }
    }

    private func entryStateLocked(at entry: Entry) throws -> EntryState {
        let directory = entryDirectoryLocked(for: entry)
        let marker = directory.appendingPathComponent(Self.readyMarkerName)
        let audioURL = directory.appendingPathComponent(Self.audioName)
        let metadataURL = directory.appendingPathComponent(Self.metadataName)

        func requiredFileKind(_ url: URL) throws -> StatKind {
            switch Self.statKind(of: url) {
            case .failure: throw PrepareError.accountingUnavailable
            case .absent: return .absent
            case .present: return .present
            }
        }
        func readIfPresent(_ url: URL) throws -> Data? {
            // Absent => nil (classified by the caller); present-but-unreadable => UNKNOWN.
            guard try requiredFileKind(url) == .present else { return nil }
            guard let data = try? Data(contentsOf: url) else {
                throw PrepareError.accountingUnavailable
            }
            return data
        }

        // Disposal/disqualification intents are DURABLE state: present => disqualified;
        // stat failure => unknown coverage (never "absent" by collapse).
        if try requiredFileKind(directory.appendingPathComponent(Self.failedName)) == .present {
            return .disqualified
        }
        // A recorded publication stage means publication began. Until the marker is confirmed and
        // the stage cleared, the entry is not trustworthy — this is the discriminator that makes
        // "marker present with no disqualifier" unreachable for a restart.
        if try requiredFileKind(directory.appendingPathComponent(Self.stageName)) == .present {
            return .disqualified
        }
        guard try requiredFileKind(marker) == .present else { return .incomplete }
        // The immutable instant bounds the entry's lifetime, so its read keeps the ORIGINAL
        // bounded-reader discipline (regular file, 1..maxCreationInstantBytes) while still
        // distinguishing absence (incomplete) from stat/read failure (UNKNOWN). A huge or
        // special created-at file must be refused BEFORE allocation, never loaded.
        let createdURL = directory.appendingPathComponent(Self.createdName)
        switch try requiredFileKind(createdURL) {
        case .absent: return .incomplete
        case .failure: throw PrepareError.accountingUnavailable
        case .present: break
        }
        guard let createdSize = fileSizeIfRegularLocked(at: createdURL),
            createdSize.isRegular, createdSize.bytes > 0,
            createdSize.bytes <= Self.maxCreationInstantBytes else {
            throw PrepareError.accountingUnavailable
        }
        // Reviewer 72e9362d: the READ is throwing — a present, bounded file whose read fails is
        // UNKNOWN coverage, never .incomplete. Only content PARSING failure classifies.
        let createdData: Data
        do { createdData = try Data(contentsOf: createdURL) } catch {
            throw PrepareError.accountingUnavailable
        }
        guard let text = String(data: createdData, encoding: .utf8),
            let seconds = TimeInterval(text), seconds.isFinite
        else { return .incomplete }
        let createdAt = Date(timeIntervalSince1970: seconds)
        guard clock().timeIntervalSince(createdAt) <= Self.maxEntryAge else { return .incomplete }

        guard let audioSize = fileSizeIfRegularLocked(at: audioURL), audioSize.isRegular,
            audioSize.bytes > 0, audioSize.bytes <= Self.maxEntryAudioBytes,
            let metadataSize = fileSizeIfRegularLocked(at: metadataURL), metadataSize.isRegular,
            metadataSize.bytes > 0, metadataSize.bytes <= Self.maxMetadataBytes
        else {
            // fileSizeIfRegularLocked returns nil on stat failure: for an entry whose marker is
            // PRESENT, the audio/metadata are required — a stat failure is unknown, not absent.
            let audioKind = try requiredFileKind(audioURL)
            let metadataKind = try requiredFileKind(metadataURL)
            if audioKind == .absent || metadataKind == .absent {
                return .incomplete
            }
            throw PrepareError.accountingUnavailable
        }

        guard let audioData = try readIfPresent(audioURL),
            let metadataData = try readIfPresent(metadataURL),
            let bound = try? VoiceSharingRecordBinding.bind(envelope: metadataData, audio: audioData)
        else { return .incomplete }
        return .bound(bound)
    }

    private func boundEntryLocked(at entry: Entry) -> VoiceSharingRecordBinding.BoundEntry? {
        // Lenient wrapper for cleanup/recovery contexts. Coverage-sensitive callers use
        // entryStateLocked.
        (try? entryStateLocked(at: entry))?.flatBound
    }

    private func isCompleteEntryLocked(at entry: Entry) -> Bool {
        boundEntryLocked(at: entry) != nil
    }

    /// Result of an error-reporting, no-follow stat. Distinguishes "not there" from "could not
    /// tell", which `fileExists` cannot: it collapses every failure into `false`.
    enum StatKind { case present, absent, failure }

    /// Stats `url` without following symlinks and WITHOUT conflating failure with absence. Only an
    /// actual `ENOENT` yields `.absent`.
    static func statKind(of url: URL) -> StatKind {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &info)
        }
        if result == 0 { return .present }
        return errno == ENOENT ? .absent : .failure
    }

    /// (isRegularFile, byte size) via attributes — no content is read.
    private func fileSizeIfRegularLocked(at url: URL) -> (isRegular: Bool, bytes: Int)? {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard let isRegular = values?.isRegularFile, let bytes = values?.fileSize else { return nil }
        return (isRegular, bytes)
    }

    private func modificationDateLocked(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Recovery: anything under the root that is not a complete entry is removed — abandoned
    /// preparation, foreign directories, malformed entries, stray files. The finite limits are
    /// RE-ESTABLISHED here over what survives: entries past the queue-age bound are removed, and
    /// if more than `maxQueueEntries` complete entries remain (e.g. the ceiling was lowered), the
    /// OLDEST are removed until the count is within bounds. Complete ready entries within bounds
    /// are kept byte-for-byte.
    private func recoverLocked() {
        var complete: [(entry: Entry, readyDate: Date)] = []
        for entry in entriesLocked() {
            let directory = entryDirectoryLocked(for: entry)
            // Bounded cleanup of this queue's own stale temporary markers before completeness is
            // judged: a failed replacement can strand one, and leaving it would block admission
            // forever with a name that is ours, not debris.
            cleanupTemporaryMarkersLocked(in: directory)
            guard isCompleteEntryLocked(at: entry) else {
                // Clarification 7e9606b: a disposal/disqualification intent (`publication.failed`)
                // is DISCOVERED STATE, not incompleteness — its cleanup deliberately could not
                // complete. The entry is RETAINED: never served (the binding refuses it), still
                // owned and charged by accounting. Deleting it here would erase the failure
                // evidence and let a fresh scan re-admit the content.
                if fileManager.fileExists(atPath: directory.appendingPathComponent(Self.failedName).path) {
                    continue
                }
                try? fileManager.removeItem(at: directory)
                continue
            }
            // Ordering uses the immutable creation instant; age is already enforced by the
            // completeness check above (which reads the same instant).
            let createdAt = creationInstantLocked(in: directory) ?? .distantPast
            complete.append((entry, createdAt))
        }
        if complete.count > Self.maxQueueEntries {
            for stale in complete.sorted(by: { $0.readyDate < $1.readyDate }).prefix(complete.count - Self.maxQueueEntries) {
                try? fileManager.removeItem(at: entryDirectoryLocked(for: stale.entry))
            }
        }
        // Stray regular files directly under the root are not entries; remove them so the root
        // stays queue-owned. Discovery here is BOUNDED too: construction must not eagerly
        // materialise an oversized root just because recovery tolerates failures. On overflow we
        // skip cleanup (fail-closed) rather than enumerate past the bound.
        if let listed = try? listDirectoryBounded(
            rootDirectory, [.isDirectoryKey], Self.maxDirectoryEntries), !listed.overflowed {
            for stray in listed.urls
            where !((try? stray.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) {
                // Lease locks are OWNED root files, not debris: removing one would invalidate the
                // inode live lock holders rely on. Only well-formed names are skipped; anything
                // else is debris as before.
                let name = stray.lastPathComponent
                if name.hasPrefix("attempt.lock."),
                   let index = Int(name.dropFirst("attempt.lock.".count)),
                   index >= 0, index < Self.leaseLockPoolSize {
                    continue
                }
                // Settlement records are the durable intent a crashed owner (or its successor)
                // still needs to reconcile. Deleting one here would erase the only recovery
                // state. Well-formed names are preserved here; `recoverAbandonedSettlements`
                // reconciles and retires them explicitly.
                if name.hasPrefix(Self.settlementRecordName + "."),
                   name.hasSuffix(".json"),
                   Self.parseSettlementName(name) != nil {
                    continue
                }
                try? fileManager.removeItem(at: stray)
            }
        }
        // Settlement records are recovery state, not debris: reconcile-retire them here.
        recoverAbandonedSettlements()
    }
}
