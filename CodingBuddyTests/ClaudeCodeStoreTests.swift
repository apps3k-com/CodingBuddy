//
//  ClaudeCodeStoreTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct ClaudeCodeStoreTests {

    private let settingsFixture = """
    {
      "model": "opus",
      "env": {
        "GITHUB_TOKEN": "secret-a",
        "PLAIN": "value"
      },
      "hooks": { "PostToolUse": [] }
    }
    """

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingBuddyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeHome(
        settings: String? = nil, settingsLocal: String? = nil, claudeJSON: String? = nil
    ) throws -> URL {
        let home = try makeTempDir()
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        if let settings {
            try settings.write(
                to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        }
        if let settingsLocal {
            try settingsLocal.write(
                to: claudeDir.appendingPathComponent("settings.local.json"), atomically: true, encoding: .utf8)
        }
        if let claudeJSON {
            try claudeJSON.write(
                to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        }
        return home
    }

    private func makeStore(home: URL) -> ClaudeCodeStore {
        ClaudeCodeStore(homeDirectory: home, backupDirectory: home.appendingPathComponent("Backups"))
    }

    @Test func loadsEnvEntriesFromBothSettingsFiles() throws {
        let home = try makeHome(
            settings: settingsFixture,
            settingsLocal: #"{ "env": { "LOCAL_ONLY": "l" } }"#
        )
        let store = makeStore(home: home)

        #expect(store.envEntries.count == 3)
        #expect(store.envEntries.first { $0.key == "GITHUB_TOKEN" }?.source == .settings)
        #expect(store.envEntries.first { $0.key == "LOCAL_ONLY" }?.source == .settingsLocal)
    }

    @Test func updateRewritesOnlyTheTargetValue() throws {
        let home = try makeHome(settings: settingsFixture)
        let store = makeStore(home: home)
        let entry = try #require(store.envEntries.first { $0.key == "GITHUB_TOKEN" })

        store.update(entry, newValue: "secret-b")

        let url = home.appendingPathComponent(".claude/settings.json")
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content == settingsFixture.replacingOccurrences(of: "\"secret-a\"", with: "\"secret-b\""))
        #expect(store.lastError == nil)
        // Backup written before the change:
        let backups = try FileManager.default.contentsOfDirectory(
            at: home.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
    }

    @Test func updateRejectsExternallyChangedValues() throws {
        let home = try makeHome(settings: settingsFixture)
        let store = makeStore(home: home)
        let entry = try #require(store.envEntries.first { $0.key == "GITHUB_TOKEN" })

        // Simulate Claude Code rewriting the file behind our back.
        let url = home.appendingPathComponent(".claude/settings.json")
        let external = settingsFixture.replacingOccurrences(of: "\"secret-a\"", with: "\"changed-outside\"")
        try external.write(to: url, atomically: true, encoding: .utf8)

        store.update(entry, newValue: "secret-b")

        #expect(store.lastError != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == external)
    }

    @Test func addAndDeleteMutateTheEnvBlock() throws {
        let home = try makeHome(settings: settingsFixture)
        let store = makeStore(home: home)

        store.add(key: "NEW_KEY", value: "new", to: .settings)
        #expect(store.envEntries.contains { $0.key == "NEW_KEY" && $0.source == .settings })

        let entry = try #require(store.envEntries.first { $0.key == "PLAIN" })
        store.delete(entry)
        #expect(!store.envEntries.contains { $0.key == "PLAIN" })
        #expect(store.lastError == nil)
    }

    @Test func addFailsWithoutEnvBlock() throws {
        let home = try makeHome(settings: #"{ "model": "opus" }"#)
        let store = makeStore(home: home)

        store.add(key: "X", value: "1", to: .settings)

        #expect(store.lastError != nil)
        #expect(store.envEntries.isEmpty)
    }

    @Test func serversComeFromUserScopeAndExistingProjectsOnly() throws {
        let home = try makeHome(settings: settingsFixture)
        let project = try makeTempDir()
        try #"{ "mcpServers": { "project-file": { "command": "npx" } } }"#.write(
            to: project.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

        let claudeJSON = """
        {
          "mcpServers": { "user-server": { "type": "http", "url": "https://u.example/mcp" } },
          "projects": {
            "\(project.path)": {
              "mcpServers": { "project-server": { "command": "npx", "env": { "K": "v" } } }
            },
            "/does/not/exist": {
              "mcpServers": { "stale-server": { "command": "gone" } }
            }
          }
        }
        """
        try claudeJSON.write(
            to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let store = makeStore(home: home)

        let names = Set(store.servers.map(\.name))
        #expect(names == ["user-server", "project-server", "project-file"])
        #expect(store.servers.first { $0.name == "user-server" }?.scope == "user")
        #expect(store.servers.first { $0.name == "project-server" }?.scope == project.path)
    }

    @Test func missingFilesYieldEmptyState() throws {
        let home = try makeTempDir()
        let store = makeStore(home: home)
        #expect(!store.directoryExists)
        #expect(store.envEntries.isEmpty)
        #expect(store.servers.isEmpty)
    }

    @Test func duplicateProjectServersDeduplicateWithLocalPrecedence() throws {
        let home = try makeHome(settings: settingsFixture)
        let project = try makeTempDir()
        // Same name in .mcp.json and in ~/.claude.json's project scope:
        try #"{ "mcpServers": { "shared": { "command": "from-mcp-json" } } }"#.write(
            to: project.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        let claudeJSON = """
        {
          "projects": {
            "\(project.path)": {
              "mcpServers": { "shared": { "command": "from-claude-json" } }
            }
          }
        }
        """
        try claudeJSON.write(
            to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let store = makeStore(home: home)

        let shared = store.servers.filter { $0.name == "shared" }
        #expect(shared.count == 1)
        #expect(shared.first?.command == "from-claude-json")
        #expect(Set(store.servers.map(\.id)).count == store.servers.count)
    }
}
