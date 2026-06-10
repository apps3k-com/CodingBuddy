//
//  ShellConfigWriter.swift
//  CodingBuddy
//

import Foundation

/// Applies edits to shell config files. Every mutation re-validates the target
/// line against the file on disk, writes a timestamped backup first, and
/// replaces the file atomically while preserving symlinks and permissions.
struct ShellConfigWriter {
    var backupDirectory: URL
    var backupRetention = 20
    /// POSIX mode for files this writer creates (credential env files use 0o600).
    var createMode: Int?

    static let managedBlockBegin = "# >>> CodingBuddy >>>"
    static let managedBlockEnd = "# <<< CodingBuddy <<<"
    /// Blocks written before the rename to CodingBuddy keep being recognized;
    /// only files without any managed block get the new markers.
    static let legacyBlockBegin = "# >>> EnvVarBuddy >>>"
    static let legacyBlockEnd = "# <<< EnvVarBuddy <<<"

    enum WriteError: LocalizedError, Equatable {
        case fileChangedExternally
        case lineNotEditable
        case invalidName(String)
        case unrepresentableValue
        case commandSubstitutionNotAllowed

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

        var lines = try loadLines(at: fileURL)
        try verify(variable, against: lines)

        var assignment = variable.assignment
        assignment.name = newName
        assignment.rawValue = newRawValue
        assignment.quoting = quoting
        assignment.exportToken = exported
            ? (assignment.exportToken.isEmpty ? "export " : assignment.exportToken)
            : ""
        lines[variable.lineIndex] = assignment.rendered

        try write(lines: lines, to: fileURL)
    }

    /// Deleting removes the line outright; the pre-write backup preserves the
    /// history, so no commented-out remains accumulate in the file.
    func deleteVariable(_ variable: some EnvAssignmentLine, at fileURL: URL) throws {
        guard variable.assignment.isEditable else { throw WriteError.lineNotEditable }
        var lines = try loadLines(at: fileURL)
        try verify(variable, against: lines)
        lines.remove(at: variable.lineIndex)
        try write(lines: lines, to: fileURL)
    }

    /// How new assignments are rendered: zsh dotfiles get `export`, dotenv
    /// files plain `NAME=value` lines.
    enum ExportStyle {
        case export
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

        var lines = (try? loadLines(at: fileURL)) ?? []
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

        try write(lines: lines, to: fileURL)
    }

    // MARK: - Validation

    static func validateName(_ name: String) throws {
        guard name.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_]*/#) != nil else {
            throw WriteError.invalidName(name)
        }
    }

    static func validateValue(_ rawValue: String) throws {
        guard !ShellQuoting.containsCommandSubstitution(rawValue) else {
            throw WriteError.commandSubstitutionNotAllowed
        }
    }

    // MARK: - File access

    private func loadLines(at fileURL: URL) throws -> [String] {
        let content = try String(contentsOf: fileURL.resolvingSymlinksInPath(), encoding: .utf8)
        return content.components(separatedBy: "\n")
    }

    private func verify(_ variable: some EnvAssignmentLine, against lines: [String]) throws {
        guard variable.lineIndex < lines.count,
              lines[variable.lineIndex] == variable.sourceLine else {
            throw WriteError.fileChangedExternally
        }
    }

    /// Joins and writes the lines through the shared write-safety machinery
    /// (no-op when unchanged, backup, atomic, symlink-safe, permissions).
    private func write(lines: [String], to fileURL: URL) throws {
        try SafeFileWriter(backupDirectory: backupDirectory, backupRetention: backupRetention, createMode: createMode)
            .write(lines.joined(separator: "\n"), to: fileURL)
    }
}
