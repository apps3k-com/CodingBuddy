//
//  CursorStoreTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct CursorStoreTests {

    private let fixture = """
    {
      "mcpServers": {
        "shopify": {
          "command": "npx",
          "args": ["-y", "@shopify/dev-mcp@latest"],
          "env": {
            "API_TOKEN": "secret-a",
            "PLAIN": "value"
          }
        },
        "linear": {
          "type": "http",
          "url": "https://mcp.linear.app/mcp"
        }
      }
    }
    """

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingBuddyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeHome(mcpJSON: String? = nil) throws -> URL {
        let home = try makeTempDir()
        let cursor = home.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        if let mcpJSON {
            let url = cursor.appendingPathComponent("mcp.json")
            try mcpJSON.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return home
    }

    private func makeStore(home: URL) -> CursorStore {
        CursorStore(
            cursorDirectory: home.appendingPathComponent(".cursor", isDirectory: true),
            backupDirectory: home.appendingPathComponent("Backups")
        )
    }

    @Test func loadsServersAndEnvEntries() throws {
        let store = makeStore(home: try makeHome(mcpJSON: fixture))

        #expect(store.servers.map(\.name).sorted() == ["linear", "shopify"])
        #expect(store.envEntries.count == 2)
        #expect(store.envEntries.allSatisfy { $0.server == "shopify" })
    }

    @Test func updateRewritesOnlyTheTargetValueAndKeepsPermissions() throws {
        let home = try makeHome(mcpJSON: fixture)
        let store = makeStore(home: home)
        let entry = try #require(store.envEntries.first { $0.key == "API_TOKEN" })

        store.update(entry, newValue: "secret-b")

        let url = home.appendingPathComponent(".cursor/mcp.json")
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content == fixture.replacingOccurrences(of: "\"secret-a\"", with: "\"secret-b\""))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(store.lastError == nil)
    }

    @Test func updateRejectsExternallyChangedValues() throws {
        let home = try makeHome(mcpJSON: fixture)
        let store = makeStore(home: home)
        let entry = try #require(store.envEntries.first { $0.key == "API_TOKEN" })

        let url = home.appendingPathComponent(".cursor/mcp.json")
        let external = fixture.replacingOccurrences(of: "\"secret-a\"", with: "\"outside\"")
        try external.write(to: url, atomically: true, encoding: .utf8)

        store.update(entry, newValue: "secret-b")

        #expect(store.lastError != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == external)
    }

    @Test func addAndDeleteMutateTheServerEnv() throws {
        let home = try makeHome(mcpJSON: fixture)
        let store = makeStore(home: home)

        store.add(key: "NEW_KEY", value: "new", toServer: "shopify")
        #expect(store.envEntries.contains { $0.key == "NEW_KEY" && $0.server == "shopify" })

        let entry = try #require(store.envEntries.first { $0.key == "PLAIN" })
        store.delete(entry)
        #expect(!store.envEntries.contains { $0.key == "PLAIN" })
        #expect(store.lastError == nil)
    }

    @Test func addFailsForServerWithoutEnvObject() throws {
        let store = makeStore(home: try makeHome(mcpJSON: fixture))

        store.add(key: "X", value: "1", toServer: "linear")

        #expect(store.lastError != nil)
    }

    @Test func missingDirectoryYieldsEmptyState() throws {
        let store = makeStore(home: try makeTempDir())
        #expect(!store.directoryExists)
        #expect(store.servers.isEmpty)
        #expect(store.envEntries.isEmpty)
    }
}
