import AppKit
import Foundation

/// Drives the OAuth 2.0 Authorization Code + PKCE flow for a Google "Desktop app" client
/// and vends fresh access tokens to the API layer.
@MainActor
final class OAuthManager: ObservableObject {

    enum AuthError: LocalizedError {
        case missingClientID
        case stateMismatch
        case userDenied(String)
        case noAuthorizationCode
        case tokenRequestFailed(String)
        case missingRefreshToken
        case needsClientSecret
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                return "No Google Client ID configured. Add GOOGLE_CLIENT_ID to .env or AppConfig.swift."
            case .stateMismatch:
                return "The sign-in response did not match the request (state mismatch). Please try again."
            case .userDenied(let reason):
                return "Google declined the sign-in: \(reason)"
            case .noAuthorizationCode:
                return "Google did not return an authorization code."
            case .tokenRequestFailed(let detail):
                return detail
            case .missingRefreshToken:
                return "Google did not return a refresh token. Revoke access at myaccount.google.com and sign in again."
            case .needsClientSecret:
                return "This Google client requires a client secret. Add GOOGLE_CLIENT_SECRET to your .env file."
            case .notSignedIn:
                return "Not signed in to Google."
            }
        }
    }

    @Published private(set) var isSignedIn = false
    @Published private(set) var accountEmail: String?
    @Published private(set) var isAuthenticating = false

    private var tokens: StoredTokens? {
        didSet {
            isSignedIn = tokens != nil
            accountEmail = tokens?.email
        }
    }

    private var server: LoopbackServer?
    private var refreshTask: Task<String, Error>?
    private let session = URLSession(configuration: .ephemeral)

    /// Set when the Keychain refused to hand over stored tokens, so the UI can explain the
    /// difference between "signed out" and "could not read the saved tokens".
    @Published private(set) var keychainWarning: String?

    init() {
        let result: (tokens: StoredTokens?, status: OSStatus) = KeychainStore.load()
        tokens = result.tokens
        isSignedIn = result.tokens != nil
        accountEmail = result.tokens?.email
        if result.tokens == nil {
            keychainWarning = KeychainStore.explain(result.status)
        }
    }

    // MARK: - Sign in / out

    func signIn() async throws {
        guard AppConfig.hasClientID else { throw AuthError.missingClientID }
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer {
            isAuthenticating = false
            server = nil
        }

        let pkce = PKCEPair()
        let state = PKCEPair.randomURLSafeString(byteCount: 16)

        let server = LoopbackServer()
        self.server = server

        // Bind first so the redirect URI (with its ephemeral port) is known, then send the
        // user to Google in their default browser.
        try await server.prepare()
        NSWorkspace.shared.open(buildAuthorizationURL(
            redirectURI: server.redirectURI,
            challenge: pkce.challenge,
            state: state
        ))

        let params = try await server.waitForCallback()

        if let error = params["error"] {
            throw AuthError.userDenied(error)
        }
        guard params["state"] == state else { throw AuthError.stateMismatch }
        guard let code = params["code"] else { throw AuthError.noAuthorizationCode }

        try await exchange(code: code, verifier: pkce.verifier, redirectURI: server.redirectURI)
    }

    func cancelSignIn() {
        server?.cancel()
        server = nil
    }

    func signOut() {
        let token = tokens?.refreshToken
        tokens = nil
        refreshTask = nil
        KeychainStore.clear()
        guard let token else { return }
        Task.detached { [session] in
            var request = URLRequest(url: AppConfig.revocationEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("token=\(token.formURLEncoded)".utf8)
            _ = try? await session.data(for: request)
        }
    }

    // MARK: - Access tokens

    /// Returns a valid access token, refreshing it if needed. Concurrent callers share one refresh.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw AuthError.notSignedIn }
        if !forceRefresh, current.isAccessTokenValid, let token = current.accessToken {
            return token
        }
        if let existing = refreshTask {
            return try await existing.value
        }
        let task = Task { () throws -> String in
            defer { refreshTask = nil }
            return try await performRefresh(refreshToken: current.refreshToken)
        }
        refreshTask = task
        return try await task.value
    }

    // MARK: - Requests

    private func buildAuthorizationURL(redirectURI: String, challenge: String, state: String) -> URL {
        var components = URLComponents(url: AppConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AppConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url!
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws {
        var form: [String: String] = [
            "client_id": AppConfig.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        if let secret = AppConfig.clientSecret { form["client_secret"] = secret }

        let response: TokenResponse = try await post(form: form)
        guard let refreshToken = response.refresh_token else { throw AuthError.missingRefreshToken }

        var stored = StoredTokens(
            refreshToken: refreshToken,
            accessToken: response.access_token,
            expiresAt: response.expiryDate,
            email: response.emailFromIDToken,
            scope: response.scope
        )
        if stored.email == nil { stored.email = tokens?.email }
        try KeychainStore.save(stored)
        tokens = stored
    }

    private func performRefresh(refreshToken: String) async throws -> String {
        var form: [String: String] = [
            "client_id": AppConfig.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if let secret = AppConfig.clientSecret { form["client_secret"] = secret }

        do {
            let response: TokenResponse = try await post(form: form)
            guard let accessToken = response.access_token else {
                throw AuthError.tokenRequestFailed("Google did not return an access token.")
            }
            var stored = tokens ?? StoredTokens(refreshToken: refreshToken)
            stored.accessToken = accessToken
            stored.expiresAt = response.expiryDate
            stored.refreshToken = response.refresh_token ?? refreshToken
            if let email = response.emailFromIDToken { stored.email = email }
            try? KeychainStore.save(stored)
            tokens = stored
            return accessToken
        } catch let error as AuthError {
            // A revoked or expired grant means the user has to sign in again.
            if case .tokenRequestFailed(let detail) = error, detail.contains("invalid_grant") {
                tokens = nil
                KeychainStore.clear()
            }
            throw error
        }
    }

    private func post(form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: AppConfig.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form
            .map { "\($0.key)=\($0.value.formURLEncoded)" }
            .joined(separator: "&").utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 200 {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        }

        let failure = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
        let code = failure?.error ?? "http_\(status)"
        let description = failure?.error_description ?? String(decoding: data, as: UTF8.self)

        if code == "invalid_client" || description.lowercased().contains("client_secret") {
            if AppConfig.clientSecret == nil { throw AuthError.needsClientSecret }
        }
        throw AuthError.tokenRequestFailed("Google token request failed (\(code)): \(description)")
    }
}

// MARK: - Wire types

private struct TokenResponse: Decodable {
    let access_token: String?
    let refresh_token: String?
    let expires_in: Double?
    let scope: String?
    let id_token: String?

    var expiryDate: Date? {
        guard let expires_in else { return nil }
        return Date().addingTimeInterval(expires_in)
    }

    /// Reads the `email` claim out of the ID token. The token came straight from Google's
    /// TLS-protected token endpoint, so no signature verification is needed here.
    var emailFromIDToken: String? {
        guard let id_token else { return nil }
        let segments = id_token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

private struct TokenErrorResponse: Decodable {
    let error: String?
    let error_description: String?
}

extension String {
    var formURLEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
