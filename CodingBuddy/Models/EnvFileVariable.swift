//
//  EnvFileVariable.swift
//  CodingBuddy
//

import Foundation

/// A line-addressed assignment shared by the writer and every store that
/// edits env-style files: zsh dotfiles (`EnvVariable`) and plain dotenv
/// files (`EnvFileVariable`).
nonisolated protocol EnvAssignmentLine {
    var assignment: ParsedAssignment { get }
    var lineIndex: Int { get }
    var sourceLine: String { get }
}

extension EnvVariable: EnvAssignmentLine {}

/// One assignment in a plain env file (e.g. `~/.codex/mcp.env`) — same
/// byte-for-byte roundtrip guarantees as the zsh models, but without the
/// load-order semantics of `ShellConfigFile`.
nonisolated struct EnvFileVariable: Identifiable, Equatable, Hashable, EnvAssignmentLine {
    var assignment: ParsedAssignment
    /// 0-based line index in the file at parse time; the writer re-validates
    /// against the on-disk state before mutating.
    var lineIndex: Int
    var sourceLine: String

    var id: Int { lineIndex }
    var name: String { assignment.name }
    var rawValue: String { assignment.rawValue }
    var isEditable: Bool { assignment.isEditable }
}
