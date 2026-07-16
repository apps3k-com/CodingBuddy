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
    /// The selected backup no longer matches the owned regular file captured during discovery.
    case backupChanged
    /// The mapped target exists but is not a regular writable file.
    case targetNotWritable

    /// Localized explanation suitable for alerts.
    var errorDescription: String? {
        switch self {
        case .unsupportedBackup:
            String(localized: "Restore is only available for backups that CodingBuddy can map to a managed file.")
        case .backupChanged:
            String(localized: "The file was changed externally. Please try again.")
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
    /// Discovery refusal that explains why no partial backup inventory is exposed.
    private(set) var discoveryError: BackupBrowserScanner.ScanError?
    /// Last restore error, surfaced by the UI.
    var lastError: String?

    /// Read-only scanner used for deterministic backup discovery.
    @ObservationIgnored private let scanner: BackupBrowserScanner
    /// Internal transaction hook used to reproduce restore races in tests.
    @ObservationIgnored private let restoreTransactionHook: ((SafeFileWriter.TransactionPoint) throws -> Void)?

    /// Dotfiles and configuration backups above 8 MiB are rejected as implausible input.
    nonisolated static let maximumBackupFileSize = 8 * 1024 * 1024

    /// Creates a backup browser store without scanning immediately.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupDirectory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodingBuddy/Backups", isDirectory: true),
        maximumDirectoryEntryCount: Int = BackupBrowserScanner.defaultMaximumDirectoryEntryCount,
        restoreTransactionHook: ((SafeFileWriter.TransactionPoint) throws -> Void)? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.backupDirectory = backupDirectory
        self.scanner = BackupBrowserScanner(
            homeDirectory: homeDirectory,
            backupDirectory: backupDirectory,
            maximumDirectoryEntryCount: maximumDirectoryEntryCount
        )
        self.restoreTransactionHook = restoreTransactionHook
    }

    /// Number of discovered backup files.
    var count: Int {
        items.count
    }

    /// Re-runs backup discovery synchronously.
    func reload() {
        let candidates: [BackupBrowserItem]
        do {
            candidates = try scanner.items()
        } catch let error as BackupBrowserScanner.ScanError {
            items = []
            discoveryError = error
            return
        } catch {
            items = []
            discoveryError = .directoryUnavailable
            return
        }

        items = candidates
        discoveryError = nil
    }

    /// Returns redacted preview text for a backup and its current target.
    func preview(for item: BackupBrowserItem) -> BackupBrowserPreview {
        guard let selectedItem = items.first(where: { $0.id == item.id }),
              selectedItem == item
        else {
            return BackupBrowserPreview(
                backupText: String(localized: "Could not read file."),
                currentText: String(localized: "Could not read file.")
            )
        }

        guard let secureMetadata = selectedItem.secureMetadata else {
            let explanation = selectedItem.rejectionReason?.explanation
                ?? String(localized: "Could not read file.")
            return BackupBrowserPreview(backupText: explanation, currentText: explanation)
        }

        let backupText: String
        if let snapshot = try? SecureInputReader.capture(
                at: selectedItem.backupURL,
                matching: secureMetadata,
                maximumByteCount: Self.maximumBackupFileSize,
                policy: .backup
           ), let text = String(data: snapshot.data, encoding: .utf8) {
            backupText = redactedPreviewText(text, source: selectedItem.source)
        } else {
            backupText = String(localized: "Could not read file.")
        }

        let currentText: String
        if let targetURL = selectedItem.targetURL {
            if FileManager.default.fileExists(atPath: targetURL.resolvingSymlinksInPath().path) {
                currentText = currentPreviewText(from: targetURL, source: selectedItem.source)
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
        guard let selectedItem = items.first(where: { $0.id == item.id }),
              selectedItem == item
        else {
            throw BackupBrowserError.backupChanged
        }
        guard let targetURL = selectedItem.targetURL else { throw BackupBrowserError.unsupportedBackup }
        guard let secureMetadata = selectedItem.secureMetadata else {
            throw BackupBrowserError.backupChanged
        }
        let backupSnapshot: SecureInputSnapshot
        do {
            backupSnapshot = try SecureInputReader.capture(
                at: selectedItem.backupURL,
                matching: secureMetadata,
                maximumByteCount: Self.maximumBackupFileSize,
                policy: .backup
            )
        } catch {
            throw BackupBrowserError.backupChanged
        }
        try validateTarget(targetURL)
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writer = SafeFileWriter(
            backupDirectory: backupDirectory,
            createMode: selectedItem.source.createMode,
            transactionHook: restoreTransactionHook
        )
        let targetSnapshot = try writer.snapshot(at: targetURL)
        guard let backupContent = String(data: backupSnapshot.data, encoding: .utf8) else {
            throw BackupBrowserError.backupChanged
        }
        try writer.write(backupContent, using: targetSnapshot)

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

    /// Reads a current target with the same bounded regular-file policy used for backups.
    private func currentPreviewText(from url: URL, source: BackupBrowserSource) -> String {
        guard let snapshot = try? SecureInputReader.capture(
            at: url.resolvingSymlinksInPath(),
            maximumByteCount: Self.maximumBackupFileSize,
            policy: .backup
        ), let text = String(data: snapshot.data, encoding: .utf8) else {
            return String(localized: "Could not read file.")
        }
        return redactedPreviewText(text, source: source)
    }

    /// Redacts structured JSON as a whole document and shell assignments line by line.
    private func redactedPreviewText(_ text: String, source: BackupBrowserSource) -> String {
        if source.containsJSON {
            return MCPAuthRedactor.maskedPreview(
                text: text,
                isJSON: true,
                policy: .backupPreview
            )
        }
        return text
            .components(separatedBy: "\n")
            .map(redactedShellPreviewLine(_:))
            .joined(separator: "\n")
    }

    /// Redacts one ordinary shell assignment without reconstructing JSON-like input.
    private func redactedShellPreviewLine(_ line: String) -> String {
        BackupShellPreviewRedactor.redact(line)
    }
}

/// Produces display-only shell lines without exposing any assignment value.
///
/// Editable assignment parsing remains owned by `ShellConfigParser`. This redactor adds a
/// deliberately broader fallback because preview safety must also cover declaration builtins,
/// malformed quotes, compound statements, indexed parameters, and append assignments.
nonisolated enum BackupShellPreviewRedactor {
    /// Stable replacement used for every hidden shell value or ambiguous assignment-bearing line.
    private static let mask = "••••••••"
    /// Declaration header whose non-value syntax can be retained before fail-closed masking.
    private static let declarationPattern = #/^(?<prefix>[ \t]*(?:(?:builtin|command)[ \t]+)?(?:typeset|readonly|export)[ \t]+(?:(?:[+-][A-Za-z]+|--)[ \t]+)*(?<name>[A-Za-z_][A-Za-z0-9_]*)[ \t]*=)(?<rest>.*)$/#
    /// Simple indexed or append assignment whose name/operator structure is unambiguous.
    private static let extendedAssignmentPattern = #/^(?<prefix>[ \t]*(?<name>[A-Za-z_][A-Za-z0-9_]*)(?:\[[A-Za-z0-9_.-]+\])?[ \t]*(?:\+=|=))(?<rest>.*)$/#

    /// Redacts an assignment while preserving syntax only when its prefix is unambiguous.
    static func redact(_ line: String) -> String {
        if let assignment = ShellConfigParser.parseLine(line),
           let equals = line.firstIndex(of: "=") {
            return redactParsedAssignment(
                prefix: String(line[...equals]),
                assignment: assignment
            )
        }

        if let match = line.wholeMatch(of: declarationPattern) {
            return redactExtendedAssignment(
                prefix: String(match.output.prefix),
                name: String(match.output.name),
                rest: String(match.output.rest)
            )
        }

        if let match = line.wholeMatch(of: extendedAssignmentPattern) {
            return redactExtendedAssignment(
                prefix: String(match.output.prefix),
                name: String(match.output.name),
                rest: String(match.output.rest)
            )
        }

        guard line.contains("=") else { return line }
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        return String(indentation) + mask
    }

    /// Retains only a parser-proven harmless suffix, dropping uncertain trailing content.
    private static func redactParsedAssignment(
        prefix: String,
        assignment: ParsedAssignment
    ) -> String {
        guard assignment.isEditable, !assignment.suffix.contains("=") else {
            return prefix + mask
        }
        return prefix + mask + assignment.suffix
    }

    /// Reuses the canonical parser for the value/suffix after stripping declaration syntax.
    private static func redactExtendedAssignment(
        prefix: String,
        name: String,
        rest: String
    ) -> String {
        guard let assignment = ShellConfigParser.parseLine("\(name)=\(rest)") else {
            return prefix + mask
        }
        return redactParsedAssignment(prefix: prefix, assignment: assignment)
    }
}

private extension BackupBrowserSource {
    /// Whether the logical source must be parsed and redacted as one JSON document.
    var containsJSON: Bool {
        switch self {
        case .claudeSettings, .claudeLocalSettings, .cursorMCPJSON:
            true
        case .unsupported(let baseName):
            baseName.lowercased().hasSuffix(".json")
        case .shell, .codexMCPEnv:
            false
        }
    }
}
