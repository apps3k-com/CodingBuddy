//
//  CraftAgentStoreTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct CraftAgentStoreTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingBuddyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeCraftDir(
        config: String? = nil, secrets: [String: String] = [:], encryptedBytes: Int? = nil
    ) throws -> URL {
        let craft = try makeTempDir().appendingPathComponent(".craft-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: craft, withIntermediateDirectories: true)
        if let config {
            try config.write(
                to: craft.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        }
        if !secrets.isEmpty {
            let secretsDir = craft.appendingPathComponent("secrets", isDirectory: true)
            try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)
            for (name, content) in secrets {
                try content.write(
                    to: secretsDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        if let encryptedBytes {
            let data = Data(repeating: 0xAB, count: encryptedBytes)
            try data.write(to: craft.appendingPathComponent("credentials.enc"))
        }
        return craft
    }

    @Test func discoversConnectionsSecretsAndEncryptedStore() throws {
        let craft = try makeCraftDir(
            config: """
            {
              "workspaces": [{ "name": "My Workspace", "slug": "my-ws", "id": "w1" }],
              "llmConnections": [
                { "slug": "claude-max", "name": "Claude Max", "providerType": "anthropic" }
              ]
            }
            """,
            secrets: ["msgraph-tokens.json": """
            { "token_type": "Bearer", "expires_in": 4000, "obtained_at": 1780001836 }
            """],
            encryptedBytes: 1234
        )
        let store = CraftAgentStore(craftDirectory: craft)

        #expect(store.directoryExists)
        #expect(store.workspaces.map(\.name) == ["My Workspace"])
        #expect(store.connections.map(\.name) == ["Claude Max"])
        #expect(store.secretFiles.map(\.fileName) == ["msgraph-tokens.json"])
        #expect(store.encryptedStore?.byteCount == 1234)
    }

    @Test func secretExpiryUsesObtainedAtAndExpiresIn() throws {
        // Already expired (obtained 2026-06, expired after 100 s).
        let craft = try makeCraftDir(secrets: ["expired.json": """
        { "expires_in": 100, "obtained_at": 1780001836 }
        """, "no-expiry.json": "{ \"token_type\": \"Bearer\" }"])
        let store = CraftAgentStore(craftDirectory: craft)

        let expired = store.secretFiles.first { $0.fileName == "expired.json" }
        #expect(expired?.status == .expired(Date(timeIntervalSince1970: 1_780_001_936)))
        let incomplete = store.secretFiles.first { $0.fileName == "no-expiry.json" }
        #expect(incomplete?.status == .incomplete)
    }

    @Test func millisecondObtainedAtIsHandled() throws {
        let craft = try makeCraftDir(secrets: ["ms.json": """
        { "expires_in": 100, "obtained_at": 1780001836000 }
        """])
        let store = CraftAgentStore(craftDirectory: craft)
        #expect(store.secretFiles.first?.status == .expired(Date(timeIntervalSince1970: 1_780_001_936)))
    }

    @Test func resetMovesFilesToTrash() throws {
        let craft = try makeCraftDir(
            secrets: ["msgraph-tokens.json": "{}"], encryptedBytes: 10
        )
        var trashed: [URL] = []
        let store = CraftAgentStore(craftDirectory: craft, trashItem: { trashed.append($0) })

        store.resetEncryptedStore()
        #expect(trashed.map(\.lastPathComponent) == ["credentials.enc"])

        let secret = try #require(store.secretFiles.first)
        store.reset(secret)
        #expect(trashed.map(\.lastPathComponent) == ["credentials.enc", "msgraph-tokens.json"])
        #expect(store.lastError == nil)
    }

    @Test func missingDirectoryYieldsEmptyState() throws {
        let store = CraftAgentStore(
            craftDirectory: try makeTempDir().appendingPathComponent(".craft-agent"))
        #expect(!store.directoryExists)
        #expect(store.connections.isEmpty)
        #expect(store.secretFiles.isEmpty)
        #expect(store.encryptedStore == nil)
    }
}
