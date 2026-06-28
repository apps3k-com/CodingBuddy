//
//  BackupBrowserItem.swift
//  CodingBuddy
//

import Foundation

/// Known source files that can be restored from CodingBuddy backups.
nonisolated enum BackupBrowserSource: Equatable, Hashable, Sendable {
    /// zsh startup file managed by the main variable editor.
    case shell(ShellConfigFile)
    /// Codex's credential-bearing MCP environment file.
    case codexMCPEnv
    /// Claude Code's global settings file.
    case claudeSettings
    /// Claude Code's local settings override file.
    case claudeLocalSettings
    /// Cursor's user-level MCP server configuration.
    case cursorMCPJSON
    /// Backup name cannot be mapped to a supported CodingBuddy target.
    case unsupported(baseName: String)

    /// Display name used in backup tables and detail views.
    var displayName: String {
        switch self {
        case .shell(let file):
            file.rawValue
        case .codexMCPEnv:
            String(localized: "Codex mcp.env")
        case .claudeSettings:
            String(localized: "Claude Code settings.json")
        case .claudeLocalSettings:
            String(localized: "Claude Code settings.local.json")
        case .cursorMCPJSON:
            String(localized: "Cursor mcp.json")
        case .unsupported:
            String(localized: "Unsupported backup")
        }
    }

    /// POSIX mode used when restore creates a new file for this source.
    var createMode: Int? {
        switch self {
        case .codexMCPEnv:
            0o600
        case .shell, .claudeSettings, .claudeLocalSettings, .cursorMCPJSON, .unsupported:
            nil
        }
    }

    /// Destination URL in the selected home directory, or nil for preview-only backups.
    func targetURL(in homeDirectory: URL) -> URL? {
        switch self {
        case .shell(let file):
            file.url(in: homeDirectory)
        case .codexMCPEnv:
            homeDirectory.appendingPathComponent(".codex", isDirectory: true).appendingPathComponent("mcp.env")
        case .claudeSettings:
            homeDirectory.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent("settings.json")
        case .claudeLocalSettings:
            homeDirectory.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent("settings.local.json")
        case .cursorMCPJSON:
            homeDirectory.appendingPathComponent(".cursor", isDirectory: true).appendingPathComponent("mcp.json")
        case .unsupported:
            nil
        }
    }
}

/// Display-only row for one timestamped CodingBuddy backup file.
nonisolated struct BackupBrowserItem: Identifiable, Equatable, Hashable, Sendable {
    /// Backup file URL inside CodingBuddy's managed backup directory.
    var backupURL: URL
    /// Prefix before the timestamp in the backup filename.
    var baseName: String
    /// Parsed timestamp embedded in the backup filename.
    var timestamp: Date
    /// Optional collision counter appended by `SafeFileWriter`.
    var collisionCounter: Int?
    /// Supported source mapping, or unsupported for preview-only backup files.
    var source: BackupBrowserSource
    /// Destination file URL if CodingBuddy can safely map this backup.
    var targetURL: URL?
    /// Backup file size in bytes, when available.
    var byteCount: Int?
    /// File-system modification date, when available.
    var modifiedAt: Date?
    /// Whether the mapped target currently exists.
    var targetExists: Bool

    /// Stable table identity based on the backup path.
    var id: String {
        backupURL.path
    }

    /// Localized source label shown in the table.
    var sourceDisplayName: String {
        source.displayName
    }

    /// True when this row can be restored without guessing a target path.
    var canRestore: Bool {
        targetURL != nil
    }

    /// Human-readable restore status.
    var statusDisplayName: String {
        canRestore ? String(localized: "Supported") : String(localized: "Preview only")
    }

    /// Search predicate covering source, backup name, target path, and status.
    func matches(searchText: String) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let haystack = [
            sourceDisplayName,
            backupURL.lastPathComponent,
            targetURL?.path ?? "",
            statusDisplayName,
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(trimmed)
    }
}

/// Redacted text preview for a backup and its current target.
nonisolated struct BackupBrowserPreview: Equatable, Sendable {
    /// Redacted backup file contents.
    var backupText: String
    /// Redacted current target contents, or an explanatory placeholder.
    var currentText: String
}
