//
//  EnvVariable.swift
//  EnvVarBuddy
//

import Foundation

/// Quoting style of a value as written in the shell file.
nonisolated enum ValueQuoting: Equatable, Hashable {
    case none
    case double
    case single

    var delimiter: String {
        switch self {
        case .none: ""
        case .double: "\""
        case .single: "'"
        }
    }
}

/// A single `NAME=value` assignment, decomposed so the original line can be
/// reproduced byte-for-byte. `rawValue` is the text between the quotes exactly
/// as written — no unescaping, no `$VAR` expansion.
nonisolated struct ParsedAssignment: Equatable, Hashable {
    /// Leading whitespace before the assignment.
    var prefix: String
    /// The `export` keyword including its trailing whitespace, or "" if absent.
    var exportToken: String
    var name: String
    var rawValue: String
    var quoting: ValueQuoting
    /// Everything after the value (whitespace, trailing comment), kept verbatim.
    var suffix: String
    /// False for lines the app must not rewrite from parts: command
    /// substitution, multi-assignments, unclosed quotes, trailing code.
    var isEditable: Bool

    var hasExport: Bool { !exportToken.isEmpty }

    /// Reassembles the source line. For editable lines this matches the
    /// original input byte-for-byte.
    var rendered: String {
        let quote = quoting.delimiter
        return prefix + exportToken + name + "=" + quote + rawValue + quote + suffix
    }
}

/// One variable assignment found in a shell config file.
nonisolated struct EnvVariable: Identifiable, Equatable, Hashable {
    var assignment: ParsedAssignment
    var file: ShellConfigFile
    /// 0-based line index in the file at parse time. The writer re-validates
    /// this against the file before modifying anything.
    var lineIndex: Int
    /// The original line verbatim, used for display and copy actions.
    var sourceLine: String

    var id: String { "\(file.rawValue):\(lineIndex)" }
    var name: String { assignment.name }
    var rawValue: String { assignment.rawValue }
    var isEditable: Bool { assignment.isEditable }
}
