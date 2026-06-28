//
//  BackupBrowserStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Restore errors surfaced by the backup browser.
nonisolated enum BackupBrowserError: LocalizedError, Equatable, Sendable {
    /// Backup filename cannot be mapped to a known CodingBuddy-managed target.
    case unsupportedBackup
    /// The mapped target exists but is not a regular writable file.
    case targetNotWritable

    /// Localized explanation suitable for alerts.
    var errorDescription: String? {
        switch self {
        case .unsupportedBackup:
            String(localized: "Restore is only available for backups that CodingBuddy can map to a managed file.")
        case .targetNotWritable:
            String(localized: "CodingBuddy cannot safely write to the selected target file.")
        }
    }
}

/// Observable state for browsing and restoring CodingBuddy backup files.
@Observable
final class BackupBrowserStore {
    /// Home directory whose managed files are restore targets.
    let homeDirectory: URL
    /// Directory that contains timestamped CodingBuddy backups.
    let backupDirectory: URL

    /// Latest backup rows in display order.
    private(set) var items: [BackupBrowserItem] = []
    /// Last restore error, surfaced by the UI.
    var lastError: String?

    /// Read-only scanner used for deterministic backup discovery.
    @ObservationIgnored private let scanner: BackupBrowserScanner

    /// Creates a backup browser store without scanning immediately.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupDirectory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodingBuddy/Backups", isDirectory: true)
    ) {
        self.homeDirectory = homeDirectory
        self.backupDirectory = backupDirectory
        self.scanner = BackupBrowserScanner(homeDirectory: homeDirectory, backupDirectory: backupDirectory)
    }

    /// Number of discovered backup files.
    var count: Int {
        items.count
    }

    /// Re-runs backup discovery synchronously.
    func reload() {
        items = scanner.items()
    }

    /// Returns redacted preview text for a backup and its current target.
    func preview(for item: BackupBrowserItem) -> BackupBrowserPreview {
        let backupText = redactedPreviewText(from: item.backupURL)
        let currentText: String
        if let targetURL = item.targetURL {
            if FileManager.default.fileExists(atPath: targetURL.resolvingSymlinksInPath().path) {
                currentText = redactedPreviewText(from: targetURL)
            } else {
                currentText = String(localized: "The target file does not exist yet.")
            }
        } else {
            currentText = String(localized: "No supported restore target.")
        }
        return BackupBrowserPreview(backupText: backupText, currentText: currentText)
    }

    /// Restores a selected backup through `SafeFileWriter`, backing up the current target first.
    func restore(_ item: BackupBrowserItem) throws {
        guard let targetURL = item.targetURL else { throw BackupBrowserError.unsupportedBackup }
        try validateTarget(targetURL)
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let backupContent = try String(contentsOf: item.backupURL, encoding: .utf8)
        try SafeFileWriter(
            backupDirectory: backupDirectory,
            createMode: item.source.createMode
        )
        .write(backupContent, to: targetURL)

        lastError = nil
        reload()
    }

    /// Ensures an existing target is a regular file or symlink to a regular file.
    private func validateTarget(_ targetURL: URL) throws {
        let resolved = targetURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw BackupBrowserError.targetNotWritable
        }
    }

    /// Reads a file for display while hiding obvious secret values.
    private func redactedPreviewText(from url: URL) -> String {
        guard let text = try? String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8) else {
            return String(localized: "Could not read file.")
        }
        return text
            .components(separatedBy: "\n")
            .map(redactedPreviewLine(_:))
            .joined(separator: "\n")
    }

    /// Redacts shell and simple JSON assignment lines whose keys look sensitive.
    private func redactedPreviewLine(_ line: String) -> String {
        if let jsonMatch = line.wholeMatch(of: #/^(\s*"([^"]+)"\s*:\s*)"[^"]*"(.*)$/#),
           SecretDetector.isSensitive(name: String(jsonMatch.2)) {
            return String(jsonMatch.1) + "\"••••••••\"" + String(jsonMatch.3)
        }

        guard let equals = line.firstIndex(of: "=") else { return line }
        let prefix = String(line[..<equals])
        let keyCandidate = prefix
            .replacingOccurrences(of: "export ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyCandidate.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_]*/#) != nil,
              SecretDetector.isSensitive(name: keyCandidate) else {
            return line
        }
        return String(line[...equals]) + "••••••••"
    }
}
