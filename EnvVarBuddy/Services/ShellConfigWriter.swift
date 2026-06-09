//
//  ShellConfigWriter.swift
//  EnvVarBuddy
//

import Foundation

/// Applies edits to shell config files. Every mutation re-validates the target
/// line against the file on disk, writes a timestamped backup first, and
/// replaces the file atomically while preserving symlinks and permissions.
struct ShellConfigWriter {
    var backupDirectory: URL
    var backupRetention = 20

    static let managedBlockBegin = "# >>> EnvVarBuddy >>>"
    static let managedBlockEnd = "# <<< EnvVarBuddy <<<"

    enum WriteError: LocalizedError, Equatable {
        case fileChangedExternally
        case lineNotEditable
        case invalidName(String)
        case unrepresentableValue
        case commandSubstitutionNotAllowed

        var errorDescription: String? {
            switch self {
            case .fileChangedExternally:
                "Die Datei wurde extern geändert. Bitte erneut versuchen."
            case .lineNotEditable:
                "Diese Zeile ist zu komplex und wird von EnvVarBuddy nicht verändert."
            case .invalidName(let name):
                "„\(name)“ ist kein gültiger Variablenname."
            case .unrepresentableValue:
                "Der Wert enthält eine Quote-Kombination, die nicht sicher geschrieben werden kann."
            case .commandSubstitutionNotAllowed:
                "Werte mit Command Substitution ($(…) oder `…`) werden nicht unterstützt."
            }
        }
    }

    // MARK: - Mutations

    func updateVariable(
        _ variable: EnvVariable,
        newName: String,
        newRawValue: String,
        exported: Bool,
        at fileURL: URL
    ) throws {
        guard variable.isEditable else { throw WriteError.lineNotEditable }
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

    func deleteVariable(_ variable: EnvVariable, at fileURL: URL) throws {
        guard variable.isEditable else { throw WriteError.lineNotEditable }
        var lines = try loadLines(at: fileURL)
        try verify(variable, against: lines)

        if let replacement = deletionReplacement(forRemovedLine: lines[variable.lineIndex]) {
            lines[variable.lineIndex] = replacement
        } else {
            lines.remove(at: variable.lineIndex)
        }

        try write(lines: lines, to: fileURL)
    }

    /// LEARNING SPOT — Löschstrategie (siehe Plan).
    /// Rückgabe nil: Zeile wird ersatzlos entfernt (sauber; das Backup hält die
    /// Historie). Rückgabe eines Strings: die Zeile wird stattdessen ersetzt,
    /// z.B. auskommentiert ("# removed by EnvVarBuddy: …"), so bleibt die
    /// Historie direkt in der Datei sichtbar — kostet aber Lesbarkeit.
    func deletionReplacement(forRemovedLine line: String) -> String? {
        // TODO(user): Strategie wählen — nil (hart löschen) oder Kommentar-String.
        nil
    }

    /// Appends new variables to the managed EnvVarBuddy block, creating the
    /// block — and the file itself — when missing.
    func addVariables(_ entries: [(name: String, rawValue: String)], to fileURL: URL) throws {
        let rendered: [String] = try entries.map { entry in
            try Self.validateName(entry.name)
            try Self.validateValue(entry.rawValue)
            guard let quoting = ShellQuoting.bestQuoting(for: entry.rawValue, preferred: .double) else {
                throw WriteError.unrepresentableValue
            }
            return ParsedAssignment(
                prefix: "", exportToken: "export ", name: entry.name,
                rawValue: entry.rawValue, quoting: quoting, suffix: "", isEditable: true
            ).rendered
        }
        guard !rendered.isEmpty else { return }

        var lines = (try? loadLines(at: fileURL)) ?? []
        if let endIndex = lines.lastIndex(of: Self.managedBlockEnd),
           lines[..<endIndex].contains(Self.managedBlockBegin) {
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

    private func verify(_ variable: EnvVariable, against lines: [String]) throws {
        guard variable.lineIndex < lines.count,
              lines[variable.lineIndex] == variable.sourceLine else {
            throw WriteError.fileChangedExternally
        }
    }

    /// Joins and writes the lines. No-ops when nothing changed; otherwise
    /// backs up the current file, then writes atomically to the symlink
    /// target, restoring its POSIX permissions afterwards.
    private func write(lines: [String], to fileURL: URL) throws {
        let fileManager = FileManager.default
        let resolved = fileURL.resolvingSymlinksInPath()
        let newContent = lines.joined(separator: "\n")

        let exists = fileManager.fileExists(atPath: resolved.path)
        if exists, try String(contentsOf: resolved, encoding: .utf8) == newContent {
            return
        }

        var permissions: Any?
        if exists {
            permissions = (try? fileManager.attributesOfItem(atPath: resolved.path))?[.posixPermissions]
            try backUp(resolved)
        }

        try newContent.write(to: resolved, atomically: true, encoding: .utf8)

        if let permissions {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: resolved.path)
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
