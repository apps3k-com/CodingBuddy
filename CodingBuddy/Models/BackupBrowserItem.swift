//
//  BackupBrowserItem.swift
//  CodingBuddy
//

import Foundation

/// Safety reason that prevents a discovered backup from being previewed or restored.
nonisolated enum BackupBrowserRejection: Equatable, Hashable, Sendable {
    /// File ownership, permissions, type, or metadata did not satisfy the backup policy.
    case unsafeMetadata
    /// File metadata reports more bytes than the explicit backup input ceiling.
    case exceedsSizeLimit(maximumByteCount: Int)

    /// Localized explanation shown when the backup remains visible but inaccessible.
    var explanation: String {
        switch self {
        case .unsafeMetadata:
            return String(localized: "This backup did not pass CodingBuddy's ownership and permission checks. It was not read and cannot be restored.")
        case .exceedsSizeLimit(let maximumByteCount):
            let limit = ByteCountFormatter.string(
                fromByteCount: Int64(maximumByteCount),
                countStyle: .file
            )
            return String(localized: "This backup exceeds CodingBuddy's \(limit) safety limit. It was not read and cannot be restored.")
        }
    }
}

/// Validated access state retained for every parseable regular backup artifact.
nonisolated enum BackupBrowserAccessState: Equatable, Hashable, Sendable {
    /// Stable no-follow metadata permits lazy preview and restore capture.
    case available(SecureInputMetadata)
    /// The artifact remains visible, but security validation denied content access.
    case rejected(BackupBrowserRejection)

    /// Stable metadata for accessible backups only.
    var secureMetadata: SecureInputMetadata? {
        guard case .available(let metadata) = self else { return nil }
        return metadata
    }

    /// Safety reason for rejected backups only.
    var rejection: BackupBrowserRejection? {
        guard case .rejected(let reason) = self else { return nil }
        return reason
    }
}

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
        case .shell, .codexMCPEnv, .claudeSettings, .claudeLocalSettings, .cursorMCPJSON:
            0o600
        case .unsupported:
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
    /// Validated metadata or an explicit reason content access was rejected.
    var accessState: BackupBrowserAccessState

    /// Stable table identity based on the backup path.
    var id: String {
        backupURL.path
    }

    /// Localized source label shown in the table.
    var sourceDisplayName: String {
        source.displayName
    }

    /// Stable no-follow metadata used to reject replacements before preview or restore.
    var secureMetadata: SecureInputMetadata? {
        accessState.secureMetadata
    }

    /// Safety reason when this artifact cannot be previewed or restored.
    var rejectionReason: BackupBrowserRejection? {
        accessState.rejection
    }

    /// True when content can be captured lazily under the backup input policy.
    var canPreview: Bool {
        secureMetadata != nil
    }

    /// True when this row can be restored without guessing a target path.
    var canRestore: Bool {
        targetURL != nil && canPreview
    }

    /// Human-readable restore status.
    var statusDisplayName: String {
        if rejectionReason != nil {
            String(localized: "Rejected")
        } else if canRestore {
            String(localized: "Supported")
        } else {
            String(localized: "Preview only")
        }
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
            rejectionReason?.explanation ?? "",
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(trimmed)
    }
}

/// Display-safe content for one side of a backup comparison.
nonisolated enum BackupBrowserPreviewContent: Equatable, Sendable {
    /// Content whose sensitive values were structurally redacted.
    case redacted(String)
    /// A non-sensitive explanation, such as an unavailable-file message.
    case message(String)
    /// The complete document was withheld because safe redaction was ambiguous.
    case suppressedForSafety

    /// Opaque text retained for non-visual consumers and regression assertions.
    var text: String {
        switch self {
        case let .redacted(text), let .message(text):
            text
        case .suppressedForSafety:
            "••••••••"
        }
    }
}

/// Redacted content preview for a backup and its current target.
nonisolated struct BackupBrowserPreview: Equatable, Sendable {
    /// Display-safe backup file contents.
    var backup: BackupBrowserPreviewContent
    /// Display-safe current target contents, or an explanatory placeholder.
    var current: BackupBrowserPreviewContent

    /// Opaque backup text retained for non-visual consumers and tests.
    var backupText: String { backup.text }
    /// Opaque current-target text retained for non-visual consumers and tests.
    var currentText: String { current.text }
}
