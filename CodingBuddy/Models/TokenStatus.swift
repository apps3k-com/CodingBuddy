//
//  TokenStatus.swift
//  CodingBuddy
//

import Foundation

/// Lifecycle state of a stored credential, shared by every token-bearing
/// section (mcp-auth, Craft Agents, …).
nonisolated enum TokenStatus: Equatable, Hashable {
    case active(expiry: Date?)
    case expired(Date)
    case incomplete

    /// Derives the status from OAuth-style fields. `obtainedAt` accepts epoch
    /// seconds or milliseconds (heuristic: values past ~Sep 33658 are ms).
    static func from(obtainedAt: Double?, expiresIn: Double?, now: Date = Date()) -> TokenStatus {
        guard let obtainedAt, let expiresIn else { return .incomplete }
        let obtainedSeconds = obtainedAt > 1_000_000_000_000 ? obtainedAt / 1000 : obtainedAt
        let expiry = Date(timeIntervalSince1970: obtainedSeconds + expiresIn)
        return expiry < now ? .expired(expiry) : .active(expiry: expiry)
    }
}
