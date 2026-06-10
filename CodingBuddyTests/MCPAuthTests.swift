//
//  MCPAuthTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct MCPAuthTests {

    private let serverURL = "https://gtm.example.com/mcp"

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPAuthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds an ~/.mcp-auth lookalike: one resolved entry with tokens, one
    /// incomplete entry, one expired entry.
    private func makeFixtureRoot(in dir: URL) throws -> (root: URL, hash: String) {
        let root = dir.appendingPathComponent(".mcp-auth", isDirectory: true)
        let version = root.appendingPathComponent("mcp-remote-9.9.9", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)

        let hash = MCPAuthScanner.md5Hex(serverURL)
        let tokens = #"{"access_token":"a-token","refresh_token":"r-token","token_type":"bearer","expires_in":3600,"scope":"read write"}"#
        let clientInfo = #"{"client_id":"abc","client_name":"MCP CLI Proxy"}"#

        try tokens.write(to: version.appendingPathComponent("\(hash)_tokens.json"), atomically: true, encoding: .utf8)
        try clientInfo.write(to: version.appendingPathComponent("\(hash)_client_info.json"), atomically: true, encoding: .utf8)
        try "verifier".write(to: version.appendingPathComponent("\(hash)_code_verifier.txt"), atomically: true, encoding: .utf8)

        let incompleteHash = String(repeating: "ab", count: 16)
        try clientInfo.write(to: version.appendingPathComponent("\(incompleteHash)_client_info.json"), atomically: true, encoding: .utf8)

        let expiredHash = String(repeating: "cd", count: 16)
        let expiredTokens = #"{"access_token":"x","expires_in":-60,"scope":"openid"}"#
        try expiredTokens.write(to: version.appendingPathComponent("\(expiredHash)_tokens.json"), atomically: true, encoding: .utf8)

        return (root, hash)
    }

    // MARK: - Scanner

    @Test func md5MatchesMCPRemoteHashing() {
        // Real-world vector: mcp-remote's file prefix for this server URL.
        #expect(MCPAuthScanner.md5Hex("https://gtm-mcp.stape.ai/mcp") == "d097dd57096938e420847d7e05ce995f")
    }

    @Test func scanGroupsResolvesAndClassifiesEntries() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)

        let entries = MCPAuthScanner.scan(root: root, knownServerURLs: [serverURL])
        #expect(entries.count == 3)

        let resolved = try #require(entries.first { $0.hash == hash })
        #expect(resolved.serverURL == serverURL)
        #expect(resolved.displayName == serverURL)
        #expect(resolved.scope == "read write")
        #expect(resolved.files.count == 3)
        #expect(resolved.status == .active(expiry: resolved.accessTokenExpiry))
        #expect(try #require(resolved.accessTokenExpiry) > Date())

        let incomplete = try #require(entries.first { $0.hash.hasPrefix("abab") })
        #expect(incomplete.serverURL == nil)
        #expect(incomplete.status == .incomplete)

        let expired = try #require(entries.first { $0.hash.hasPrefix("cdcd") })
        #expect(expired.status == .expired(try #require(expired.accessTokenExpiry)))
    }

    @Test func configuredServerURLsAreFoundInClaudeConfig() throws {
        let home = try makeTempDir()
        let config = #"{"mcpServers":{"gtm":{"command":"npx","args":["mcp-remote","\#(serverURL)"]}}}"#
        try config.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let urls = MCPAuthScanner.configuredServerURLs(homeDirectory: home)
        #expect(urls.contains(serverURL))
    }

    // MARK: - Store

    @Test func resetMovesAllEntryFilesAway() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)

        let store = MCPAuthStore(
            rootDirectory: root,
            configHomeDirectory: dir,
            trashItem: { try FileManager.default.removeItem(at: $0) }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })

        store.reset(entry)

        #expect(store.lastError == nil)
        #expect(!store.entries.contains { $0.hash == hash })
        #expect(store.entries.count == 2)
    }

    @Test func resetAllEmptiesTheRoot() throws {
        let dir = try makeTempDir()
        let (root, _) = try makeFixtureRoot(in: dir)

        let store = MCPAuthStore(
            rootDirectory: root,
            configHomeDirectory: dir,
            trashItem: { try FileManager.default.removeItem(at: $0) }
        )
        #expect(!store.entries.isEmpty)

        store.resetAll()

        #expect(store.lastError == nil)
        #expect(store.entries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func saveRejectsInvalidJSON() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let store = MCPAuthStore(
            rootDirectory: root,
            configHomeDirectory: dir,
            trashItem: { try FileManager.default.removeItem(at: $0) }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })
        let tokens = try #require(entry.files.first { $0.kind == .tokens })
        let original = try store.contents(of: tokens)

        store.save("{not json", to: tokens)

        #expect(store.lastError != nil)
        #expect(try store.contents(of: tokens) == original)
    }

    // MARK: - Redactor

    @Test func redactorMasksSecretBearingKeysOnly() {
        let preview = MCPAuthRedactor.maskedPreview(
            text: #"{"access_token":"SECRETVALUE","scope":"read","client_id":"abc"}"#,
            isJSON: true
        )
        #expect(!preview.contains("SECRETVALUE"))
        #expect(preview.contains("••••••••"))
        #expect(preview.contains("read"))
        #expect(preview.contains("abc"))
    }

    @Test func redactorMasksNonJSONEntirely() {
        let preview = MCPAuthRedactor.maskedPreview(text: "raw-verifier-value", isJSON: false)
        #expect(preview == "••••••••")
    }
}
