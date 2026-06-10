//
//  CodexStoreTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct CodexStoreTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingBuddyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeCodexDir(
        mcpEnv: String? = nil, configTOML: String? = nil
    ) throws -> (home: URL, codex: URL) {
        let home = try makeTempDir()
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        if let mcpEnv {
            let url = codex.appendingPathComponent("mcp.env")
            try mcpEnv.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if let configTOML {
            try configTOML.write(
                to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        }
        return (home, codex)
    }

    private func makeStore(home: URL) -> CodexStore {
        CodexStore(codexDirectory: home.appendingPathComponent(".codex", isDirectory: true),
                   backupDirectory: home.appendingPathComponent("Backups"))
    }

    @Test func loadsVariablesAndServers() throws {
        let (home, _) = try makeCodexDir(
            mcpEnv: "# codex env\nAPPS3K_MCP_AUTH_TOKEN=secret\n",
            configTOML: """
            [mcp_servers.apps3k]
            url = "https://example.com/mcp"
            bearer_token_env_var = "APPS3K_MCP_AUTH_TOKEN"
            """
        )
        let store = makeStore(home: home)

        #expect(store.directoryExists)
        #expect(store.variables.map(\.name) == ["APPS3K_MCP_AUTH_TOKEN"])
        #expect(store.servers.map(\.name) == ["apps3k"])
        #expect(store.missingEnvVarNames.isEmpty)
    }

    @Test func reportsReferencedButUndefinedVariables() throws {
        let (home, _) = try makeCodexDir(
            mcpEnv: "OTHER=1\n",
            configTOML: """
            [mcp_servers.apps3k]
            url = "https://example.com/mcp"
            bearer_token_env_var = "MISSING_TOKEN"
            """
        )
        let store = makeStore(home: home)
        #expect(store.missingEnvVarNames == ["MISSING_TOKEN"])
    }

    @Test func editPreservesCommentsAndPermissions() throws {
        let (home, codex) = try makeCodexDir(
            mcpEnv: "# keep this comment\nTOKEN_A=old\n\nTOKEN_B=other\n"
        )
        let store = makeStore(home: home)
        let variable = try #require(store.variables.first { $0.name == "TOKEN_A" })

        store.update(variable, name: "TOKEN_A", rawValue: "new")

        let url = codex.appendingPathComponent("mcp.env")
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("# keep this comment"))
        #expect(content.contains("TOKEN_A=new") || content.contains("TOKEN_A=\"new\""))
        #expect(content.contains("TOKEN_B=other"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(store.lastError == nil)
    }

    @Test func addCreatesFileWithRestrictiveMode() throws {
        let home = try makeTempDir()
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let store = makeStore(home: home)

        store.add(name: "NEW_TOKEN", rawValue: "abc")

        let url = codex.appendingPathComponent("mcp.env")
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("NEW_TOKEN=\"abc\""))
        #expect(!content.contains("export NEW_TOKEN"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func missingDirectoryIsReported() throws {
        let home = try makeTempDir()
        let store = makeStore(home: home)
        #expect(!store.directoryExists)
        #expect(store.variables.isEmpty)
        #expect(store.servers.isEmpty)
    }

    @Test func deleteRemovesOnlyTheTargetLine() throws {
        let (home, codex) = try makeCodexDir(mcpEnv: "A=1\nB=2\nC=3\n")
        let store = makeStore(home: home)
        let b = try #require(store.variables.first { $0.name == "B" })

        store.delete(b)

        let content = try String(
            contentsOf: codex.appendingPathComponent("mcp.env"), encoding: .utf8)
        #expect(content == "A=1\nC=3\n")
    }
}
