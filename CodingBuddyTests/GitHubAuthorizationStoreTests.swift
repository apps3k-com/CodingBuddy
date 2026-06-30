//
//  GitHubAuthorizationStoreTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Tests token-safe state transitions in `GitHubAuthorizationStore`.
@MainActor
struct GitHubAuthorizationStoreTests {

    /// Verifies existing tokens produce an authorized state without leaking the token.
    @Test func authorizationStoreReportsExistingTokenWithoutExposingIt() {
        let tokenStore = MemoryGitHubAuthorizationTokenStore(token: "github_pat_secret")
        let store = GitHubAuthorizationStore(tokenStore: tokenStore)

        #expect(store.state == .authorized)
        #expect(store.hasSavedToken)
        #expect(!store.debugDescription.contains("github_pat_secret"))
    }

    /// Verifies stored blank values are treated as missing credentials.
    @Test func authorizationStoreTreatsWhitespaceOnlyStoredTokenAsMissing() {
        let tokenStore = MemoryGitHubAuthorizationTokenStore(token: "   \n ")
        let store = GitHubAuthorizationStore(tokenStore: tokenStore)

        #expect(store.state == .missing)
        #expect(!store.hasSavedToken)
    }

    /// Verifies load failures use read-specific token-safe UI state.
    @Test func authorizationStoreLoadFailureReportsReadFailure() {
        let store = GitHubAuthorizationStore(tokenStore: LoadFailingGitHubAuthorizationTokenStore())

        #expect(store.state == .failed(.tokenLoadFailed))
        #expect(!store.hasSavedToken)
        #expect(!store.debugDescription.contains("github_pat_secret"))
    }

    /// Verifies saved tokens are trimmed before storage.
    @Test func authorizationStoreSavesTrimmedTokenAndReportsAuthorizedState() {
        let tokenStore = MemoryGitHubAuthorizationTokenStore(token: nil)
        let store = GitHubAuthorizationStore(tokenStore: tokenStore)

        let didSave = store.saveToken("  github_pat_secret  ")

        #expect(didSave)
        #expect(tokenStore.savedToken == "github_pat_secret")
        #expect(store.state == .authorized)
        #expect(store.hasSavedToken)
        #expect(!store.debugDescription.contains("github_pat_secret"))
    }

    /// Verifies blank saves do not hide or overwrite an existing token.
    @Test func authorizationStoreRejectsBlankSaveWithoutHidingExistingToken() {
        let tokenStore = MemoryGitHubAuthorizationTokenStore(token: "github_pat_existing")
        let store = GitHubAuthorizationStore(tokenStore: tokenStore)

        let didSave = store.saveToken(" \n\t ")

        #expect(!didSave)
        #expect(tokenStore.savedToken == "github_pat_existing")
        #expect(store.state == .authorized)
        #expect(store.hasSavedToken)
    }

    /// Verifies deleting a token clears the visible authorization state.
    @Test func authorizationStoreDeletesTokenAndReportsMissingState() {
        let tokenStore = MemoryGitHubAuthorizationTokenStore(token: "github_pat_secret")
        let store = GitHubAuthorizationStore(tokenStore: tokenStore)

        let didDelete = store.deleteToken()

        #expect(didDelete)
        #expect(tokenStore.savedToken == nil)
        #expect(store.state == .missing)
        #expect(!store.hasSavedToken)
    }

    /// Verifies storage failures never expose token-like text in debug output.
    @Test func authorizationStoreFailureStateStaysTokenSafe() {
        let store = GitHubAuthorizationStore(tokenStore: FailingGitHubAuthorizationTokenStore())

        let didSave = store.saveToken("github_pat_secret")

        #expect(!didSave)
        #expect(store.state == .failed(.tokenStorageFailed))
        #expect(!store.debugDescription.contains("github_pat_secret"))
    }
}

/// Token store that fails while loading the saved token.
private struct LoadFailingGitHubAuthorizationTokenStore: GitHubTokenStore {
    /// Always throws a token-like error to exercise sanitization.
    func loadToken() throws -> String? {
        throw Failure()
    }

    /// Saves are unused for this test double.
    func saveToken(_ token: String) throws {}

    /// Deletes are unused for this test double.
    func deleteToken() throws {}

    /// Synthetic load failure with secret-looking text.
    private struct Failure: LocalizedError {
        /// Error text intentionally includes a fake token.
        var errorDescription: String? {
            "keychain failed for github_pat_secret"
        }
    }
}

/// In-memory GitHub token store for authorization settings tests.
private final class MemoryGitHubAuthorizationTokenStore: GitHubTokenStore, @unchecked Sendable {
    /// Token returned by `loadToken()`.
    private var token: String?

    /// Creates the store with an optional token.
    init(token: String?) {
        self.token = token
    }

    /// Current raw test token value.
    var savedToken: String? {
        token
    }

    /// Returns the current in-memory token.
    func loadToken() throws -> String? {
        token
    }

    /// Stores the token in memory.
    func saveToken(_ token: String) throws {
        self.token = token
    }

    /// Removes the in-memory token.
    func deleteToken() throws {
        token = nil
    }
}

/// Token store that fails every persistence operation.
private struct FailingGitHubAuthorizationTokenStore: GitHubTokenStore {
    /// Returns no token so tests can focus on failure transitions.
    func loadToken() throws -> String? {
        nil
    }

    /// Always throws a token-like error to exercise sanitization.
    func saveToken(_ token: String) throws {
        throw Failure()
    }

    /// Always throws a token-like error to exercise sanitization.
    func deleteToken() throws {
        throw Failure()
    }

    /// Synthetic persistence failure with secret-looking text.
    private struct Failure: LocalizedError {
        /// Error text intentionally includes a fake token.
        var errorDescription: String? {
            "keychain failed for github_pat_secret"
        }
    }
}
