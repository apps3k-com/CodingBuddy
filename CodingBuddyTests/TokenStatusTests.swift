//
//  TokenStatusTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct TokenStatusTests {

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func activeTokenFromSecondsTimestamps() {
        let status = TokenStatus.from(
            obtainedAt: 1_999_999_000, expiresIn: 4_000, now: now
        )
        #expect(status == .active(expiry: Date(timeIntervalSince1970: 2_000_003_000)))
    }

    @Test func expiredTokenFromSecondsTimestamps() {
        let status = TokenStatus.from(
            obtainedAt: 1_999_990_000, expiresIn: 100, now: now
        )
        #expect(status == .expired(Date(timeIntervalSince1970: 1_999_990_100)))
    }

    @Test func millisecondTimestampsAreDetected() {
        // obtained_at in ms (e.g. Craft Agents writes epoch milliseconds).
        let status = TokenStatus.from(
            obtainedAt: 1_999_999_000_000, expiresIn: 4_000, now: now
        )
        #expect(status == .active(expiry: Date(timeIntervalSince1970: 2_000_003_000)))
    }

    @Test func missingFieldsAreIncomplete() {
        #expect(TokenStatus.from(obtainedAt: nil, expiresIn: 100, now: now) == .incomplete)
        #expect(TokenStatus.from(obtainedAt: 1_999_999_000, expiresIn: nil, now: now) == .incomplete)
    }
}
