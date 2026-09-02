import Foundation
import CryptoKit

class ModelDownloader {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = true
        self.session = URLSession(configuration: config)
    }

    func download(
        url: URL,
        sha256: String,
        to directory: URL,
        expectedBytes: Int64? = nil
    ) async -> Result<Void, Error> {
        let tmpURL = directory.appendingPathComponent(url.lastPathComponent + ".tmp")
        let finalURL = directory.appendingPathComponent(url.lastPathComponent)

        // Already present and matching size/hash — skip.
        if FileManager.default.fileExists(atPath: finalURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
           let size = attrs[.size] as? NSNumber,
           expectedBytes == nil || size.int64Value == expectedBytes {
            if sha256.isEmpty {
                return .success(())
            }
            if let data = try? Data(contentsOf: finalURL), sha256Hex(data) == sha256 {
                return .success(())
            }
        }

        var request = URLRequest(url: url)
        if FileManager.default.fileExists(atPath: tmpURL.path) {
            let existingSize = (try? tmpURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if existingSize > 0 {
                request.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
            }
        }

        do {
            let (downloadedURL, _) = try await session.download(for: request)
            if FileManager.default.fileExists(atPath: tmpURL.path) {
                try FileManager.default.removeItem(at: tmpURL)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: tmpURL)

            let data = try Data(contentsOf: tmpURL)
            if let expectedBytes, Int64(data.count) != expectedBytes {
                try FileManager.default.removeItem(at: tmpURL)
                throw ModelError.downloadFailed
            }
            if !sha256.isEmpty {
                let computedHash = sha256Hex(data)
                guard computedHash == sha256 else {
                    try FileManager.default.removeItem(at: tmpURL)
                    throw ModelError.hashMismatch
                }
            }

            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: tmpURL, to: finalURL)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}

enum ModelError: Error {
    case hashMismatch
    case downloadFailed
}
