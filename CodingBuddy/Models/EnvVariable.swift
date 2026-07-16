//
//  EnvVariable.swift
//  CodingBuddy
//

import Foundation

/// Quoting style of a value as written in the shell file.
nonisolated enum ValueQuoting: Equatable, Hashable {
    /// Value is not enclosed by quote characters.
    case none
    /// Value is enclosed by double quotes.
    case double
    /// Value is enclosed by single quotes.
    case single

    /// Exact quote character used on both sides of the value.
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
    /// Environment variable name as parsed from the assignment.
    var name: String
    /// Value text exactly as written between any quote delimiters.
    var rawValue: String
    /// Quote style retained for byte-for-byte rendering.
    var quoting: ValueQuoting
    /// Everything after the value (whitespace, trailing comment), kept verbatim.
    var suffix: String
    /// False for lines the app must not rewrite from parts: command
    /// substitution, multi-assignments, unclosed quotes, trailing code.
    var isEditable: Bool

    /// Whether the source assignment included the `export` keyword.
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
    /// Parsed assignment whose rendering preserves the source line.
    var assignment: ParsedAssignment
    /// Startup file containing the assignment.
    var file: ShellConfigFile
    /// 0-based line index in the file at parse time. The writer re-validates
    /// this against the file before modifying anything.
    var lineIndex: Int
    /// The original line verbatim, used for display and copy actions.
    var sourceLine: String

    /// Identity scoped by startup file and source line.
    var id: String { "\(file.rawValue):\(lineIndex)" }
    /// Environment variable name without export or quoting syntax.
    var name: String { assignment.name }
    /// Value text exactly as it appeared between any delimiters.
    var rawValue: String { assignment.rawValue }
    /// Whether the assignment can be reconstructed safely from parsed parts.
    var isEditable: Bool { assignment.isEditable }
}
