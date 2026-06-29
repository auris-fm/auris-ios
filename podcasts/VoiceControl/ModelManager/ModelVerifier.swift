import Foundation
import CryptoKit

enum ModelVerifier {
    static func verify(fileAt path: URL, expectedSHA256: String) -> Bool {
        guard let data = try? Data(contentsOf: path) else { return false }
        let digest = SHA256.hash(data: data)
        let computedHash = digest.compactMap { String(format: "%02x", $0) }.joined()
        return computedHash == expectedSHA256
    }

    static func verifyAll(models: [(path: URL, sha256: String)]) -> Bool {
        models.allSatisfy { verify(fileAt: $0.path, expectedSHA256: $0.sha256) }
    }
}
