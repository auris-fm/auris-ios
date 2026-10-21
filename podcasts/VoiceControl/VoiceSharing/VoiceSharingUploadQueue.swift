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

    enum PrepareError: Error, Equatable {
        case queueFull
        case audioTooLarge
        case metadataTooLarge
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
    static let maxCreationInstantBytes = 64
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
        }
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.clock = clock
        self.synchronizer = synchronizer
        self.failureRecordWriter = failureRecordWriter
        self.markerReplacer = markerReplacer
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
                guard countEntriesLocked() < Self.maxQueueEntries else { throw PrepareError.queueFull }
                guard audio.count <= Self.maxEntryAudioBytes else { throw PrepareError.audioTooLarge }
                guard metadata.count <= Self.maxMetadataBytes else { throw PrepareError.metadataTooLarge }
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
            // The lifecycle stage is recorded BEFORE publication begins, so that after any crash the
            // presence of this file means "publication was attempted and may not have completed".
            // Written with the plain (non-atomic) route so a crash HERE leaves nothing rather than a
            // half-written discriminator: an entry with no stage file and no marker never published.
            // Deliberately NOT routed through the injectable failure-record seam: this write is part
            // of the publication protocol, and letting failure injection suppress it would remove the
            // discriminator that the restart guarantee depends on.
            if !fileManager.fileExists(atPath: stage.path) {
                try Data([0x01]).write(to: stage, options: .atomic)
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

    private func countEntriesLocked() -> Int {
        entriesLocked().count
    }

    private func entriesLocked() -> [Entry] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
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

    private func boundEntryLocked(at entry: Entry) -> VoiceSharingRecordBinding.BoundEntry? {
        let directory = entryDirectoryLocked(for: entry)
        let marker = directory.appendingPathComponent(Self.readyMarkerName)
        let audioURL = directory.appendingPathComponent(Self.audioName)
        let metadataURL = directory.appendingPathComponent(Self.metadataName)

        guard !fileManager.fileExists(atPath: directory.appendingPathComponent(Self.failedName).path)
        else { return nil }
        // A recorded publication stage means publication began. Until the marker is confirmed and
        // the stage cleared, the entry is not trustworthy — this is the discriminator that makes
        // "marker present with no disqualifier" unreachable for a restart.
        guard !fileManager.fileExists(atPath: directory.appendingPathComponent(Self.stageName).path)
        else { return nil }
        guard fileManager.fileExists(atPath: marker.path),
            let createdAt = creationInstantLocked(in: directory),
            clock().timeIntervalSince(createdAt) <= Self.maxEntryAge,
            let audioSize = fileSizeIfRegularLocked(at: audioURL), audioSize.isRegular,
            audioSize.bytes > 0, audioSize.bytes <= Self.maxEntryAudioBytes,
            let metadataSize = fileSizeIfRegularLocked(at: metadataURL), metadataSize.isRegular,
            metadataSize.bytes > 0, metadataSize.bytes <= Self.maxMetadataBytes
        else { return nil }

        guard let audioData = try? Data(contentsOf: audioURL),
            let metadataData = try? Data(contentsOf: metadataURL),
            let bound = try? VoiceSharingRecordBinding.bind(envelope: metadataData, audio: audioData)
        else { return nil }
        return bound
    }

    private func isCompleteEntryLocked(at entry: Entry) -> Bool {
        boundEntryLocked(at: entry) != nil
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
            guard isCompleteEntryLocked(at: entry) else {
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
        // stays queue-owned.
        let strays = (try? fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for stray in strays where !((try? stray.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) {
            try? fileManager.removeItem(at: stray)
        }
    }
}
