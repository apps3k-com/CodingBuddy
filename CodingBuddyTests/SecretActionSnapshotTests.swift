//
//  SecretActionSnapshotTests.swift
//  CodingBuddyTests
//

import Testing
@testable import CodingBuddy

@Suite("Secret action snapshot")
struct SecretActionSnapshotTests {
    private struct Row: Identifiable, Equatable {
        let id: Int
        var value: String
    }

    @Test("Resolves only an unchanged row in the captured presentation generation")
    func resolvesOnlyUnchangedPresentation() {
        let expected = Row(id: 7, value: "original")
        let snapshot = SecretActionSnapshot(generation: 3, value: expected)

        #expect(snapshot.resolve(currentGeneration: 3, in: [expected]) == expected)
        #expect(snapshot.resolve(currentGeneration: 4, in: [expected]) == nil)
        #expect(snapshot.resolve(currentGeneration: 3, in: [Row(id: 7, value: "changed")]) == nil)
        #expect(snapshot.resolve(currentGeneration: 3, in: []) == nil)
    }
}
