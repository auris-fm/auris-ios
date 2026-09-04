import Foundation
import CryptoKit

/// Downloads model assets with the spec's download contract: resumable HTTP (Range header
/// against an existing `.tmp`, appending partial bytes), SHA-256 verification **when a hash is
/// pinned**, and an atomic `.tmp` → final rename.
///
/// SHA-256 is only enforced when `sha256` is non-empty. Several assets (notably the
/// hf-mirror.com SenseVoice/Canary/Whisper models) do not yet carry a pinned hash, so those
/// downloads still get resumable + atomic semantics but no integrity check. **TODO(ASR-debt):
/// pin the SHA-256 for every remote model asset so integrity is enforced on all downloads.**
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

    private var session: URLSession { Self.session }

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

    func download(url: URL, sha256: String, to directory: URL) async -> Result<Void, Error> {
        let tmpURL = directory.appendingPathComponent(url.lastPathComponent + ".tmp")
        let finalURL = directory.appendingPathComponent(url.lastPathComponent)

        // Skip when the final file is already present. Mirrors the Android `downloadFile`:
        // an existing asset is not re-fetched (when a hash is pinned and mismatches, the
        // caller should delete and re-request; for un-pinned assets an existing file is
        // treated as good).
        if FileManager.default.fileExists(atPath: finalURL.path) {
            return .success(())
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
            try await downloadResumable(url: url, tmpURL: tmpURL, resumeOffset: resumeOffset)

            // SHA-256 verify. An empty pin (no hash yet) is intentionally allowed so the
            // download still proceeds with resumable + atomic semantics; pin hashes for
            // assets that have one so integrity is enforced.
            if !sha256.isEmpty {
                let data = try Data(contentsOf: tmpURL)
                let digest = SHA256.hash(data: data)
                let computedHash = digest.compactMap { String(format: "%02x", $0) }.joined()
                guard computedHash == sha256 else {
                    try? FileManager.default.removeItem(at: tmpURL)
                    throw ModelError.hashMismatch
                }
            }

            // Atomic rename
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: tmpURL, to: finalURL)
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
}
