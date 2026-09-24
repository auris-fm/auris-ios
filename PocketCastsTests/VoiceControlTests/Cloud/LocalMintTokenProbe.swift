import XCTest
@testable import podcasts

/// LOCAL-ONLY probe (never meant to be committed): mints a staging Auris access
/// token through the production seam and writes it to /tmp/minted_token.txt so
/// the probe can consume it. Runs inside the host app process, so the account
/// session is read from the app's own Keychain — the durable credential never
/// leaves the simulator.
final class LocalMintTokenProbe: XCTestCase {
    func testMintStagingEdgeToken() async throws {
        var diagnostic = ""

        let credential = CloudAccountSessionCredentialProvider().credential()
        diagnostic += "credential_present=\(credential != nil)\n"

        guard credential != nil else {
            diagnostic += "reason=not_logged_in\n"
            try? diagnostic.write(toFile: "/tmp/minted_token_diag.txt", atomically: true, encoding: .utf8)
            // Not a failure of the harness: the app simply has no session yet.
            return
        }

        let provider = CloudAuthTokenProvider(
            authBaseURLProvider: { "https://api-staging.auris.fm" },
            credentialProvider: { CloudAccountSessionCredentialProvider().credential() },
            appVersionProvider: { "probe" }
        )

        let token = await provider.token()
        diagnostic += "minted=\(token != nil)\n"
        if let token {
            try token.write(toFile: "/tmp/auris-probe-token", atomically: true, encoding: .utf8)
            diagnostic += "token_len=\(token.count)\n"
            diagnostic += "looks_like_jwt=\(token.split(separator: ".").count == 3)\n"
        }
        try? diagnostic.write(toFile: "/tmp/minted_token_diag.txt", atomically: true, encoding: .utf8)
        XCTAssertNotNil(token, "expected a token when the app is signed in; see /tmp/minted_token_diag.txt")
    }

    /// LOCAL-ONLY: reports which account endpoints accept the app's *access* token
    /// as a bearer (status codes only — the token never leaves the process).
    /// A password login yields no refresh token, so the Auris exchange needs a
    /// credential mode that accepts an access token; this finds the endpoint that
    /// actually authenticates it.
    func testAccountEndpointsAcceptTheAccessToken() async throws {
        guard let credential = CloudAccountSessionCredentialProvider().credential() else {
            try? "not_logged_in\n".write(toFile: "/tmp/account_endpoint_diag.txt", atomically: true, encoding: .utf8)
            return
        }
        var lines: [String] = []
        // Ask the app what it actually resolves for cloud/API traffic, then probe
        // that same base — a candidate list of guessed hosts is what 404'd before.
        let appBase = CloudConfig.shared.baseUrl
        lines.append("app_base_url=\(appBase.isEmpty ? "<empty>" : appBase)")
        let candidateBases = appBase.isEmpty
            ? ["https://api-staging.auris.fm", "https://api.pocketcasts.net"]
            : [appBase]
        for base in candidateBases {
            let trimmed = base.hasSuffix("/") ? base : base + "/"
            for path in ["user/last_sync_at", "user/account", "api/user/last_sync_at", "api/user/account"] {
                var request = URLRequest(url: URL(string: trimmed + path)!)
                request.httpMethod = "GET"
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 15
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    lines.append("GET \(trimmed)\(path) -> \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                } catch {
                    lines.append("GET \(trimmed)\(path) -> transport error")
                }
            }
        }
        try? lines.joined(separator: "\n").write(toFile: "/tmp/account_endpoint_diag.txt", atomically: true, encoding: .utf8)
    }
}
