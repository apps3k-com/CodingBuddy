//
//  CapabilityFingerprintTests.swift
//  CodingBuddyTests
//

import CryptoKit
import Foundation
import Testing
@testable import CodingBuddy

/// Equality and non-disclosure tests for opaque capability fingerprints.
nonisolated struct CapabilityFingerprintTests {
    /// One scan key preserves equality while different scans cannot create reusable secret hashes.
    @Test func secretBearingFingerprintsAreScanLocal() {
        let firstKey = SymmetricKey(size: .bits256)
        let secondKey = SymmetricKey(size: .bits256)
        let secretBytes = Data("token=fixture-secret".utf8)

        let first = CapabilityFingerprint.secretBearingContent(
            schemaVersion: "mcp-json-v1",
            data: secretBytes,
            key: firstKey
        )
        let sameScan = CapabilityFingerprint.secretBearingContent(
            schemaVersion: "mcp-json-v1",
            data: secretBytes,
            key: firstKey
        )
        let laterScan = CapabilityFingerprint.secretBearingContent(
            schemaVersion: "mcp-json-v1",
            data: secretBytes,
            key: secondKey
        )

        #expect(first == sameScan)
        #expect(first != laterScan)
        #expect(first.description == "<opaque capability fingerprint>")
        #expect(first.debugDescription == first.description)
        #expect(!String(reflecting: first).contains("fixture-secret"))
    }

    /// Canonical schema revisions are domain-separated even when content bytes match.
    @Test func publicFingerprintsAreVersionSeparated() {
        let data = Data("public-skill-content".utf8)

        let versionOne = CapabilityFingerprint.publicContent(schemaVersion: "skill-tree-v1", data: data)
        let versionTwo = CapabilityFingerprint.publicContent(schemaVersion: "skill-tree-v2", data: data)

        #expect(versionOne != versionTwo)
    }
}
