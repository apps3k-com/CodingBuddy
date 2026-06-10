//
//  SelectionResolver.swift
//  CodingBuddy
//

import Foundation

/// Re-resolves a Table selection after the variable list was rebuilt.
/// `EnvVariable.id` encodes the line index, so a reload that shifts lines
/// (import, external edit) invalidates the id even though the variable still
/// exists — the selection would silently clear.
nonisolated enum SelectionResolver {

    static func resolve(
        _ selection: EnvVariable.ID?,
        from oldVariables: [EnvVariable],
        in newVariables: [EnvVariable]
    ) -> EnvVariable.ID? {
        guard let selection else { return nil }
        guard let selected = oldVariables.first(where: { $0.id == selection }) else {
            return keepIfPresent(selection, in: newVariables)
        }

        // Name + file alone are ambiguous — duplicate assignments of one name
        // in one file are valid zsh — so match the occurrence ordinal too.
        let oldMatches = occurrences(of: selected, in: oldVariables)
        let newMatches = occurrences(of: selected, in: newVariables)
        guard !newMatches.isEmpty else {
            // Name gone: an in-place rename keeps the row's id, so keep the
            // selection when a row still carries it.
            return keepIfPresent(selection, in: newVariables)
        }

        let ordinal = oldMatches.firstIndex { $0.id == selection } ?? 0
        return newMatches[min(ordinal, newMatches.count - 1)].id
    }

    /// All assignments of the same name in the same file, in line order.
    private static func occurrences(
        of variable: EnvVariable, in variables: [EnvVariable]
    ) -> [EnvVariable] {
        variables
            .filter { $0.name == variable.name && $0.file == variable.file }
            .sorted { $0.lineIndex < $1.lineIndex }
    }

    private static func keepIfPresent(
        _ selection: EnvVariable.ID, in variables: [EnvVariable]
    ) -> EnvVariable.ID? {
        variables.contains { $0.id == selection } ? selection : nil
    }
}
