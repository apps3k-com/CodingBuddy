//
//  BackupBrowserTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Discovery and restore coverage for CodingBuddy's backup browser.
@MainActor
@Suite(.serialized)
struct BackupBrowserTests {

    /// Creates an isolated fixture root for backup browser tests.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupBrowserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes UTF-8 text while creating missing parent directories.
    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Returns a discovered backup item by exact backup filename.
    private func item(_ fileName: String, in items: [BackupBrowserItem]) throws -> BackupBrowserItem {
        try #require(items.first { $0.backupURL.lastPathComponent == fileName })
    }

    /// Verifies backup files are grouped by supported logical source files.
    @Test func scannerGroupsSupportedBackupsByLogicalSource() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try write("zsh backup\n", to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333"))
        try write("codex backup\n", to: backups.appendingPathComponent("mcp.env-2026-06-28-001123-333"))
        try write("claude backup\n", to: backups.appendingPathComponent("settings.json-2026-06-28-001124-333"))
        try write("claude local backup\n", to: backups.appendingPathComponent("settings.local.json-2026-06-28-001125-333"))
        try write("cursor backup\n", to: backups.appendingPathComponent("mcp.json-2026-06-28-001126-333"))
        try write("unknown backup\n", to: backups.appendingPathComponent("random-2026-06-28-001127-333"))

        let items = BackupBrowserScanner(homeDirectory: home, backupDirectory: backups).items()

        #expect(items.map(\.backupURL.lastPathComponent) == [
            "random-2026-06-28-001127-333",
            "mcp.json-2026-06-28-001126-333",
            "settings.local.json-2026-06-28-001125-333",
            "settings.json-2026-06-28-001124-333",
            "mcp.env-2026-06-28-001123-333",
            "zshrc-2026-06-28-001122-333",
        ])
        #expect(try item("zshrc-2026-06-28-001122-333", in: items).targetURL == home.appendingPathComponent(".zshrc"))
        #expect(try item("mcp.env-2026-06-28-001123-333", in: items).sourceDisplayName == "Codex mcp.env")
        #expect(try item("settings.json-2026-06-28-001124-333", in: items).targetURL == home.appendingPathComponent(".claude/settings.json"))
        #expect(try item("settings.local.json-2026-06-28-001125-333", in: items).targetURL == home.appendingPathComponent(".claude/settings.local.json"))
        #expect(try item("mcp.json-2026-06-28-001126-333", in: items).targetURL == home.appendingPathComponent(".cursor/mcp.json"))
        #expect(try item("random-2026-06-28-001127-333", in: items).targetURL == nil)
    }

    /// Verifies restore writes through SafeFileWriter and backs up the current target first.
    @Test func storeRestoreCreatesBackupOfCurrentFileBeforeReplacingIt() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let target = home.appendingPathComponent(".zshrc")
        try write("current\n", to: target)
        try write("restored\n", to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333"))
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        try store.restore(backup)

        #expect(try String(contentsOf: target, encoding: .utf8) == "restored\n")
        let entries = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        #expect(entries.contains { $0.lastPathComponent.hasPrefix("zshrc-") && $0.lastPathComponent != backup.backupURL.lastPathComponent })
        let currentBackup = try #require(entries.first { $0.lastPathComponent != backup.backupURL.lastPathComponent })
        #expect(try String(contentsOf: currentBackup, encoding: .utf8) == "current\n")
    }

    /// Verifies restoring Codex credentials recreates missing files with restrictive permissions.
    @Test func storeRestoreCreatesCodexEnvWithRestrictivePermissions() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let target = home.appendingPathComponent(".codex/mcp.env")
        try write("OPENAI_API_KEY=restored\n", to: backups.appendingPathComponent("mcp.env-2026-06-28-001122-333"))
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        try store.restore(backup)

        #expect(try String(contentsOf: target, encoding: .utf8) == "OPENAI_API_KEY=restored\n")
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        )
        #expect(permissions & 0o777 == 0o600)
    }

    /// Verifies restoring through a dotfile symlink updates the target without replacing the link.
    @Test func storeRestorePreservesDotfileSymlink() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let realTarget = root.appendingPathComponent("dotfiles-zshrc")
        let link = home.appendingPathComponent(".zshrc")
        try write("current\n", to: realTarget)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realTarget)
        try write("restored\n", to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333"))
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        try store.restore(backup)

        #expect(try String(contentsOf: realTarget, encoding: .utf8) == "restored\n")
        let linkType = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(linkType == .typeSymbolicLink)
    }

    /// Verifies previews hide obvious secret values without changing restore data.
    @Test func storePreviewRedactsSensitiveValues() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try write(
            """
            export GITHUB_TOKEN=secret
              "api_key": "secret",
            NORMAL=value
            """,
            to: backups.appendingPathComponent("mcp.env-2026-06-28-001122-333")
        )
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        let preview = store.preview(for: backup)

        #expect(preview.backupText.contains("export GITHUB_TOKEN=••••••••"))
        #expect(preview.backupText.contains("  \"api_key\": \"••••••••\","))
        #expect(preview.backupText.contains("NORMAL=value"))
    }

    /// Verifies unsupported backup names are preview-only and cannot be restored.
    @Test func storeRestoreRefusesUnsupportedBackupTargets() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try write("unknown\n", to: backups.appendingPathComponent("random-2026-06-28-001125-333"))
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        #expect(throws: BackupBrowserError.unsupportedBackup) {
            try store.restore(backup)
        }
    }

    /// Verifies restore fails before writing when the target path is not a file.
    @Test func storeRestoreRefusesDirectoryTargets() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".zshrc"), withIntermediateDirectories: true)
        try write("restored\n", to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333"))
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        #expect(throws: BackupBrowserError.targetNotWritable) {
            try store.restore(backup)
        }
    }
}
