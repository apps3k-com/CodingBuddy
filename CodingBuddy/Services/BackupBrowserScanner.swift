//
//  BackupBrowserScanner.swift
//  CodingBuddy
//

import Foundation

/// Read-only scanner for CodingBuddy's managed backup directory.
nonisolated struct BackupBrowserScanner: Sendable {
    /// Home directory used to resolve known backup basenames back to targets.
    var homeDirectory: URL
    /// Directory where `SafeFileWriter` stores timestamped backups.
    var backupDirectory: URL

    /// Creates a scanner for one home directory and backup directory.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupDirectory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodingBuddy/Backups", isDirectory: true)
    ) {
        self.homeDirectory = homeDirectory
        self.backupDirectory = backupDirectory
    }

    /// Loads parseable backup files, newest first.
    func items() -> [BackupBrowserItem] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap(item(for:))
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp > rhs.timestamp
                }
                return lhs.backupURL.lastPathComponent > rhs.backupURL.lastPathComponent
            }
    }

    /// Creates a backup row for one parseable regular file.
    private func item(for backupURL: URL) -> BackupBrowserItem? {
        guard let parsed = Self.parse(fileName: backupURL.lastPathComponent) else { return nil }
        let values = try? backupURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values?.isRegularFile != false else { return nil }

        let source = source(for: parsed.baseName)
        let targetURL = source.targetURL(in: homeDirectory)
        let targetExists = targetURL
            .map { FileManager.default.fileExists(atPath: $0.resolvingSymlinksInPath().path) } ?? false

        return BackupBrowserItem(
            backupURL: backupURL,
            baseName: parsed.baseName,
            timestamp: parsed.timestamp,
            collisionCounter: parsed.collisionCounter,
            source: source,
            targetURL: targetURL,
            byteCount: values?.fileSize,
            modifiedAt: values?.contentModificationDate,
            targetExists: targetExists
        )
    }

    /// Maps a backup basename to a supported restore target.
    private func source(for baseName: String) -> BackupBrowserSource {
        switch baseName {
        case "zshenv":
            .shell(.zshenv)
        case "zprofile":
            .shell(.zprofile)
        case "zshrc":
            .shell(.zshrc)
        case "mcp.env":
            .codexMCPEnv
        case "settings.json":
            .claudeSettings
        case "settings.local.json":
            .claudeLocalSettings
        case "mcp.json":
            .cursorMCPJSON
        default:
            .unsupported(baseName: baseName)
        }
    }

    /// Parses `baseName-yyyy-MM-dd-HHmmss-SSS[-counter]` backup filenames.
    private static func parse(fileName: String) -> (baseName: String, timestamp: Date, collisionCounter: Int?)? {
        guard let match = fileName.wholeMatch(
            of: #/^(.+)-(\d{4}-\d{2}-\d{2}-\d{6}-\d{3})(?:-(\d+))?$/#
        ) else {
            return nil
        }
        let stamp = String(match.2)
        guard let timestamp = timestampFormatter.date(from: stamp) else { return nil }
        return (
            baseName: String(match.1),
            timestamp: timestamp,
            collisionCounter: match.3.map { Int($0) ?? 0 }
        )
    }

    /// Formatter matching `SafeFileWriter` backup timestamps.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        return formatter
    }()
}
