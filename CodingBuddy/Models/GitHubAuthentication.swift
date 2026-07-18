//
//  GitHubAuthentication.swift
//  CodingBuddy
//

import Foundation

/// Origin of a GitHub credential without exposing any credential value.
nonisolated enum GitHubCredentialSource: String, Codable, Sendable {
    /// A user access token issued to the CodingBuddy GitHub App through device flow.
    case githubAppDeviceFlow
    /// A user-supplied fine-grained personal access token retained as a fallback.
    case fineGrainedPersonalAccessToken
}

/// Secret-bearing GitHub credential persisted only through the Keychain-backed store.
nonisolated struct GitHubCredential: Codable, Equatable, Sendable {
    /// Authentication mechanism that issued the credential.
    let source: GitHubCredentialSource
    /// Bearer token used for GitHub API requests.
    let accessToken: String
    /// Rotating refresh token returned for expiring GitHub App user tokens.
    let refreshToken: String?
    /// Access-token expiry, or `nil` for a non-expiring PAT.
    let accessTokenExpiresAt: Date?
    /// Refresh-token expiry when GitHub returned one.
    let refreshTokenExpiresAt: Date?

    /// Creates a credential for an explicitly entered fine-grained PAT.
    static func personalAccessToken(_ token: String) -> GitHubCredential {
        GitHubCredential(
            source: .fineGrainedPersonalAccessToken,
            accessToken: token,
            refreshToken: nil,
            accessTokenExpiresAt: nil,
            refreshTokenExpiresAt: nil
        )
    }

    /// Whether the access token should be refreshed before another API request.
    func needsRefresh(at date: Date, leeway: TimeInterval = 60) -> Bool {
        guard source == .githubAppDeviceFlow, let accessTokenExpiresAt else { return false }
        return accessTokenExpiresAt <= date.addingTimeInterval(max(0, leeway))
    }

    /// Whether a still-valid refresh token can rotate this credential.
    func canRefresh(at date: Date) -> Bool {
        guard source == .githubAppDeviceFlow,
              let refreshToken,
              !refreshToken.isEmpty else {
            return false
        }
        return refreshTokenExpiresAt.map { $0 > date } ?? true
    }
}

/// Public GitHub App configuration embedded by the release build.
nonisolated struct GitHubOAuthConfiguration: Equatable, Sendable {
    /// Generated Info.plist key populated from `CODINGBUDDY_GITHUB_APP_CLIENT_ID`.
    static let clientIDInfoKey = "CodingBuddyGitHubAppClientID"

    /// Public GitHub App client identifier. This is not a client secret.
    let clientID: String
    /// Endpoint that creates a short-lived device authorization.
    let deviceCodeEndpoint: URL
    /// Endpoint polled for initial and refreshed user access tokens.
    let accessTokenEndpoint: URL

    /// Loads the public client ID from the app bundle and keeps endpoints pinned to GitHub.com.
    static func bundled(in bundle: Bundle = .main) -> GitHubOAuthConfiguration? {
        guard let rawValue = bundle.object(forInfoDictionaryKey: clientIDInfoKey) as? String else {
            return nil
        }
        let clientID = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidClientID(clientID) else { return nil }
        return GitHubOAuthConfiguration(
            clientID: clientID,
            deviceCodeEndpoint: URL(string: "https://github.com/login/device/code")!,
            accessTokenEndpoint: URL(string: "https://github.com/login/oauth/access_token")!
        )
    }

    /// Rejects placeholders, whitespace, delimiters, and unbounded build-setting values.
    private static func isValidClientID(_ value: String) -> Bool {
        guard (8...128).contains(value.utf8.count),
              value != "$(CODINGBUDDY_GITHUB_APP_CLIENT_ID)" else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }
}

/// Short-lived device authorization shown to the user while GitHub approval is pending.
nonisolated struct GitHubDeviceAuthorization: Sendable {
    /// Opaque verification secret sent only to GitHub's token endpoint.
    let deviceCode: String
    /// Human-readable code copied or entered on GitHub.com.
    let userCode: String
    /// Pinned GitHub verification page opened in the user's browser.
    let verificationURL: URL
    /// Absolute time after which polling must stop.
    let expiresAt: Date
    /// Minimum polling interval required by GitHub.
    let pollingInterval: TimeInterval
}
