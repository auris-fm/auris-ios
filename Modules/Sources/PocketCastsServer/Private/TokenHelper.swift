import Foundation
import PocketCastsUtils
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

class TokenHelper {

    static let shared = TokenHelper(urlConnection: URLConnection(handler: URLSession.shared))

    private static let renewalLock = NSLock()
    private let backgroundState: (() -> Bool)?
    private let urlConnection: URLConnection

    init(urlConnection: URLConnection, backgroundState: (() -> Bool)? = nil) {
        self.urlConnection = urlConnection
        self.backgroundState = backgroundState
    }

    func callSecureUrl(request: URLRequest, completion: @escaping ((HTTPURLResponse?, Data?, Error?) -> Void)) {
        DispatchQueue.global().async { [weak self] in
            self?.performCallSecureUrl(request: request, retryOnUnauthorized: true, completion: completion)
        }
    }

    /// Makes an authentication URL request and returns the response and data asynchronously
    /// - Parameter request: The URLRequest to execute using URLConnection
    /// - Returns: A tuple containing the HTTPURLResponse and Data
    /// - Throws: Any error returned from the URLConnection
    func callSecureUrl(request: URLRequest) async throws -> (HTTPURLResponse?, Data?) {
        try await withCheckedThrowingContinuation { continuation in
            performCallSecureUrl(request: request, retryOnUnauthorized: true) { response, data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (response, data))
            }
        }
    }

    private func performCallSecureUrl(request: URLRequest, retryOnUnauthorized: Bool = true, completion: @escaping ((HTTPURLResponse?, Data?, Error?) -> Void)) {
        var mutableRequest = request

        if let privateUserAgent = ServerConfig.shared.syncDelegate?.privateUserAgent() {
            mutableRequest.setValue(privateUserAgent, forHTTPHeaderField: ServerConstants.HttpHeaders.userAgent)
        }

        if SyncManager.isUserLoggedIn() {
            let token: String
            if let storedToken = ServerSettings.syncingV2Token {
                token = storedToken
            } else if let newToken = acquireToken() {
                token = newToken
            } else {
                completion(nil, nil, nil)
                return
            }

            mutableRequest.setValue("Bearer \(token)", forHTTPHeaderField: ServerConstants.HttpHeaders.authorization)
        }

        urlConnection.send(request: mutableRequest) { [weak self] data, response, error in
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(nil, nil, error)
                return
            }

            if httpResponse.statusCode == ServerConstants.HttpConstants.unauthorized {
                if SyncManager.isUserLoggedIn(), retryOnUnauthorized {
                    ServerSettings.invalidateAccessToken(mutableRequest.value(forHTTPHeaderField: ServerConstants.HttpHeaders.authorization)?.replacingOccurrences(of: "Bearer ", with: ""))
                    FileLog.shared.addMessage("TokenHelper: Removed syncingV2TokenKey due to 401 unauthorized retrying url: \(request.url?.absoluteString ?? "unknown")")
                    self?.performCallSecureUrl(request: request, retryOnUnauthorized: false, completion: completion)
                } else {
                    completion(httpResponse, nil, error)
                }

                return
            }

            completion(httpResponse, data, error)
        }
    }

    func acquireToken(onlyIfMissingRefresh: Bool = false) -> String? {
        // Query main before the renewal lock: a main-thread credential lookup may
        // need that lock while another renewal is failing. Never wait on main holding it.
        let wasBackgrounded = backgroundState?() ?? isApplicationBackgrounded()
        let observedToken = ServerSettings.syncingV2Token
        Self.renewalLock.lock()
        defer { Self.renewalLock.unlock() }
        if !onlyIfMissingRefresh, let current = ServerSettings.syncingV2Token, current != observedToken { return current }
        if onlyIfMissingRefresh, (try? ServerSettings.refreshToken()) != nil { return ServerSettings.syncingV2Token }
        guard let attempt = ServerSettings.beginAuthentication(explicit: false) else { return nil }
        defer { ServerSettings.finishAuthentication(attempt) }
        let semaphore = DispatchSemaphore(value: 0)
        var refreshedToken: String? = nil
        var authentication: AuthenticationResponse?
        var error: Error? = nil

        asyncAcquireToken { result in
            switch result {
            case .success(let authenticationResponse):
                refreshedToken = authenticationResponse?.token
                authentication = authenticationResponse
            case .failure(let resultError):
                refreshedToken = nil
                error = resultError
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let token = refreshedToken, !token.isEmpty {
            guard let authentication, ServerSettings.commitAuthentication(authentication, for: attempt) else { return nil }
        }
        else {
            if wasBackgrounded {
                FileLog.shared.addMessage("TokenHelper: Skipped logout in background due to error: \(String(describing: error))")
            } else {
                // if the user doesn't have an email and password or SSO token, they aren't going to be able to acquire a sync token
                switch error as? APIError {
                case APIError.TOKEN_DEAUTH?, APIError.PERMISSION_DENIED?, APIError.INCORRECT_PASSWORD?, APIError.EMAIL_NOT_FOUND?:
                    let cleanup = { ServerSettings.ifAuthenticationIsCurrent(attempt) { self.tokenCleanUp() } }
                    // Never wait on main while owning renewalLock. Revalidate when the queued
                    // effect runs so a newer login cannot be signed out by this old failure.
                    if Thread.isMainThread { cleanup() }
                    else { DispatchQueue.main.async(execute: cleanup) }
                default:
                    // Do nothing so the user is not disrupted in the case of non-auth errors
                    FileLog.shared.addMessage("TokenHelper: Unable to acquire token but avoided logout due to error: \(String(describing: error))")
                }
            }

            return nil
        }

        return refreshedToken
    }

    private func isApplicationBackgrounded() -> Bool {
        if Thread.isMainThread {
            #if os(iOS)
            return UIApplication.shared.applicationState == .background
            #elseif os(watchOS)
            return WKExtension.shared().applicationState == .background
            #endif
        }
        let semaphore = DispatchSemaphore(value: 0)
        var isBackgrounded = false

        DispatchQueue.main.async {
            #if os(iOS)
            isBackgrounded = UIApplication.shared.applicationState == .background
            #elseif os(watchOS)
            isBackgrounded = WKExtension.shared().applicationState == .background
            #endif

            semaphore.signal()
        }

        semaphore.wait()
        return isBackgrounded
    }

    // MARK: - Email / Password Token

    func acquirePasswordToken() throws -> AuthenticationResponse? {
        guard let email = ServerSettings.syncingEmail(), let password = ServerSettings.syncingPassword() else {
            // if the user doesn't have an email and password, then we'll check if they're using SSO
            return nil
        }

        let request = try ApiServerHandler.shared.passwordLoginRequest(username: email, password: password, scope: ServerConstants.Values.apiScope)
        let (data, response) = try urlConnection.sendSynchronousRequest(with: request)
        return try ApiServerHandler.shared.decodePasswordLogin(data: data, response: response)
    }

    // MARK: - Email / Password Token

    func asyncAcquireToken(completion: @escaping (Result<AuthenticationResponse?, Error>) -> Void) {
        do {
            if (try? ServerSettings.refreshToken()) == nil, let authenticationResponse = try acquirePasswordToken() {
                completion(.success(authenticationResponse))
                return
            }
        } catch {
            completion(.failure(error))
            return
        }

        Task {
            do {
                let authenticationResponse = try await acquireIdentityToken()
                completion(.success(authenticationResponse))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - SSO Identity Token

    private func acquireIdentityToken() async throws -> AuthenticationResponse {
        return try await ApiServerHandler.shared.refreshIdentityToken(connection: urlConnection)
    }

    // MARK: Cleanup

    private func tokenCleanUp() {
        var logMessages = [String]()

        defer {
            FileLog.shared.addMessage("Acquire Token was called, however the user has \(logMessages.joined(separator: ", ")).")
        }

        if ServerSettings.syncingEmail() == nil {
            logMessages.append("no email address")
        }

        if ServerSettings.syncingPassword() == nil {
            logMessages.append("no password")
        }

        do {
            if try ServerSettings.refreshToken() == nil {
                logMessages.append("no SSO token")
            }
        } catch {
            if case let KeychainHelper.KeychainError.status(status) = error, status == errSecInteractionNotAllowed {
                logMessages.append("no SSO token")
                FileLog.shared.addMessage("Acquire Token was called, however the user has \(logMessages.joined(separator: ", ")).")
                return
            }
        }

        FileLog.shared.addMessage("Sync account is in a weird state, logging user out")
        SyncManager.signout()
    }
}
