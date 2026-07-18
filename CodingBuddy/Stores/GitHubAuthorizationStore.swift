//
//  GitHubAuthorizationStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Token authorization state shown in app settings.
nonisolated enum GitHubAuthorizationState: Equatable, Sendable {
    /// No GitHub token is stored.
    case missing
    /// A GitHub token exists in Keychain.
    case authorized
    /// CodingBuddy could not read or write the token.
    case failed(GitHubClientError)
}

/// Settings-originated token changes that other stores can react to.
nonisolated enum GitHubAuthorizationChange: Equatable, Sendable {
    /// A token was saved or replaced.
    case saved
    /// The saved token was removed.
    case removed
}

/// Root-owned settings model for GitHub authorization.
@Observable
final class GitHubAuthorizationStore: CustomDebugStringConvertible {
    /// Token persistence shared with GitHub clients.
    @ObservationIgnored private let tokenStore: any GitHubTokenStore
    /// Actor that owns device flow and rotating-token refresh state.
    @ObservationIgnored private let credentialCoordinator: GitHubCredentialCoordinator

    /// Current authorization state. The raw token is never exposed.
    private(set) var state: GitHubAuthorizationState
    /// Credential origin shown without exposing any secret value.
    private(set) var credentialSource: GitHubCredentialSource?
    /// Token-safe device-flow failure shown only during sign-in.
    private(set) var signInError: String?

    /// Creates a settings store around an injectable token backend.
    init(
        tokenStore: any GitHubTokenStore = KeychainGitHubTokenStore(),
        credentialCoordinator: GitHubCredentialCoordinator? = nil
    ) {
        self.tokenStore = tokenStore
        self.credentialCoordinator = credentialCoordinator
            ?? GitHubCredentialCoordinator(tokenStore: tokenStore)
        let authorization = Self.loadAuthorization(from: tokenStore)
        self.state = authorization.state
        self.credentialSource = authorization.source
        self.signInError = nil
    }

    /// Whether a token is currently saved.
    var hasSavedToken: Bool {
        state == .authorized
    }

    /// Debug text intentionally omits the token and underlying storage errors.
    var debugDescription: String {
        "GitHubAuthorizationStore(state: \(debugStateName))"
    }

    /// Saves a trimmed GitHub token in the configured backend.
    @discardableResult
    func saveToken(_ token: String) async -> Bool {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            reload()
            return false
        }

        do {
            try await credentialCoordinator.savePersonalAccessToken(trimmedToken)
            state = .authorized
            credentialSource = .fineGrainedPersonalAccessToken
            signInError = nil
            return true
        } catch {
            state = .failed(.tokenStorageFailed)
            return false
        }
    }

    /// Deletes the stored GitHub token.
    @discardableResult
    func deleteToken() async -> Bool {
        do {
            try await credentialCoordinator.deleteCredential()
            state = .missing
            credentialSource = nil
            signInError = nil
            return true
        } catch {
            state = .failed(.tokenStorageFailed)
            return false
        }
    }

    /// Reloads the visible authorization state from storage.
    func reload() {
        let authorization = Self.loadAuthorization(from: tokenStore)
        state = authorization.state
        credentialSource = authorization.source
    }

    /// Requests a short-lived browser code from the configured CodingBuddy GitHub App.
    func beginGitHubAppSignIn() async -> GitHubDeviceAuthorization? {
        signInError = nil
        do {
            return try await credentialCoordinator.beginDeviceAuthorization()
        } catch {
            signInError = Self.safeSignInMessage(for: error)
            return nil
        }
    }

    /// Polls GitHub for approval and reloads token-safe authorization metadata on success.
    @discardableResult
    func completeGitHubAppSignIn(_ authorization: GitHubDeviceAuthorization) async -> Bool {
        signInError = nil
        do {
            _ = try await credentialCoordinator.completeDeviceAuthorization(authorization)
            reload()
            return true
        } catch is CancellationError {
            return false
        } catch {
            signInError = Self.safeSignInMessage(for: error)
            return false
        }
    }

    /// Clears a previous device-flow error before another attempt.
    func clearSignInError() {
        signInError = nil
    }

    /// Converts token storage into a token-safe UI state.
    private static func loadAuthorization(
        from tokenStore: any GitHubTokenStore
    ) -> (state: GitHubAuthorizationState, source: GitHubCredentialSource?) {
        do {
            if let credential = try tokenStore.loadCredential(),
               !credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (.authorized, credential.source)
            }
            return (.missing, nil)
        } catch {
            return (.failed(.tokenLoadFailed), nil)
        }
    }

    /// Maps only sanitized local errors into device-flow UI copy.
    private static func safeSignInMessage(for error: Error) -> String {
        if let error = error as? GitHubOAuthDeviceFlowError {
            return error.localizedDescription
        }
        if let error = error as? GitHubCredentialCoordinatorError {
            return error.localizedDescription
        }
        return String(localized: "GitHub sign-in could not be completed.")
    }

    /// Stable token-safe debug state name.
    private var debugStateName: String {
        switch state {
        case .missing:
            "missing"
        case .authorized:
            "authorized"
        case .failed:
            "failed"
        }
    }
}
