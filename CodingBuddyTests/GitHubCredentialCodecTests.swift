//
//  GitHubCredentialCodecTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Tests fail-closed migration and versioning for the secret-bearing Keychain payload.
nonisolated struct GitHubCredentialCodecTests {
    /// Verifies a legacy raw PAT remains readable and is normalized during migration.
    @Test func decodesLegacyRawPAT() throws {
        let credential = try GitHubCredentialCodec.decode(Data("  legacy-pat\n".utf8))

        #expect(credential == .personalAccessToken("legacy-pat"))
    }

    /// Verifies complete rotating metadata survives a current-version round trip.
    @Test func roundTripsCurrentCredentialEnvelope() throws {
        let credential = GitHubCredential(
            source: .githubAppDeviceFlow,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
            refreshTokenExpiresAt: Date(timeIntervalSince1970: 2_000)
        )

        let decoded = try GitHubCredentialCodec.decode(
            GitHubCredentialCodec.encode(credential)
        )

        #expect(decoded == credential)
    }

    /// Verifies an unknown future envelope never falls back to a raw token.
    @Test func rejectsUnknownEnvelopeVersion() {
        let data = Data(#"{"version":2,"credential":{"source":"githubAppDeviceFlow","accessToken":"access","refreshToken":null,"accessTokenExpiresAt":null,"refreshTokenExpiresAt":null}}"#.utf8)

        #expect(throws: GitHubTokenStoreError.invalidData) {
            try GitHubCredentialCodec.decode(data)
        }
    }

    /// Verifies malformed JSON with leading whitespace cannot masquerade as a legacy PAT.
    @Test func rejectsCorruptJSONWithLeadingWhitespace() {
        #expect(throws: GitHubTokenStoreError.invalidData) {
            try GitHubCredentialCodec.decode(Data(" \n {not-json".utf8))
        }
    }

    /// Verifies blank legacy values and invalid UTF-8 fail closed.
    @Test func rejectsBlankAndNonUTF8Data() {
        #expect(throws: GitHubTokenStoreError.invalidData) {
            try GitHubCredentialCodec.decode(Data(" \n\t".utf8))
        }
        #expect(throws: GitHubTokenStoreError.invalidData) {
            try GitHubCredentialCodec.decode(Data([0xFF, 0xFE]))
        }
    }
}
