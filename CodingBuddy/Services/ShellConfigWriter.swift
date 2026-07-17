//
//  ShellConfigWriter.swift
//  CodingBuddy
//

import Foundation

/// Applies edits to shell config files. Every mutation re-validates the target
/// line against the file on disk, writes a timestamped backup first, and
/// replaces the file atomically while preserving symlinks and permissions.
struct ShellConfigWriter {
    /// Directory that receives timestamped copies before existing files change.
    var backupDirectory: URL
    /// Maximum number of backups retained per target basename.
    var backupRetention = 20
    /// POSIX mode for newly created secret-capable dotfiles; existing modes win.
    var createMode: Int? = 0o600
    /// Internal transaction seam used only for deterministic filesystem race tests.
    var transactionHook: ((SafeFileWriter.TransactionPoint) throws -> Void)? = nil

    /// Opening marker for assignments managed by current CodingBuddy versions.
    static let managedBlockBegin = "# >>> CodingBuddy >>>"
    /// Closing marker for assignments managed by current CodingBuddy versions.
    static let managedBlockEnd = "# <<< CodingBuddy <<<"
    /// Blocks written before the rename to CodingBuddy keep being recognized;
    /// only files without any managed block get the new markers.
    static let legacyBlockBegin = "# >>> EnvVarBuddy >>>"
    /// Closing marker paired with the legacy managed-block opening marker.
    static let legacyBlockEnd = "# <<< EnvVarBuddy <<<"

    /// Fail-closed validation and stale-source errors for shell mutations.
    enum WriteError: LocalizedError, Equatable {
        /// The on-disk line no longer matches the line originally parsed.
        case fileChangedExternally
        /// Ambiguous shell syntax prevents a safe structural rewrite.
        case lineNotEditable
        /// A variable name does not satisfy portable shell identifier rules.
        case invalidName(String)
        /// No supported quoting form can preserve the requested value.
        case unrepresentableValue
        /// Executable shell syntax is forbidden inside managed values.
        case commandSubstitutionNotAllowed

        /// Localized explanation suitable for editor validation feedback.
        var errorDescription: String? {
            switch self {
            case .fileChangedExternally:
                String(localized: "The file was changed externally. Please try again.")
            case .lineNotEditable:
                String(localized: "This line is too complex and is left untouched by CodingBuddy.")
            case .invalidName(let name):
                String(localized: "“\(name)” is not a valid variable name.")
            case .unrepresentableValue:
                String(localized: "The value contains a quote combination that cannot be written safely.")
            case .commandSubstitutionNotAllowed:
                String(localized: "Values with command substitution ($(…) or `…`) are not supported.")
            }
        }
    }

    // MARK: - Mutations

    /// Replaces one parsed assignment only if its original source line still matches disk.
    func updateVariable(
        _ variable: some EnvAssignmentLine,
        newName: String,
        newRawValue: String,
        exported: Bool,
        at fileURL: URL
    ) throws {
        guard variable.assignment.isEditable else { throw WriteError.lineNotEditable }
        try Self.validateName(newName)
        try Self.validateValue(newRawValue)
        guard let quoting = ShellQuoting.bestQuoting(for: newRawValue, preferred: variable.assignment.quoting) else {
            throw WriteError.unrepresentableValue
        }

        let loaded = try load(at: fileURL)
        var lines = loaded.lines
        try verify(variable, against: lines)

        var assignment = variable.assignment
        assignment.name = newName
        assignment.rawValue = newRawValue
        assignment.quoting = quoting
        assignment.exportToken = exported
            ? (assignment.exportToken.isEmpty ? "export " : assignment.exportToken)
            : ""
        lines[variable.lineIndex] = assignment.rendered

        try write(lines: lines, using: loaded.snapshot)
    }

    /// Deleting removes the line outright; the pre-write backup preserves the
    /// history, so no commented-out remains accumulate in the file.
    func deleteVariable(_ variable: some EnvAssignmentLine, at fileURL: URL) throws {
        guard variable.assignment.isEditable else { throw WriteError.lineNotEditable }
        let loaded = try load(at: fileURL)
        var lines = loaded.lines
        try verify(variable, against: lines)
        lines.remove(at: variable.lineIndex)
        try write(lines: lines, using: loaded.snapshot)
    }

    /// How new assignments are rendered: zsh dotfiles get `export`, dotenv
    /// files plain `NAME=value` lines.
    enum ExportStyle {
        /// Prefix each managed assignment with `export` for shell startup files.
        case export
        /// Write plain `NAME=value` assignments for dotenv files.
        case none
    }

    /// Appends new variables to the managed CodingBuddy block, creating the
    /// block — and the file itself — when missing.
    func addVariables(
        _ entries: [(name: String, rawValue: String)],
        to fileURL: URL,
        exportStyle: ExportStyle = .export
    ) throws {
        let rendered: [String] = try entries.map { entry in
            try Self.validateName(entry.name)
            try Self.validateValue(entry.rawValue)
            guard let quoting = ShellQuoting.bestQuoting(for: entry.rawValue, preferred: .double) else {
                throw WriteError.unrepresentableValue
            }
            return ParsedAssignment(
                prefix: "", exportToken: exportStyle == .export ? "export " : "", name: entry.name,
                rawValue: entry.rawValue, quoting: quoting, suffix: "", isEditable: true
            ).rendered
        }
        guard !rendered.isEmpty else { return }

        let snapshot = try capture(at: fileURL)
        var lines = try decodedContent(from: snapshot).map {
            $0.components(separatedBy: "\n")
        } ?? []
        let markers = [
            (Self.managedBlockBegin, Self.managedBlockEnd),
            (Self.legacyBlockBegin, Self.legacyBlockEnd),
        ]
        if let endIndex = markers.lazy.compactMap({ begin, end -> Int? in
            guard let endIndex = lines.lastIndex(of: end),
                  lines[..<endIndex].contains(begin) else { return nil }
            return endIndex
        }).first {
            lines.insert(contentsOf: rendered, at: endIndex)
        } else {
            // `lines` ending in "" means the file ends with a newline.
            if lines.last == "" { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines += [Self.managedBlockBegin] + rendered + [Self.managedBlockEnd, ""]
        }

        try write(lines: lines, using: snapshot)
    }

    // MARK: - Validation

    /// Rejects names that cannot be represented as shell assignment identifiers.
    static func validateName(_ name: String) throws {
        guard name.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_]*/#) != nil else {
            throw WriteError.invalidName(name)
        }
    }

    /// Rejects values whose evaluation could execute shell commands.
    static func validateValue(_ rawValue: String) throws {
        guard !ShellQuoting.containsCommandSubstitution(rawValue) else {
            throw WriteError.commandSubstitutionNotAllowed
        }
    }

    // MARK: - File access

    private func load(at fileURL: URL) throws -> (snapshot: SafeFileWriter.Snapshot, lines: [String]) {
        let snapshot = try capture(at: fileURL)
        guard let content = try decodedContent(from: snapshot) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return (snapshot, content.components(separatedBy: "\n"))
    }

    private func capture(at fileURL: URL) throws -> SafeFileWriter.Snapshot {
        do {
            return try makeSafeWriter().snapshot(at: fileURL)
        } catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
    }

    private func decodedContent(from snapshot: SafeFileWriter.Snapshot) throws -> String? {
        try snapshot.utf8Content()
    }

    private func verify(_ variable: some EnvAssignmentLine, against lines: [String]) throws {
        guard variable.lineIndex < lines.count,
              lines[variable.lineIndex] == variable.sourceLine else {
            throw WriteError.fileChangedExternally
        }
    }

    /// Joins and writes the lines through the shared write-safety machinery
    /// (no-op when unchanged, backup, atomic, symlink-safe, permissions).
    private func write(lines: [String], using snapshot: SafeFileWriter.Snapshot) throws {
        try makeSafeWriter().write(lines.joined(separator: "\n"), using: snapshot)
    }

    private func makeSafeWriter() -> SafeFileWriter {
        SafeFileWriter(
            backupDirectory: backupDirectory,
            backupRetention: backupRetention,
            createMode: createMode,
            transactionHook: transactionHook
        )
    }
}
