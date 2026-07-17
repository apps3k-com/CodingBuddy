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
    /// A previous restore has unresolved recovery state that must be reviewed first.
    case recoveryRequiresReview

    /// Localized explanation suitable for alerts.
    var errorDescription: String? {
        switch self {
        case .unsupportedBackup:
            String(localized: "Restore is only available for backups that CodingBuddy can map to a managed file.")
        case .backupChanged:
            String(localized: "The file was changed externally. Please try again.")
        case .targetNotWritable:
            String(localized: "CodingBuddy cannot safely write to the selected target file.")
        case .recoveryRequiresReview:
            String(localized: "Review the previous restore recovery state before restoring another backup.")
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
    /// Unresolved transactional outcome retained across navigation until explicit review.
    private(set) var restoreRecoveryAttention: BackupRestoreFailurePresentation?

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

    /// Clears the navigation-stable safety block only after the user explicitly reviews it.
    func markRestoreRecoveryReviewed() {
        restoreRecoveryAttention = nil
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
                backup: .message(String(localized: "Could not read file.")),
                current: .message(String(localized: "Could not read file."))
            )
        }

        guard let secureMetadata = selectedItem.secureMetadata else {
            let explanation = selectedItem.rejectionReason?.explanation
                ?? String(localized: "Could not read file.")
            return BackupBrowserPreview(backup: .message(explanation), current: .message(explanation))
        }

        let backup: BackupBrowserPreviewContent
        if let snapshot = try? SecureInputReader.capture(
                at: selectedItem.backupURL,
                matching: secureMetadata,
                maximumByteCount: Self.maximumBackupFileSize,
                policy: .backup
           ), let text = String(data: snapshot.data, encoding: .utf8) {
            backup = redactedPreviewContent(text, source: selectedItem.source)
        } else {
            backup = .message(String(localized: "Could not read file."))
        }

        let current: BackupBrowserPreviewContent
        if let targetURL = selectedItem.targetURL {
            if FileManager.default.fileExists(atPath: targetURL.resolvingSymlinksInPath().path) {
                current = currentPreviewContent(from: targetURL, source: selectedItem.source)
            } else {
                current = .message(String(localized: "The target file does not exist yet."))
            }
        } else {
            current = .message(String(localized: "No supported restore target."))
        }
        return BackupBrowserPreview(backup: backup, current: current)
    }

    /// Restores a selected backup through `SafeFileWriter`, backing up the current target first.
    func restore(_ item: BackupBrowserItem) throws {
        guard restoreRecoveryAttention == nil else {
            throw BackupBrowserError.recoveryRequiresReview
        }
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
        guard let backupContent = String(data: backupSnapshot.data, encoding: .utf8) else {
            throw BackupBrowserError.backupChanged
        }
        let writer = SafeFileWriter(
            backupDirectory: backupDirectory,
            createMode: selectedItem.source.createMode,
            transactionHook: restoreTransactionHook
        )
        let targetSnapshot: SafeFileWriter.Snapshot
        do {
            targetSnapshot = try writer.snapshot(
                at: targetURL,
                maximumByteCount: Self.maximumBackupFileSize,
                createMissingParentDirectories: true
            )
        } catch SafeFileWriter.WriteError.unsafeTarget {
            throw BackupBrowserError.targetNotWritable
        } catch SafeFileWriter.WriteError.danglingSymlink {
            throw BackupBrowserError.targetNotWritable
        }
        do {
            try writer.write(backupContent, using: targetSnapshot)
        } catch {
            let presentation = BackupRestoreFailurePresentation(error: error)
            if presentation.requiresPersistentAttention {
                restoreRecoveryAttention = presentation
            }
            throw error
        }

        lastError = nil
        reload()
    }

    /// Reads a current target with the same bounded regular-file policy used for backups.
    private func currentPreviewContent(
        from url: URL,
        source: BackupBrowserSource
    ) -> BackupBrowserPreviewContent {
        guard let snapshot = try? SecureInputReader.capture(
            at: url.resolvingSymlinksInPath(),
            maximumByteCount: Self.maximumBackupFileSize,
            policy: .backup
        ), let text = String(data: snapshot.data, encoding: .utf8) else {
            return .message(String(localized: "Could not read file."))
        }
        return redactedPreviewContent(text, source: source)
    }

    /// Redacts structured JSON as a whole document and shell assignments fail closed.
    private func redactedPreviewContent(
        _ text: String,
        source: BackupBrowserSource
    ) -> BackupBrowserPreviewContent {
        if source.containsJSON {
            return .redacted(
                MCPAuthRedactor.maskedPreview(
                    text: text,
                    isJSON: true,
                    policy: .backupPreview
                )
            )
        }
        return BackupShellPreviewRedactor.redactDocument(text)
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

    /// Redacts a complete shell document, refusing all structure when an assignment
    /// has syntax that can consume subsequent lines.
    static func redactDocument(_ text: String) -> BackupBrowserPreviewContent {
        let lines = text.components(separatedBy: "\n")
        guard !lines.contains(where: assignmentContinuesBeyondLine(_:)) else {
            return .suppressedForSafety
        }
        return .redacted(lines.map(redact(_:)).joined(separator: "\n"))
    }

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

    /// Detects quotes, substitutions, arrays, heredocs, and explicit operators
    /// whose value or command body may continue on a later physical line.
    private static func assignmentContinuesBeyondLine(_ line: String) -> Bool {
        let value: Substring
        if ShellConfigParser.parseLine(line) != nil,
           let equals = line.firstIndex(of: "=") {
            value = line[line.index(after: equals)...]
        } else if let match = line.wholeMatch(of: declarationPattern) {
            value = match.output.rest
        } else if let match = line.wholeMatch(of: extendedAssignmentPattern) {
            value = match.output.rest
        } else if let equals = line.firstIndex(of: "=") {
            value = line[line.index(after: equals)...]
        } else {
            return false
        }

        return containsOpenShellSyntax(value)
    }

    /// Lexes only enough shell syntax to determine whether later lines can belong
    /// to the current assignment. Uncertainty deliberately produces `true`.
    private static func containsOpenShellSyntax(_ value: Substring) -> Bool {
        enum Context {
            case singleQuote
            case doubleQuote
            case backtick
            case parentheses
            case braces
        }

        var contexts: [Context] = []
        var escaped = false
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            let nextIndex = value.index(after: index)
            let next = nextIndex < value.endIndex ? value[nextIndex] : nil
            let previous = index > value.startIndex ? value[value.index(before: index)] : nil
            let startsPossibleComment = character == "#" && previous.map {
                $0.isWhitespace || ";|&({".contains($0)
            } ?? true

            if character == "$", next == "'" || next == "[" {
                if case .singleQuote? = contexts.last {
                    // Expansion markers are literal inside ordinary single quotes.
                } else {
                    // ANSI-C quotes and legacy zsh arithmetic have distinct escape
                    // rules. Refuse the document instead of approximating either.
                    return true
                }
            }

            switch contexts.last {
            case .singleQuote:
                if character == "'" { contexts.removeLast() }
            case .doubleQuote:
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    contexts.removeLast()
                } else if character == "`" {
                    contexts.append(.backtick)
                } else if character == "$", next == "(" {
                    contexts.append(.parentheses)
                    index = value.index(after: nextIndex)
                    continue
                } else if character == "$", next == "{" {
                    contexts.append(.braces)
                    index = value.index(after: nextIndex)
                    continue
                }
            case .backtick:
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "`" {
                    contexts.removeLast()
                } else if startsPossibleComment {
                    return true
                } else if character == "$", next == "(" {
                    contexts.append(.parentheses)
                    index = value.index(after: nextIndex)
                    continue
                }
            case .parentheses:
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "'" {
                    contexts.append(.singleQuote)
                } else if character == "\"" {
                    contexts.append(.doubleQuote)
                } else if character == "`" {
                    contexts.append(.backtick)
                } else if startsPossibleComment {
                    return true
                } else if character == "(" {
                    contexts.append(.parentheses)
                } else if character == ")" {
                    contexts.removeLast()
                } else if character == "$", next == "{" {
                    contexts.append(.braces)
                    index = value.index(after: nextIndex)
                    continue
                } else if character == "<", next == "<" {
                    return true
                }
            case .braces:
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "'" {
                    contexts.append(.singleQuote)
                } else if character == "\"" {
                    contexts.append(.doubleQuote)
                } else if character == "`" {
                    contexts.append(.backtick)
                } else if character == "}" {
                    contexts.removeLast()
                } else if character == "$", next == "(" {
                    contexts.append(.parentheses)
                    index = value.index(after: nextIndex)
                    continue
                } else if character == "$", next == "{" {
                    contexts.append(.braces)
                    index = value.index(after: nextIndex)
                    continue
                }
            case nil:
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "'" {
                    contexts.append(.singleQuote)
                } else if character == "\"" {
                    contexts.append(.doubleQuote)
                } else if character == "`" {
                    contexts.append(.backtick)
                } else if character == "(" {
                    contexts.append(.parentheses)
                } else if character == "$", next == "{" {
                    contexts.append(.braces)
                    index = value.index(after: nextIndex)
                    continue
                } else if character == "<", next == "<" {
                    return true
                }
            }
            index = nextIndex
        }

        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let endsWithContinuationOperator = trimmed.hasSuffix("|")
            || trimmed.hasSuffix("||")
            || trimmed.hasSuffix("&&")
        return !contexts.isEmpty
            || escaped
            || endsWithContinuationOperator
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
