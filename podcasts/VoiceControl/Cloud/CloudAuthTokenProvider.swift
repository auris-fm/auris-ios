import Foundation

/// Task #33 client half — the Auris-issued token implementation behind
/// `CloudTokenProviding`.
///
/// Contract (`core` edge-particle, `53a83e2` + `28cd409`):
/// - `POST /api/v1/auth/token` — body `{credential, device{platform, app_version}}`;
///   the credential is the account session the app already holds. Response:
///   `{access_token, token_type, expires_in, refresh_token, refresh_expires_in, issuer, subject}`.
/// - `POST /api/v1/auth/refresh` — body `{refresh_token}`; returns a **new**
///   access + refresh pair (rotation). Replaying a rotated token revokes the
///   chain and returns `401`, so concurrent refreshes must be single-flighted.
/// - Access lifetime is 15 minutes; refresh lifetime 30 days.
///
/// Postures kept from the seam: fail closed with no credential (callers then
/// dial nothing), and no same-turn retry after a refresh. A `401` from the
/// refresh endpoint means re-acquire from the account credential via the token
/// endpoint — never retry the refresh.
///
/// `handleUnauthorized()` is called by callers on a 401; the *next* `token()`
/// carries the new credential. Tokens are held in memory only: a cold start
/// re-exchanges the account credential, which avoids persisting a long-lived
/// refresh token in a second place (the account session is already in the
/// Keychain).
final class CloudAuthTokenProvider: CloudTokenProviding {
    static let tokenPath = "/api/v1/auth/token"
    static let refreshPath = "/api/v1/auth/refresh"
    /// Refresh slightly before the server-side expiry so a request never leaves
    /// with a token that expires in flight.
    static let expirySkew: TimeInterval = 30
    static let requestTimeoutSeconds: TimeInterval = 15

    struct Tokens: Equatable {
        let accessToken: String
        let refreshToken: String?
        /// Proactive-refresh boundary (real expiry minus the skew).
        let expiresAt: Date
        /// The token's real expiry: a request may still use the token up to here,
        /// so an inconclusive refresh doesn't fail a call that was still valid.
        let hardExpiresAt: Date

        var isFresh: Bool { expiresAt > Date() }
    }

    /// Result of one endpoint call. The 401/other split is load-bearing: only a
    /// definitive rejection may discard the credential/chain — an unreachable or
    /// failing verification path (503/429/transport) must not sign the user out.
    private enum Outcome {
        case success(Tokens)
        /// Checked and rejected (401): the credential or chain is genuinely bad.
        case rejected
        /// Could not be checked (5xx/429/transport/unconfigured): keep everything.
        case inconclusive
    }

    private let authBaseURLProvider: () -> String
    private let credentialProvider: () -> String?
    private let appVersionProvider: () -> String
    private let session: URLSession
    private let now: () -> Date

    private let lock = NSLock()
    private var tokens: Tokens?
    /// Single-flight handle: concurrent 401s/handlers await the same refresh
    /// instead of each rotating the refresh token (the second replay would
    /// revoke the chain).
    private var inFlight: Task<Outcome, Never>?

    init(
        authBaseURLProvider: @escaping () -> String,
        credentialProvider: @escaping () -> String?,
        appVersionProvider: @escaping () -> String = { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown" },
        session: URLSession? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.authBaseURLProvider = authBaseURLProvider
        self.credentialProvider = credentialProvider
        self.appVersionProvider = appVersionProvider
        self.now = now
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.requestTimeoutSeconds
            config.timeoutIntervalForResource = Self.requestTimeoutSeconds * 2
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - CloudTokenProviding

    func token() async -> String? {
        if let cached = cachedFreshToken() {
            return cached
        }
        // Past the proactive-refresh boundary: prefer the rotating refresh chain,
        // fall back to a fresh credential exchange.
        let outcome = await singleFlight { [self] in
            if let stored = currentRefreshToken() {
                switch await performRefresh(refreshToken: stored) {
                case let .success(rotated):
                    store(rotated)
                    return .success(rotated)
                case .rejected:
                    // 401: the chain is revoked/rotated-out — re-acquire from the
                    // account credential instead of replaying the refresh.
                    dropChain()
                    return await exchangeCredential()
                case .inconclusive:
                    // Verification path unreachable: keep the chain AND any token
                    // that is still within its real lifetime.
                    return .inconclusive
                }
            }
            return await exchangeCredential()
        }

        switch outcome {
        case let .success(tokens):
            return tokens.accessToken
        case .rejected:
            return nil
        case .inconclusive:
            return cachedUsableToken()
        }
    }

    func handleUnauthorized() async {
        // Drop only the rejected ACCESS token: the refresh chain must survive so
        // the next acquisition rotates it instead of re-exchanging the account
        // credential. Callers do not retry their own request with the result
        // (no same-turn retry).
        invalidateAccessToken()
        _ = await token()
    }

    // MARK: - request paths

    private func exchangeCredential() async -> Outcome {
        guard let credential = credentialProvider(), !credential.isEmpty else { return .rejected }
        let body: [String: Any] = [
            "credential": credential,
            "device": [
                "platform": platformName,
                "app_version": appVersionProvider(),
            ],
        ]
        switch await post(path: Self.tokenPath, body: body) {
        case let .success(tokens):
            store(tokens)
            return .success(tokens)
        case .rejected:
            return .rejected
        case .inconclusive:
            return .inconclusive
        }
    }

    private func performRefresh(refreshToken: String) async -> Outcome {
        await post(path: Self.refreshPath, body: ["refresh_token": refreshToken])
    }

    private func post(path: String, body: [String: Any]) async -> Outcome {
        let baseURL = authBaseURLProvider().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !baseURL.isEmpty, let url = URL(string: baseURL + path) else { return .inconclusive }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.requestTimeoutSeconds
        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { return .rejected }
        request.httpBody = encoded

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                guard let tokens = decodeTokens(data) else { return .inconclusive }
                return .success(tokens)
            }
            // 401/403: checked and rejected. Anything else (5xx/429/other) is
            // "could not check" — never a reason to discard the credential.
            return (status == 401 || status == 403) ? .rejected : .inconclusive
        } catch {
            return .inconclusive
        }
    }

    private func decodeTokens(_ data: Data) -> Tokens? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String, !accessToken.isEmpty
        else {
            return nil
        }
        let expiresIn = (object["expires_in"] as? Double) ?? 900
        let issued = now()
        return Tokens(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String,
            expiresAt: issued.addingTimeInterval(max(0, expiresIn - Self.expirySkew)),
            hardExpiresAt: issued.addingTimeInterval(max(0, expiresIn))
        )
    }

    // MARK: - state

    private func cachedFreshToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let tokens, tokens.expiresAt > now(), !tokens.accessToken.isEmpty else { return nil }
        return tokens.accessToken
    }

    private func currentTokens() -> Tokens? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    private func store(_ tokens: Tokens) {
        lock.lock()
        self.tokens = tokens
        lock.unlock()
    }

    /// Drops the refresh chain after a definitive rejection (401 from /refresh).
    private func dropChain() {
        lock.lock()
        tokens = nil
        lock.unlock()
    }

    /// A token we may still use while a refresh is inconclusive: past the
    /// proactive-refresh boundary but within its real lifetime.
    private func cachedUsableToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let tokens, tokens.hardExpiresAt > now(), !tokens.accessToken.isEmpty else { return nil }
        return tokens.accessToken
    }

    private func currentRefreshToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let refresh = tokens?.refreshToken, !refresh.isEmpty else { return nil }
        return refresh
    }

    /// Marks the cached access token unusable while keeping the refresh token.
    private func invalidateAccessToken() {
        lock.lock()
        if let existing = tokens {
            tokens = Tokens(
                accessToken: "",
                refreshToken: existing.refreshToken,
                expiresAt: .distantPast,
                hardExpiresAt: .distantPast
            )
        }
        lock.unlock()
    }

    /// One refresh/exchange at a time: every caller awaits the same in-flight
    /// result.
    private func singleFlight(_ work: @escaping () async -> Outcome) async -> Outcome {
        lock.lock()
        if let existing = inFlight {
            lock.unlock()
            return await existing.value
        }
        let task = Task { await work() }
        inFlight = task
        lock.unlock()

        let result = await task.value
        lock.lock()
        inFlight = nil
        lock.unlock()
        return result
    }

    private var platformName: String {
        #if os(iOS)
        return "ios"
        #else
        return "unknown"
        #endif
    }
}
