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

    /// Current authorization state. The raw token is never exposed.
    private(set) var state: GitHubAuthorizationState

    /// Creates a settings store around an injectable token backend.
    init(tokenStore: any GitHubTokenStore = KeychainGitHubTokenStore()) {
        self.tokenStore = tokenStore
        self.state = Self.loadState(from: tokenStore)
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
    func saveToken(_ token: String) -> Bool {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            state = Self.loadState(from: tokenStore)
            return false
        }

        do {
            try tokenStore.saveToken(trimmedToken)
            state = .authorized
            return true
        } catch {
            state = .failed(.tokenStorageFailed)
            return false
        }
    }

    /// Deletes the stored GitHub token.
    @discardableResult
    func deleteToken() -> Bool {
        do {
            try tokenStore.deleteToken()
            state = .missing
            return true
        } catch {
            state = .failed(.tokenStorageFailed)
            return false
        }
    }

    /// Reloads the visible authorization state from storage.
    func reload() {
        state = Self.loadState(from: tokenStore)
    }

    /// Converts token storage into a token-safe UI state.
    private static func loadState(from tokenStore: any GitHubTokenStore) -> GitHubAuthorizationState {
        do {
            if let token = try tokenStore.loadToken(),
               !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .authorized
            }
            return .missing
        } catch {
            return .failed(.tokenStorageFailed)
        }
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
