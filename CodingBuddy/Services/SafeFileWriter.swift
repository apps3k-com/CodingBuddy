//
//  SafeFileWriter.swift
//  CodingBuddy
//

import Foundation

/// The write-safety machinery shared by every store that mutates user files:
/// timestamped backup with retention, atomic replace, symlink-safe,
/// POSIX-permission preservation — plus a mode for newly created files.
nonisolated struct SafeFileWriter {
    var backupDirectory: URL
    var backupRetention = 20
    /// POSIX mode applied when the write creates a brand-new file (e.g. 0o600
    /// for credential-bearing env files). Existing permissions always win.
    var createMode: Int?

    init(backupDirectory: URL, backupRetention: Int = 20, createMode: Int? = nil) {
        self.backupDirectory = backupDirectory
        self.backupRetention = backupRetention
        self.createMode = createMode
    }

    /// No-ops when the content is unchanged; otherwise backs up the current
    /// file, writes atomically to the symlink target and restores its POSIX
    /// permissions (or applies `createMode` to brand-new files).
    func write(_ content: String, to fileURL: URL) throws {
        let fileManager = FileManager.default
        let resolved = fileURL.resolvingSymlinksInPath()

        let exists = fileManager.fileExists(atPath: resolved.path)
        if exists, try String(contentsOf: resolved, encoding: .utf8) == content {
            return
        }

        var permissions: Any?
        if exists {
            permissions = (try? fileManager.attributesOfItem(atPath: resolved.path))?[.posixPermissions]
            try backUp(resolved)
        }

        try content.write(to: resolved, atomically: true, encoding: .utf8)

        // Permission failures must surface: a credential file silently left
        // world-readable would defeat the createMode guarantee.
        if let permissions {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: resolved.path)
        } else if let createMode {
            try fileManager.setAttributes([.posixPermissions: createMode], ofItemAtPath: resolved.path)
        }
    }

    // MARK: - Backups

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        return formatter
    }()

    private func backUp(_ resolved: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        // ".zshrc" → "zshrc" so backups are not hidden files.
        let baseName = String(resolved.lastPathComponent.drop(while: { $0 == "." }))
        let stamp = Self.timestampFormatter.string(from: Date())
        var target = backupDirectory.appendingPathComponent("\(baseName)-\(stamp)")
        var counter = 1
        while fileManager.fileExists(atPath: target.path) {
            target = backupDirectory.appendingPathComponent("\(baseName)-\(stamp)-\(counter)")
            counter += 1
        }
        try fileManager.copyItem(at: resolved, to: target)
        pruneBackups(baseName: baseName)
    }

    private func pruneBackups(baseName: String) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        let backups = entries
            .filter { $0.lastPathComponent.hasPrefix("\(baseName)-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for stale in backups.dropLast(backupRetention) {
            try? fileManager.removeItem(at: stale)
        }
    }
}
