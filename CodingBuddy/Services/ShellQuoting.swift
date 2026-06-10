//
//  ShellQuoting.swift
//  CodingBuddy
//

import Foundation

/// Rules for which raw value texts can sit verbatim inside a given quoting
/// style without changing the meaning of the line. Pure value logic — opted
/// out of the project's MainActor default isolation.
nonisolated enum ShellQuoting {

    /// Characters that are safe in an unquoted assignment value. Conservative
    /// on purpose: anything outside this set forces quotes (or read-only when
    /// parsing existing lines).
    /// Explicitly nonisolated (despite the enum-level annotation): Xcode's
    /// live-issue pipeline misses the type-level opt-out when this is passed
    /// as an unapplied reference and reports spurious MainActor warnings.
    nonisolated static func isUnquotedSafe(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return true }
        return "_./:$~^+,@%={}-".contains(character)
    }

    /// True if `raw` can be written verbatim between the delimiters of
    /// `quoting` without breaking out of them.
    static func isValid(raw: String, for quoting: ValueQuoting) -> Bool {
        switch quoting {
        case .none:
            return raw.allSatisfy { isUnquotedSafe($0) }
        case .single:
            return !raw.contains("'")
        case .double:
            // No unescaped `"`, and no dangling trailing backslash that would
            // escape the closing quote.
            var escaped = false
            for character in raw {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    return false
                }
            }
            return !escaped
        }
    }

    /// Picks a quoting style that can represent `raw` verbatim, preferring the
    /// style the line already uses. Returns nil if no style fits (e.g. the
    /// value mixes an unescaped `"` with a `'`).
    static func bestQuoting(for raw: String, preferred: ValueQuoting) -> ValueQuoting? {
        let candidates: [ValueQuoting] = [preferred, .double, .single, .none]
        return candidates.first { isValid(raw: raw, for: $0) }
    }

    /// Command substitution executes code; the app neither edits nor creates
    /// such values.
    static func containsCommandSubstitution(_ raw: String) -> Bool {
        raw.contains("$(") || raw.contains("`")
    }
}
