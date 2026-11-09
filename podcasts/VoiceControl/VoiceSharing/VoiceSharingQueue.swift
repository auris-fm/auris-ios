import Foundation

/// The contribution queue: one folder per recording, and nothing else.
///
/// Folders are the only state. There is no index, ledger, ownership lock, recovery pass or counter —
/// each recording is `audio.wav` plus `metadata.json` in its own directory. A recording is written
/// under a temporary name and published with a single rename, so a half-written entry is never
/// visible as ready. Anything still under a temporary name at startup is deleted.
///
/// The queue is deliberately small and boring: its job is to hold bytes that the uploader will offer,
/// and to delete them on exactly the conditions the spec lists — never to decide questions of its own.
final class VoiceSharingQueue {

    /// At most 32 recordings. The spec's only queue limit.
    static let capacity = 32

    /// Recordings older than this are deleted without sending.
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    /// The same bound under the name the retention controls use.
    static var maxEntryAge: TimeInterval { maximumAge }

    /// Prefixes for the two temporary shapes; both are removed at startup.
    private static let writingPrefix = ".writing-"
    private static let stagedMetadata = ".metadata-"
    /// The recording's creation instant, written with the folder and published by the same rename.
    private static let creationFile = "created.at"

    private let root: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let log: (String) -> Void

    /// Entries currently in their backoff window. Kept in memory only: a restart simply tries again,
    /// which is what the spec asks for and removes the durable not-before bookkeeping entirely.
    private var retryAfter: [String: Date] = [:]

    init(
        root: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.root = root
        self.fileManager = fileManager
        self.now = now
        self.log = log
    }

    /// The production queue location, beside the app's other application support data.
    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VoiceContributions", isDirectory: true)
    }

    // MARK: Publication

    /// Publishes one recording. Returns the entry name on success, `nil` when the queue is full or the
    /// write failed — in both cases the recording is dropped and the drop logged, per the spec.
    ///
    /// The caller supplies already-encoded bytes; the queue never invents or validates content beyond
    /// what it needs to write a folder atomically.
    @discardableResult
    func publish(audio: Data, metadata: Data, name: String = UUID().uuidString) -> String? {
        createRootIfNeeded()
        removeTemporaryEntries()

        guard count() < Self.capacity else {
            log("drop reason=queue-full name=\(name)")
            return nil
        }

        let staging = root.appendingPathComponent(Self.writingPrefix + name, isDirectory: true)
        let final = root.appendingPathComponent(name, isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try audio.write(to: staging.appendingPathComponent("audio.wav"), options: .atomic)
            // Metadata goes in last and under its own temporary name: its rename is the publish.
            let stagedMetadataURL = staging.appendingPathComponent(Self.stagedMetadata + "metadata.json")
            try metadata.write(to: stagedMetadataURL, options: .atomic)
            try fileManager.moveItem(at: stagedMetadataURL,
                                     to: staging.appendingPathComponent("metadata.json"))
            // The recording's age is stamped by the queue's own clock, so the bound is measured
            // against the same time source every read uses rather than the file system's.
            try String(Self.creationStamp(for: now())).write(
                to: staging.appendingPathComponent(Self.creationFile),
                atomically: true, encoding: .utf8)
            // ONE rename publishes the whole folder.
            try fileManager.moveItem(at: staging, to: final)
            return name
        } catch {
            log("drop reason=write-failed name=\(name)")
            try? fileManager.removeItem(at: staging)
            return nil
        }
    }

    // MARK: Inspection

    /// Every published recording, oldest first by creation date.
    func entries() -> [Entry] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .compactMap { name -> Entry? in
                let url = root.appendingPathComponent(name, isDirectory: true)
                guard let created = creationDate(of: url) else { return nil }
                return Entry(name: name, url: url, createdAt: created)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func count() -> Int { entries().count }

    /// Whether the queue folder can be read at all. A count alone cannot tell "no recordings" from
    /// "could not look", and the surface must not report an unreadable device as an empty one.
    var isReadable: Bool {
        (try? fileManager.contentsOfDirectory(atPath: root.path)) != nil
    }

    /// Seconds until the OLDEST recording expires, or nil when nothing is retained. The surface
    /// arms one timer from this so the age bound is observed without polling.
    func secondsUntilNextAgeBoundary() -> TimeInterval? {
        guard let oldest = entries().map(\.createdAt).min() else { return nil }
        return max(0, VoiceSharingQueue.maximumAge + oldest.timeIntervalSince(now()))
    }

    /// Entries the uploader may offer now: not expired, not inside a backoff window.
    ///
    /// Expired recordings are not returned because they are deleted, which is a different action from
    /// being skipped — the caller must be able to tell "nothing to do" from "this was removed".
    func dueEntries() -> [Entry] {
        let cutoff = now().addingTimeInterval(-Self.maximumAge)
        let current = now()
        var due: [Entry] = []
        for entry in entries() {
            if entry.createdAt < cutoff {
                delete(entry, reason: "expired")
                continue
            }
            if let until = retryAfter[entry.name], until > current { continue }
            due.append(entry)
        }
        return due
    }

    // MARK: Deletion

    /// Deletes one recording. Every call logs its reason; the spec's list of reasons is exhaustive.
    func delete(_ entry: Entry, reason: String) {
        try? fileManager.removeItem(at: entry.url)
        retryAfter[entry.name] = nil
        log("delete reason=\(reason) name=\(entry.name)")
    }

    /// Deletes every recording, keeping the queue folder itself. Returns how many were removed, so
    /// the caller can report the size of what it purged rather than only that it tried.
    @discardableResult
    func deleteAll(reason: String) -> Int {
        let all = entries()
        for entry in all { delete(entry, reason: reason) }
        return all.count
    }

    /// Records that an entry should not be offered again until `date`. Memory-only by design.
    func deferUntil(_ date: Date, entry: Entry) {
        retryAfter[entry.name] = date
    }

    // MARK: Housekeeping

    /// Removes anything left under a temporary name. Called at startup: a process that died mid-write
    /// leaves only temporary entries, which are never published and so are never valid recordings.
    func removeTemporaryEntries() {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(Self.writingPrefix) {
            try? fileManager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
            log("delete reason=incomplete-write name=\(name)")
        }
    }

    private func createRootIfNeeded() {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func creationDate(of url: URL) -> Date? {
        if let text = try? String(contentsOf: url.appendingPathComponent(Self.creationFile),
                                  encoding: .utf8),
           let stamp = TimeInterval(text) {
            return Date(timeIntervalSince1970: stamp)
        }
        // A folder written before the stamp existed falls back to the file system's own date.
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    static func creationStamp(for date: Date) -> TimeInterval { date.timeIntervalSince1970 }

    struct Entry: Equatable {
        let name: String
        let url: URL
        let createdAt: Date

        var audioURL: URL { url.appendingPathComponent("audio.wav") }
        var metadataURL: URL { url.appendingPathComponent("metadata.json") }
    }
}