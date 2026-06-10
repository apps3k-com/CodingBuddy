//
//  SelectionResolverTests.swift
//  CodingBuddyTests
//

import Testing
@testable import CodingBuddy

@MainActor
struct SelectionResolverTests {

    private func variable(
        _ name: String,
        value: String = "x",
        file: ShellConfigFile = .zshrc,
        line: Int
    ) -> EnvVariable {
        let assignment = ParsedAssignment(
            prefix: "", exportToken: "export ", name: name, rawValue: value,
            quoting: .double, suffix: "", isEditable: true
        )
        return EnvVariable(
            assignment: assignment, file: file, lineIndex: line,
            sourceLine: assignment.rendered
        )
    }

    @Test func selectionFollowsVariableWhenLinesAreInsertedAbove() {
        let old = [variable("FOO", line: 5)]
        let new = [variable("IMPORTED", line: 5), variable("FOO", line: 8)]
        let resolved = SelectionResolver.resolve(old[0].id, from: old, in: new)
        #expect(resolved == new[1].id)
    }

    @Test func duplicateNamesResolveToTheSameOccurrence() {
        // Duplicate assignments of one name in one file are valid zsh — the
        // selection must stay on the same occurrence, not jump to the first.
        let old = [variable("FOO", value: "a", line: 2), variable("FOO", value: "b", line: 7)]
        let new = [variable("FOO", value: "a", line: 4), variable("FOO", value: "b", line: 9)]
        let resolved = SelectionResolver.resolve(old[1].id, from: old, in: new)
        #expect(resolved == new[1].id)
    }

    @Test func occurrencesAreCountedPerFile() {
        let old = [
            variable("FOO", file: .zshenv, line: 1),
            variable("FOO", file: .zshrc, line: 3),
        ]
        let new = [
            variable("FOO", file: .zshenv, line: 1),
            variable("FOO", file: .zshrc, line: 6),
        ]
        let resolved = SelectionResolver.resolve(old[1].id, from: old, in: new)
        #expect(resolved == new[1].id)
    }

    @Test func selectionClampsToLastOccurrenceWhenSelectedOneIsRemoved() {
        let old = [variable("FOO", value: "a", line: 2), variable("FOO", value: "b", line: 7)]
        let new = [variable("FOO", value: "a", line: 2)]
        let resolved = SelectionResolver.resolve(old[1].id, from: old, in: new)
        #expect(resolved == new[0].id)
    }

    @Test func renameInPlaceKeepsTheSelectedRow() {
        // An in-place edit keeps the line index; the id therefore still points
        // at the same row even though the name changed.
        let old = [variable("FOO", line: 5)]
        let new = [variable("BAR", line: 5)]
        let resolved = SelectionResolver.resolve(old[0].id, from: old, in: new)
        #expect(resolved == new[0].id)
    }

    @Test func selectionClearsWhenVariableAndRowAreGone() {
        let old = [variable("FOO", line: 5)]
        let resolved = SelectionResolver.resolve(old[0].id, from: old, in: [])
        #expect(resolved == nil)
    }

    @Test func nilSelectionStaysNil() {
        let new = [variable("FOO", line: 5)]
        #expect(SelectionResolver.resolve(nil, from: [], in: new) == nil)
    }

    @Test func unchangedListKeepsSelection() {
        let variables = [variable("FOO", line: 5), variable("BAR", line: 6)]
        let resolved = SelectionResolver.resolve(variables[0].id, from: variables, in: variables)
        #expect(resolved == variables[0].id)
    }

    @Test func unknownSelectionResolvesAgainstTheNewListOnly() {
        // A stale id that never existed in the old snapshot: keep it when a
        // row still carries it, clear it otherwise.
        let new = [variable("FOO", line: 5)]
        #expect(SelectionResolver.resolve("\(ShellConfigFile.zshrc.rawValue):5", from: [], in: new) == new[0].id)
        #expect(SelectionResolver.resolve("\(ShellConfigFile.zshrc.rawValue):9", from: [], in: new) == nil)
    }
}
