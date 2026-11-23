import Foundation

/// Whether the configured log-encryption key can actually seal a log for upload.
///
/// The upload path force-unwraps `sodium.box.seal(message:recipientPublicKey:)`, which returns nil
/// unless the recipient key is exactly 32 bytes. An empty credential reaches that unwrap because
/// `Data(base64Encoded: "")` yields EMPTY Data rather than nil, so the library's own precondition
/// passes and the trap fires. A build archived with empty credentials — what
/// `make external_contributor` writes — would therefore crash when a person submits a support
/// request with logs attached. Checking usability here lets the caller refuse instead.
enum LogUploadCredentials {

    /// libsodium's sealed-box recipient key length (`crypto_box_PUBLICKEYBYTES`).
    static let requiredKeyBytes = 32

    static func isUsableEncryptionKey(_ base64Key: String) -> Bool {
        guard let decoded = Data(base64Encoded: base64Key) else { return false }
        return decoded.count == requiredKeyBytes
    }
}
