//
//  EnvFileVariable.swift
//  CodingBuddy
//

import Foundation

/// A line-addressed assignment shared by the writer and every store that
/// edits env-style files: zsh dotfiles (`EnvVariable`) and plain dotenv
/// files (`EnvFileVariable`).
nonisolated protocol EnvAssignmentLine {
    /// Parsed components retained for lossless rendering and safe edits.
    var assignment: ParsedAssignment { get }
    /// Zero-based source position captured during parsing.
    var lineIndex: Int { get }
    /// Original line used to detect external changes before a write.
    var sourceLine: String { get }
}

extension EnvVariable: EnvAssignmentLine {}

/// One assignment in a plain env file (e.g. `~/.codex/mcp.env`) — same
/// byte-for-byte roundtrip guarantees as the zsh models, but without the
/// load-order semantics of `ShellConfigFile`.
nonisolated struct EnvFileVariable: Identifiable, Equatable, Hashable, EnvAssignmentLine {
    /// Parsed assignment whose rendering preserves the source line.
    var assignment: ParsedAssignment
    /// 0-based line index in the file at parse time; the writer re-validates
    /// against the on-disk state before mutating.
    var lineIndex: Int
    /// Original line used for display and pre-write revalidation.
    var sourceLine: String

    /// Line-addressed identity within the env file snapshot.
    var id: Int { lineIndex }
    /// Environment variable name without export or quoting syntax.
    var name: String { assignment.name }
    /// Value text exactly as it appeared between any delimiters.
    var rawValue: String { assignment.rawValue }
    /// Whether the assignment can be reconstructed safely from parsed parts.
    var isEditable: Bool { assignment.isEditable }
}
