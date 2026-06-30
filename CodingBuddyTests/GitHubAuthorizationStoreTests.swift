//
//  GitHubAuthorizationStoreTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct GitHubAuthorizationStoreTests {

    @Test func authorizationStoreReportsExistingTokenWithoutExposingIt() {
        let tokenStore = MemoryGitHubAuthorizationTokenStore(token: "github_pat_secret")
        let store = GitHubAuthorizationStore(tokenStore: tokenStore)

        #expect(store.state == .authorized)
        #expect(store.hasSavedToken)
        #expect(!store.debugDescription.contains("github_pat_secret"))
    }

    @Test func authorizationStoreTreatsWhitespaceOnlyStoredTokenAsMissing() {
        let tokenStore = MemoryGitHubAuthorizationTokenStore(token: "   \n ")
        let store = GitHubAuthorizationStore(tokenStore: tokenStore)

        #expect(store.state == .missing)
        #expect(!store.hasSavedToken)
    }

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

    @Test func authorizationStoreDeletesTokenAndReportsMissingState() {
        let tokenStore = MemoryGitHubAuthorizationTokenStore(token: "github_pat_secret")
        let store = GitHubAuthorizationStore(tokenStore: tokenStore)

        let didDelete = store.deleteToken()

        #expect(didDelete)
        #expect(tokenStore.savedToken == nil)
        #expect(store.state == .missing)
        #expect(!store.hasSavedToken)
    }

    @Test func authorizationStoreFailureStateStaysTokenSafe() {
        let store = GitHubAuthorizationStore(tokenStore: FailingGitHubAuthorizationTokenStore())

        let didSave = store.saveToken("github_pat_secret")

        #expect(!didSave)
        #expect(store.state == .failed(.tokenStorageFailed))
        #expect(!store.debugDescription.contains("github_pat_secret"))
    }
}

private final class MemoryGitHubAuthorizationTokenStore: GitHubTokenStore, @unchecked Sendable {
    private var token: String?

    init(token: String?) {
        self.token = token
    }

    var savedToken: String? {
        token
    }

    func loadToken() throws -> String? {
        token
    }

    func saveToken(_ token: String) throws {
        self.token = token
    }

    func deleteToken() throws {
        token = nil
    }
}

private struct FailingGitHubAuthorizationTokenStore: GitHubTokenStore {
    func loadToken() throws -> String? {
        nil
    }

    func saveToken(_ token: String) throws {
        throw Failure()
    }

    func deleteToken() throws {
        throw Failure()
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? {
            "keychain failed for github_pat_secret"
        }
    }
}
