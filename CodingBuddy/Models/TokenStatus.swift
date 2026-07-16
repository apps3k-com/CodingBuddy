//
//  TokenStatus.swift
//  CodingBuddy
//

import Foundation

/// Lifecycle state of a stored credential, shared by every token-bearing
/// section (mcp-auth, Craft Agents, …).
nonisolated enum TokenStatus: Equatable, Hashable {
    /// Credential is present and either unexpired or has no known expiry.
    case active(expiry: Date?)
    /// Known access-token expiry lies in the past.
    case expired(Date)
    /// Available metadata is insufficient to establish an active credential.
    case incomplete
    /// Credential artifacts exist but are intentionally unreadable and may only be reset.
    case resetOnly

    /// Derives the status from OAuth-style fields. `obtainedAt` accepts epoch
    /// seconds or milliseconds (heuristic: values past ~Sep 33658 are ms).
    static func from(obtainedAt: Double?, expiresIn: Double?, now: Date = Date()) -> TokenStatus {
        guard let obtainedAt, let expiresIn else { return .incomplete }
        let obtainedSeconds = obtainedAt > 1_000_000_000_000 ? obtainedAt / 1000 : obtainedAt
        let expiry = Date(timeIntervalSince1970: obtainedSeconds + expiresIn)
        return expiry < now ? .expired(expiry) : .active(expiry: expiry)
    }
}
