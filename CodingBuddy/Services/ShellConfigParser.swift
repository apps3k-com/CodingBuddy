//
//  ShellConfigParser.swift
//  CodingBuddy
//

import Foundation

/// Parses zsh config files line by line. Only simple single assignments are
/// considered editable; anything that could change meaning when rewritten
/// (command substitution, multi-assignments, unclosed quotes, trailing code)
/// is surfaced read-only and preserved verbatim by the writer.
nonisolated enum ShellConfigParser {

    /// Parses a plain env file (dotenv style, e.g. `~/.codex/mcp.env`) into
    /// line-addressed assignments — dotenv lines are a subset of shell
    /// assignments, so the grammar is shared.
    static func assignments(in content: String) -> [EnvFileVariable] {
        content.components(separatedBy: "\n").enumerated().compactMap { index, line in
            parseLine(line).map {
                EnvFileVariable(assignment: $0, lineIndex: index, sourceLine: line)
            }
        }
    }

    static func variables(in content: String, file: ShellConfigFile) -> [EnvVariable] {
        content.components(separatedBy: "\n").enumerated().compactMap { index, line in
            parseLine(line).map {
                EnvVariable(assignment: $0, file: file, lineIndex: index, sourceLine: line)
            }
        }
    }

    /// Returns the decomposed assignment, or nil if the line is not a
    /// variable assignment at all (comments, aliases, functions, ...).
    static func parseLine(_ line: String) -> ParsedAssignment? {
        let head = #/(?<prefix>[ \t]*)(?<export>export[ \t]+)?(?<name>[A-Za-z_][A-Za-z0-9_]*)=(?<rest>.*)/#
        guard let match = line.wholeMatch(of: head) else { return nil }

        let rest = match.output.rest
        var assignment = ParsedAssignment(
            prefix: String(match.output.prefix),
            exportToken: String(match.output.export ?? ""),
            name: String(match.output.name),
            rawValue: "",
            quoting: .none,
            suffix: "",
            isEditable: true
        )

        switch rest.first {
        case "\"":
            guard let (raw, suffix) = scanQuoted(rest, delimiter: "\"", allowsEscapes: true) else {
                return readOnly(assignment, rawValue: String(rest))
            }
            assignment.quoting = .double
            assignment.rawValue = raw
            assignment.suffix = suffix
        case "'":
            guard let (raw, suffix) = scanQuoted(rest, delimiter: "'", allowsEscapes: false) else {
                return readOnly(assignment, rawValue: String(rest))
            }
            assignment.quoting = .single
            assignment.rawValue = raw
            assignment.suffix = suffix
        default:
            // Unquoted: the value ends at the first whitespace.
            if let cut = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                assignment.rawValue = String(rest[..<cut])
                assignment.suffix = String(rest[cut...])
            } else {
                assignment.rawValue = String(rest)
            }
            if !assignment.rawValue.allSatisfy({ ShellQuoting.isUnquotedSafe($0) }) {
                return readOnly(assignment, rawValue: assignment.rawValue)
            }
        }

        assignment.isEditable = isSuffixHarmless(assignment.suffix)
            && !ShellQuoting.containsCommandSubstitution(assignment.rawValue)
        return assignment
    }

    /// A suffix is harmless when nothing after the value is executed: it must
    /// be empty, whitespace, or whitespace followed by a `#` comment. Anything
    /// else (a second assignment, a command) makes the line read-only.
    private static func isSuffixHarmless(_ suffix: String) -> Bool {
        if suffix.isEmpty { return true }
        guard suffix.first == " " || suffix.first == "\t" else { return false }
        let trimmed = suffix.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    /// Scans a quoted value starting at the opening delimiter. Returns the
    /// content between the delimiters verbatim (escapes preserved) and the
    /// remainder after the closing delimiter, or nil if the quote never closes.
    private static func scanQuoted(
        _ rest: Substring, delimiter: Character, allowsEscapes: Bool
    ) -> (raw: String, suffix: String)? {
        var raw = ""
        var escaped = false
        var index = rest.index(after: rest.startIndex)
        while index < rest.endIndex {
            let character = rest[index]
            if escaped {
                raw.append(character)
                escaped = false
            } else if allowsEscapes && character == "\\" {
                raw.append(character)
                escaped = true
            } else if character == delimiter {
                return (raw, String(rest[rest.index(after: index)...]))
            } else {
                raw.append(character)
            }
            index = rest.index(after: index)
        }
        return nil
    }

    private static func readOnly(_ assignment: ParsedAssignment, rawValue: String) -> ParsedAssignment {
        var readOnly = assignment
        readOnly.rawValue = rawValue
        readOnly.quoting = .none
        readOnly.suffix = ""
        readOnly.isEditable = false
        return readOnly
    }
}
