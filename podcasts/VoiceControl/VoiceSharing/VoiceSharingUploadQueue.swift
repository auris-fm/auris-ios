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
    }

    /// Opaque entry handle. Only names an entry under a root; every accessor validates that the
    /// handle belongs to THIS queue before touching the filesystem.
    struct Entry: Equatable {
        let root: URL
        let name: String
    }

    private static let readyMarkerName = "ready.marker"
    private static let audioName = "audio.wav"
    private static let metadataName = "metadata.json"

    let rootDirectory: URL
    private let fileManager: FileManager
    /// Storage-synchronization seam: fsync-equivalent for a file or directory path. Production
    /// default performs a real sync; controls inject a recorder to pin ordering.
    private let synchronizer: (_ path: URL, _ isDirectory: Bool) throws -> Void
    private let serialQueue = DispatchQueue(label: "fm.auris.voicesharing.uploadqueue")

    /// Creates the queue over `rootDirectory` and runs recovery: entries that are not complete
    /// (including abandoned preparation, foreign directories and malformed entries) are removed;
    /// complete ready entries are kept intact.
    init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        synchronizer: @escaping (_ path: URL, _ isDirectory: Bool) throws -> Void = VoiceSharingUploadQueue.defaultSynchronizer
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.synchronizer = synchronizer
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
            let marker = directory.appendingPathComponent(Self.readyMarkerName)
            // Publication protocol: entry CONTENT must be durable before the marker exists, and
            // the marker's namespace entry must be durable after it is written. A synchronization
            // failure at any stage THROWS and the entry stays unready — durability is never
            // silently assumed.
            try synchronizer(directory.appendingPathComponent(Self.audioName), false)
            try synchronizer(directory.appendingPathComponent(Self.metadataName), false)
            try synchronizer(directory, true)
            let temporary = directory.appendingPathComponent("\(Self.readyMarkerName).tmp-\(UUID().uuidString)")
            try Data([0x01]).write(to: temporary, options: .atomic)
            _ = try fileManager.replaceItemAt(marker, withItemAt: temporary)
            do {
                try synchronizer(marker, false)
                // The marker's directory entry and the queue root link are persisted AFTER
                // publication; a pre-marker directory sync cannot cover namespace changes made
                // later.
                try synchronizer(directory, true)
                try synchronizer(rootDirectory, true)
            } catch {
                // Refuse publication: without durable namespace entries the marker may not be
                // visible after a crash, so the entry must not surface as ready.
                try? fileManager.removeItem(at: marker)
                throw error
            }
        }
    }

    // MARK: Listing and access

    /// All complete, ready entries within the queue-age bound, in finalize order (marker mtime;
    /// name as the deterministic tiebreak).
    func readyEntries() -> [Entry] {
        serialQueue.sync {
            entriesLocked()
                .filter { isCompleteEntryLocked(at: $0) }
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

    /// Complete-entry validation, FAIL-CLOSED and STAT-FIRST: sizes and file kinds are checked
    /// via attributes BEFORE any content is loaded; then the metadata's declared audio digest and
    /// byte count must match the actual bytes. Oversized, irregular, malformed or unbindable
    /// entries are incomplete.
    private func isCompleteEntryLocked(at entry: Entry) -> Bool {
        let directory = entryDirectoryLocked(for: entry)
        let marker = directory.appendingPathComponent(Self.readyMarkerName)
        let audioURL = directory.appendingPathComponent(Self.audioName)
        let metadataURL = directory.appendingPathComponent(Self.metadataName)

        guard fileManager.fileExists(atPath: marker.path),
            let audioSize = fileSizeIfRegularLocked(at: audioURL), audioSize.isRegular, audioSize.bytes > 0, audioSize.bytes <= Self.maxEntryAudioBytes,
            let metadataSize = fileSizeIfRegularLocked(at: metadataURL), metadataSize.isRegular, metadataSize.bytes > 0, metadataSize.bytes <= Self.maxMetadataBytes
        else { return false }

        // Sizes are within bounds; only now is content loaded.
        guard let audioData = try? Data(contentsOf: audioURL),
            let metadataData = try? Data(contentsOf: metadataURL),
            let declared = declaredAudioFactsLocked(from: metadataData)
        else { return false }

        let digest = SHA256.hash(data: audioData).map { String(format: "%02x", $0) }.joined()
        return digest == declared.digest && audioData.count == declared.byteCount
    }

    /// (isRegularFile, byte size) via attributes — no content is read.
    private func fileSizeIfRegularLocked(at url: URL) -> (isRegular: Bool, bytes: Int)? {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard let isRegular = values?.isRegularFile, let bytes = values?.fileSize else { return nil }
        return (isRegular, bytes)
    }

    /// Extracts `audio.sha256` and `audio.byte_count` from the metadata envelope. Missing or
    /// malformed declarations make the entry incomplete — an undeclarable entry cannot be bound
    /// to its bytes, so it must not survive.
    private func declaredAudioFactsLocked(from metadata: Data) -> (digest: String, byteCount: Int)? {
        guard
            let object = try? JSONSerialization.jsonObject(with: metadata, options: [.fragmentsAllowed]),
            let record = (object as? [String: Any])?["record"] as? [String: Any],
            let audio = record["audio"] as? [String: Any],
            let digest = audio["sha256"] as? String, digest.count == 64,
            let byteCount = audio["byte_count"] as? Int
        else { return nil }
        return (digest, byteCount)
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
            let readyDate = modificationDateLocked(of: directory.appendingPathComponent(Self.readyMarkerName))
            if Date().timeIntervalSince(readyDate) > Self.maxEntryAge {
                try? fileManager.removeItem(at: directory)
                continue
            }
            complete.append((entry, readyDate))
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
