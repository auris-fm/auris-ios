import Foundation

/// Durable upload queue persistence (spec §Client queue and scheduling, docs commit 270dfa5 lineage):
/// "Persist the metadata and audio as one queue entry using an atomic ready marker; interrupted
/// preparation is not a ready upload. The queue owns temporary files and removes abandoned
/// preparation files on recovery."
///
/// Design pinned by VoiceSharingUploadQueueTests:
///   * One directory per entry under the queue root: `audio.wav`, `metadata.json`, `ready.marker`.
///   * `prepare` writes audio + metadata into an entry directory; the entry is INVISIBLE to
///     `readyEntries()` until `finalize` writes the marker. The marker is written with an
///     atomic replace so a crash cannot leave a half-written marker reading as ready.
///   * `recover` (run by `init`) deletes every entry directory without a ready marker —
///     including directories the queue did not create, because the queue OWNS its root and
///     anything foreign under it is abandoned preparation by definition.
///   * Ready entries survive recovery byte-for-byte; they are durable upload work.
///   * Dequeue order is finalize order: the marker's creation time decides FIFO position,
///     never directory name or preparation order.
///   * `remove` deletes the whole entry directory; nothing is left hidden on disk.
///
/// This type owns persistence only. Attempt gating, retry/backoff, network policy and receipt
/// handling are downstream uploader concerns and are deliberately not here.
final class VoiceSharingUploadQueue {

    /// Marker file whose PRESENCE makes an entry ready. Written atomically at finalize.
    private static let readyMarkerName = "ready.marker"
    private static let audioName = "audio.wav"
    private static let metadataName = "metadata.json"

    let rootDirectory: URL
    private let fileManager: FileManager

    /// Creates the queue over `rootDirectory` and runs recovery: abandoned preparation under the
    /// root is removed; ready entries are kept intact.
    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        recover()
    }

    struct Preparation {
        let entryDirectory: URL
    }

    /// Writes audio and metadata into a new entry directory. The entry is NOT ready and does not
    /// appear in `readyEntries()` until `finalize` marks it.
    func prepare(metadata: Data, audio: Data) throws -> Preparation {
        let entryDirectory = rootDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: entryDirectory, withIntermediateDirectories: true)
        try audio.write(to: entryDirectory.appendingPathComponent(Self.audioName), options: .atomic)
        try metadata.write(to: entryDirectory.appendingPathComponent(Self.metadataName), options: .atomic)
        return Preparation(entryDirectory: entryDirectory)
    }

    /// Atomically marks a prepared entry ready. After this returns, the entry is durable and
    /// dequeueable; a crash before this point leaves an abandoned preparation that recovery removes.
    func finalize(_ preparation: Preparation) throws {
        let marker = preparation.entryDirectory.appendingPathComponent(Self.readyMarkerName)
        let temporary = preparation.entryDirectory.appendingPathComponent("\(Self.readyMarkerName).tmp-\(UUID().uuidString)")
        try Data([0x01]).write(to: temporary, options: .atomic)
        // Atomic replace: the marker appears whole or not at all.
        _ = try fileManager.replaceItemAt(marker, withItemAt: temporary)
    }

    /// All ready (finalized) entries in finalize order.
    func readyEntries() -> [Preparation] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let ready = contents.filter { entry in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  fileManager.fileExists(atPath: entry.appendingPathComponent(Self.readyMarkerName).path)
            else { return false }
            return true
        }
        return ready
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if lDate == rDate { return lhs.lastPathComponent < rhs.lastPathComponent }
                return lDate < rDate
            }
            .map { Preparation(entryDirectory: $0) }
    }

    func metadata(of entry: Preparation) throws -> Data {
        try Data(contentsOf: entry.entryDirectory.appendingPathComponent(Self.metadataName))
    }

    func audio(of entry: Preparation) throws -> Data {
        try Data(contentsOf: entry.entryDirectory.appendingPathComponent(Self.audioName))
    }

    /// Deletes the entire entry: audio, metadata and marker leave the disk.
    func remove(_ entry: Preparation) throws {
        try fileManager.removeItem(at: entry.entryDirectory)
    }

    /// Recovery: every directory under the root without a ready marker is abandoned preparation —
    /// including foreign directories, because the queue owns its root. Ready entries are untouched.
    private func recover() {
        let contents = (try? fileManager.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for entry in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                // Stray files under the root are not entries the queue created in any live flow;
                // remove them too so the root stays queue-owned.
                try? fileManager.removeItem(at: entry)
                continue
            }
            let marker = entry.appendingPathComponent(Self.readyMarkerName)
            if !fileManager.fileExists(atPath: marker.path) {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
