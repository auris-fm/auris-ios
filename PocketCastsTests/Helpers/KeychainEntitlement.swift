import XCTest
@testable import PocketCastsServer
import PocketCastsUtils
import Security

/// Environment limitation, checked before a test captures or changes any host state: an unsigned host
/// build (test_fast) has no keychain entitlement and every keychain call fails with
/// errSecMissingEntitlement. Skip on exactly that status; any other keychain error still fails.
func skipWithoutKeychainEntitlement() throws {
    do {
        _ = try KeychainHelper.string(for: ServerConstants.Values.syncingV2TokenKey)
    } catch KeychainHelper.KeychainError.status(let status) where status == errSecMissingEntitlement {
        throw XCTSkip("host build has no keychain entitlement (errSecMissingEntitlement); run the signed `make test`")
    }
}
