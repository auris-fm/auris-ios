import Foundation
import CryptoKit

class ModelDownloader {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.background(withIdentifier: "com.auris.model-download")
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        session = URLSession(configuration: config)
    }

    func download(url: URL, sha256: String, to directory: URL) async -> Result<Void, Error> {
        let tmpURL = directory.appendingPathComponent(url.lastPathComponent + ".tmp")
        let finalURL = directory.appendingPathComponent(url.lastPathComponent)

        // Resumable download with Range header if tmp exists
        var request = URLRequest(url: url)
        if FileManager.default.fileExists(atPath: tmpURL.path) {
            let existingSize = (try? tmpURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if existingSize > 0 {
                request.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
            }
        }

        do {
            let (downloadedURL, _) = try await session.download(for: request)
            try FileManager.default.moveItem(at: downloadedURL, to: tmpURL)

            // SHA-256 verify
            let data = try Data(contentsOf: tmpURL)
            let digest = SHA256.hash(data: data)
            let computedHash = digest.compactMap { String(format: "%02x", $0) }.joined()
            guard computedHash == sha256 else {
                try FileManager.default.removeItem(at: tmpURL)
                throw ModelError.hashMismatch
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
}

enum ModelError: Error {
    case hashMismatch
    case downloadFailed
}
