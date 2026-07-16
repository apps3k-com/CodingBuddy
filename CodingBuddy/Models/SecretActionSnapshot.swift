//
//  SecretActionSnapshot.swift
//  CodingBuddy
//

import Foundation

/// Captures one presentation row before authentication and resolves it only
/// while both the surrounding presentation and the row remain unchanged.
nonisolated struct SecretActionSnapshot<Value: Identifiable & Equatable> where Value.ID: Equatable {
    /// Monotonic presentation generation captured before authentication begins.
    let generation: Int
    /// Exact row whose protected action the user requested.
    let value: Value

    /// Returns the current row only when neither its identity, contents, nor presentation changed.
    func resolve(currentGeneration: Int, in values: [Value]) -> Value? {
        guard currentGeneration == generation,
              let current = values.first(where: { $0.id == value.id }),
              current == value else { return nil }
        return current
    }
}
