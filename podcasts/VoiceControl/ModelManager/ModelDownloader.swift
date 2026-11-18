import Foundation
import CryptoKit
import os.log

/// Downloads model assets with the spec's download contract: resumable HTTP (Range header
/// against an existing `.tmp`, appending partial bytes), SHA-256 verification **when a hash is
/// pinned**, and an atomic `.tmp` → final rename.
///
/// SHA-256 is enforced whenever `sha256` is non-empty; every remote model asset carries a
/// pin. An empty pin keeps resumable + atomic semantics without an integrity check.
final class ModelDownloader {

    /// A single session shared by every `ModelDownloader` instance. Model downloads happen
    /// while the app is foregrounded (during `ensureReady`), so a regular (non-background)
    /// session is used; a background config is not needed and its streaming is unsupported.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    private let sessionOverride: URLSession?

    init(session: URLSession? = nil) {
        self.sessionOverride = session
    }

    private var session: URLSession { sessionOverride ?? Self.session }

    /// Downloads every file in `files` into `directory` (creating it if needed), applying the
    /// per-file download contract above. Short-circuits on the first failure.
    func download(files: [ModelFile], to directory: URL) async -> Result<Void, Error> {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(error)
        }
        for file in files {
            let result = await download(url: file.url, sha256: file.sha256 ?? "", to: directory)
            if case .failure = result { return result }
        }
        return .success(())
    }

    /// One in-flight download per final path: concurrent callers for the same asset await the
    /// running task instead of starting a second writer on the same `.tmp`. Different assets
    /// download in parallel. An actor (not a lock) because the work spans `await`s.
    private actor PathDownloads {
        static let shared = PathDownloads()
        private var running: [String: Task<Result<Void, Error>, Never>] = [:]

        func run(path: String, _ work: @escaping @Sendable () async -> Result<Void, Error>) async -> Result<Void, Error> {
            if let existing = running[path] {
                // A second caller waits for the first download, then re-checks the file itself.
                _ = await existing.value
                return await work()
            }
            let task = Task { await work() }
            running[path] = task
            let result = await task.value
            running[path] = nil
            return result
        }
    }

    /// Streams the file's SHA-256 in 1 MiB chunks so a 239 MB model is never read into RAM
    /// whole. Returns nil when the file cannot be read.
    private func streamedSHA256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    /// A verified-file marker: the pin, size and modification date at the moment the file
    /// passed its hash check. On later starts a matching marker skips the full hash — hashing
    /// 239 MB on every launch would add seconds to the first voice start. Any difference (or a
    /// missing marker) falls back to the full streamed hash.
    private struct VerifiedMarker: Codable {
        let sha256: String
        let size: Int
        let mtime: TimeInterval
    }

    private func markerURL(for finalURL: URL) -> URL {
        finalURL.appendingPathExtension("verified")
    }

    private func markerMatches(_ finalURL: URL, sha256: String) -> Bool {
        guard let data = try? Data(contentsOf: markerURL(for: finalURL)),
              let marker = try? JSONDecoder().decode(VerifiedMarker.self, from: data),
              marker.sha256 == sha256,
              let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
              let size = attrs[.size] as? Int, size == marker.size,
              let mtime = attrs[.modificationDate] as? Date,
              abs(mtime.timeIntervalSince1970 - marker.mtime) < 1 else { return false }
        return true
    }

    private func writeMarker(_ finalURL: URL, sha256: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
              let size = attrs[.size] as? Int,
              let mtime = attrs[.modificationDate] as? Date else { return }
        let marker = VerifiedMarker(sha256: sha256, size: size, mtime: mtime.timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(marker) {
            try? data.write(to: markerURL(for: finalURL), options: .atomic)
        }
    }

    /// Reads `finalURL` and checks it against `sha256` when a hash is pinned. An un-pinned
    /// asset cannot be verified, so it reports valid. A matching verified-marker skips the
    /// hash; otherwise the file is hashed in full and a fresh marker written on success.
    private func existingFileMatchesPin(_ finalURL: URL, sha256: String) -> Bool {
        if sha256.isEmpty { return true }
        if markerMatches(finalURL, sha256: sha256) { return true }
        let start = Date()
        let computed = streamedSHA256(of: finalURL)
        let elapsed = Date().timeIntervalSince(start)
        os_log(.info, "ModelDownloader: hashed existing %{public}@ in %.2f s", finalURL.lastPathComponent, elapsed)
        guard computed == sha256 else { return false }
        writeMarker(finalURL, sha256: sha256)
        return true
    }

    func download(url: URL, sha256: String, to directory: URL) async -> Result<Void, Error> {
        let tmpURL = directory.appendingPathComponent(url.lastPathComponent + ".tmp")
        let finalURL = directory.appendingPathComponent(url.lastPathComponent)
        return await PathDownloads.shared.run(path: finalURL.path) { [weak self] in
            guard let self else { return .failure(ModelError.hashMismatch) }
            return await self.downloadOne(url: url, sha256: sha256, tmpURL: tmpURL, finalURL: finalURL, directory: directory)
        }
    }

    private func downloadOne(url: URL, sha256: String, tmpURL: URL, finalURL: URL, directory: URL) async -> Result<Void, Error> {
        // Skip when the final file is already present AND good. A pinned asset is verified
        // against its hash; a corrupt or truncated file is deleted and re-downloaded instead
        // of being trusted forever. Un-pinned assets keep the old trust behaviour.
        if FileManager.default.fileExists(atPath: finalURL.path) {
            if existingFileMatchesPin(finalURL, sha256: sha256) {
                return .success(())
            }
            // The marker describes the OLD file; it must not sit next to its replacement.
            try? FileManager.default.removeItem(at: markerURL(for: finalURL))
            try? FileManager.default.removeItem(at: finalURL)
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(error)
        }

        // Resumable download: if a `.tmp` already exists, request the remaining bytes from the
        // server and append to the existing partial file.
        var resumeOffset: UInt64 = 0
        if let size = (try? tmpURL.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > 0 {
            resumeOffset = UInt64(size)
        }

        do {
            do {
                try await downloadResumable(url: url, tmpURL: tmpURL, resumeOffset: resumeOffset)
            } catch ModelError.rangeNotSatisfiable {
                // The `.tmp` is already at (or past) the full length — a kill between the
                // download and the rename leaves exactly this state. The bytes on disk are
                // the whole asset; fall through to the hash check instead of retrying a
                // Range request the server will keep answering with 416.
            }

            // SHA-256 verify. An empty pin (no hash yet) is intentionally allowed so the
            // download still proceeds with resumable + atomic semantics; pin hashes for
            // assets that have one so integrity is enforced.
            if !sha256.isEmpty {
                if streamedSHA256(of: tmpURL) != sha256 {
                    try? FileManager.default.removeItem(at: tmpURL)
                    // A full-size but corrupt `.tmp` (the 416 fall-through) is re-downloaded
                    // from scratch once, not kept and failed forever.
                    if resumeOffset > 0 {
                        try await downloadResumable(url: url, tmpURL: tmpURL, resumeOffset: 0)
                        guard streamedSHA256(of: tmpURL) == sha256 else {
                            try? FileManager.default.removeItem(at: tmpURL)
                            throw ModelError.hashMismatch
                        }
                    } else {
                        throw ModelError.hashMismatch
                    }
                }
            }

            // Atomic rename. Any stale marker goes first so it never describes the new file.
            try? FileManager.default.removeItem(at: markerURL(for: finalURL))
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: tmpURL, to: finalURL)
            // The bytes were just hashed above, so the marker is written right here — the
            // first start after install adds no extra hash.
            if !sha256.isEmpty { writeMarker(finalURL, sha256: sha256) }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Streams `url` into `tmpURL`, resuming from `resumeOffset` when > 0. Retries transient
    /// failures with a small backoff, mirroring the Android `ModelManager.downloadFile`.
    private func downloadResumable(url: URL, tmpURL: URL, resumeOffset: UInt64) async throws {
        var offset = resumeOffset
        var attempts = 0
        while attempts < 5 {
            attempts += 1
            do {
                try await streamOnce(url: url, tmpURL: tmpURL, offset: offset)
                return
            } catch ModelError.rangeNotSatisfiable {
                throw ModelError.rangeNotSatisfiable
            } catch {
                if attempts >= 5 {
                    throw error
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                offset = (try? tmpURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? offset
            }
        }
    }

    private func streamOnce(url: URL, tmpURL: URL, offset: UInt64) async throws {
        if !FileManager.default.fileExists(atPath: tmpURL.path) {
            FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        }
        let fileHandle = try FileHandle(forWritingTo: tmpURL)
        defer { try? fileHandle.close() }

        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelError.downloadFailed }
        let code = http.statusCode
        if code == 416 { throw ModelError.rangeNotSatisfiable }
        guard code == 200 || code == 206 else { throw ModelError.downloadFailed }
        let isRange = code == 206

        // If the server ignored our Range (200), restart the file from scratch.
        var writeOffset = offset
        if offset > 0 && !isRange {
            try fileHandle.truncate(atOffset: 0)
            writeOffset = 0
        }
        try fileHandle.seek(toOffset: writeOffset)

        // Buffer into 1 MiB chunks to avoid a per-byte syscall.
        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1_048_576 {
                try fileHandle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try fileHandle.write(buffer)
        }
    }
}

enum ModelError: Error {
    case hashMismatch
    case downloadFailed
    case rangeNotSatisfiable
}
