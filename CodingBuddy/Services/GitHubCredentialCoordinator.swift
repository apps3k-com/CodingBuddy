//
//  GitHubCredentialCoordinator.swift
//  CodingBuddy
//

import Foundation

/// Capability requested from the stored GitHub credential.
nonisolated enum GitHubCredentialAccess: Sendable {
    /// Read-only API access used by monitoring and review inspection.
    case readOnly
    /// Mutating API access reserved for the installed CodingBuddy GitHub App.
    case write
}

/// Fail-closed credential lifecycle errors safe to map into authorization UI.
nonisolated enum GitHubCredentialCoordinatorError: LocalizedError, Equatable, Sendable {
    /// No credential is available in Keychain.
    case missingCredential
    /// A legacy PAT can inspect data but cannot authorize CodingBuddy writes.
    case githubAppRequired
    /// The app build lacks its public GitHub App client identifier.
    case missingConfiguration
    /// Keychain could not load or persist the credential bundle.
    case credentialStorageFailed

    /// Localized explanation that never contains credential data.
    var errorDescription: String? {
        switch self {
        case .missingCredential:
            String(localized: "Sign in to GitHub to continue.")
        case .githubAppRequired:
            String(localized: "Sign in with the CodingBuddy GitHub App before changing pull requests.")
        case .missingConfiguration:
            String(localized: "This CodingBuddy build is not configured for GitHub App sign-in.")
        case .credentialStorageFailed:
            String(localized: "CodingBuddy could not update GitHub authorization in Keychain.")
        }
    }
}

/// Serializes GitHub credential reads, device authorization, and rotating-token refreshes.
actor GitHubCredentialCoordinator {
    /// Keychain-backed persistence shared with read-only clients.
    private let tokenStore: any GitHubTokenStore
    /// Device-flow client when the build carries a valid public client ID.
    private let oauthClient: GitHubOAuthDeviceFlowClient?
    /// In-flight refresh shared by concurrent callers.
    private var refreshFlight: RefreshFlight?
    /// Monotonic invalidation generation for operations that suspend across network I/O.
    private var revision: UInt64 = 0

    /// Creates the production coordinator from bundled configuration.
    init(
        tokenStore: any GitHubTokenStore = KeychainGitHubTokenStore(),
        oauthConfiguration: GitHubOAuthConfiguration? = GitHubOAuthConfiguration.bundled(),
        transport: any GitHubTransport = URLSessionGitHubTransport()
    ) {
        self.tokenStore = tokenStore
        self.oauthClient = oauthConfiguration.map {
            GitHubOAuthDeviceFlowClient(configuration: $0, transport: transport)
        }
    }

    /// Creates a coordinator around an injectable OAuth client for deterministic tests.
    init(tokenStore: any GitHubTokenStore, oauthClient: GitHubOAuthDeviceFlowClient?) {
        self.tokenStore = tokenStore
        self.oauthClient = oauthClient
    }

    /// Starts a short-lived GitHub device authorization without persisting its device secret.
    func beginDeviceAuthorization() async throws -> GitHubDeviceAuthorization {
        guard let oauthClient else {
            throw GitHubCredentialCoordinatorError.missingConfiguration
        }
        return try await oauthClient.requestAuthorization()
    }

    /// Completes a displayed device authorization and atomically saves the rotating credential bundle.
    func completeDeviceAuthorization(
        _ authorization: GitHubDeviceAuthorization
    ) async throws -> GitHubCredentialSource {
        guard let oauthClient else {
            throw GitHubCredentialCoordinatorError.missingConfiguration
        }
        let expectedRevision = revision
        let baseline = try loadCredential()
        let credential = try await oauthClient.waitForAuthorization(authorization)
        guard revision == expectedRevision,
              try loadCredential() == baseline else {
            throw CancellationError()
        }
        do {
            try tokenStore.saveCredential(credential)
        } catch {
            throw GitHubCredentialCoordinatorError.credentialStorageFailed
        }
        return credential.source
    }

    /// Returns a valid credential for the requested capability, refreshing once when needed.
    func credential(
        for access: GitHubCredentialAccess,
        at date: Date = Date()
    ) async throws -> GitHubCredential {
        let credential: GitHubCredential
        do {
            guard let loaded = try tokenStore.loadCredential() else {
                throw GitHubCredentialCoordinatorError.missingCredential
            }
            credential = loaded
        } catch let error as GitHubCredentialCoordinatorError {
            throw error
        } catch {
            throw GitHubCredentialCoordinatorError.credentialStorageFailed
        }

        if access == .write, credential.source != .githubAppDeviceFlow {
            throw GitHubCredentialCoordinatorError.githubAppRequired
        }
        guard credential.needsRefresh(at: date) else { return credential }
        return try await refreshedCredential(from: credential)
    }

    /// Deletes every saved GitHub credential and cancels an unconsumed refresh result.
    func deleteCredential() throws {
        revision &+= 1
        refreshFlight?.task.cancel()
        refreshFlight = nil
        do {
            try tokenStore.deleteToken()
        } catch {
            throw GitHubCredentialCoordinatorError.credentialStorageFailed
        }
    }

    /// Replaces any credential with a read-only PAT and invalidates suspended OAuth work.
    func savePersonalAccessToken(_ token: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GitHubCredentialCoordinatorError.missingCredential }
        revision &+= 1
        refreshFlight?.task.cancel()
        refreshFlight = nil
        do {
            try tokenStore.saveCredential(.personalAccessToken(token))
        } catch {
            throw GitHubCredentialCoordinatorError.credentialStorageFailed
        }
    }

    /// Shares a single refresh request and persists both rotated tokens as one logical value.
    private func refreshedCredential(from credential: GitHubCredential) async throws -> GitHubCredential {
        guard let oauthClient else {
            throw GitHubCredentialCoordinatorError.missingConfiguration
        }
        let expectedRevision = revision
        let flight: RefreshFlight
        if let refreshFlight {
            flight = refreshFlight
        } else {
            flight = RefreshFlight(task: Task {
                try await oauthClient.refresh(credential)
            })
            refreshFlight = flight
        }
        defer {
            if refreshFlight?.id == flight.id {
                refreshFlight = nil
            }
        }
        do {
            let refreshed = try await flight.task.value
            guard revision == expectedRevision else {
                throw CancellationError()
            }
            let current = try loadCredential()
            if current == credential {
                do {
                    try tokenStore.saveCredential(refreshed)
                } catch {
                    throw GitHubCredentialCoordinatorError.credentialStorageFailed
                }
            } else if current != refreshed {
                throw CancellationError()
            }
            return refreshed
        } catch {
            throw error
        }
    }

    /// Reads one complete credential while normalizing persistence failures.
    private func loadCredential() throws -> GitHubCredential? {
        do {
            return try tokenStore.loadCredential()
        } catch {
            throw GitHubCredentialCoordinatorError.credentialStorageFailed
        }
    }

    /// One identifiable refresh operation so late waiters cannot clear a newer flight.
    private struct RefreshFlight {
        /// Stable identity used when conditionally clearing actor state.
        let id = UUID()
        /// Shared network operation.
        let task: Task<GitHubCredential, Error>
    }
}
