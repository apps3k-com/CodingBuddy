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
    /// Creates a complete occurrence for stable-identity tests.
    private func item(scope: String, sourcePath: String, identity: String) -> CapabilityInventoryItem {
        CapabilityInventoryItem(
            kind: .skill,
            consumer: .codex,
            runtimeIdentity: identity,
            sourcePath: sourcePath,
            effectiveScope: scope,
            registrationState: .installed,
            activationState: .enabled,
            sourceStatus: .complete,
            canonicalFingerprint: .publicContent(
                schemaVersion: "test-v1",
                data: Data(sourcePath.utf8)
            )
        )
    }

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

    /// Provider-controlled delimiters cannot collapse distinct occurrence identities.
    @Test func inventoryIDsAreUnambiguous() {
        let first = item(scope: "user", sourcePath: "/skills|review", identity: "helper")
        let second = item(scope: "user", sourcePath: "/skills", identity: "review|helper")

        #expect(first.id != second.id)
    }

    /// Delimiters inside occurrence IDs cannot collapse distinct finding identities.
    @Test func findingIDsAreUnambiguous() {
        let first = CapabilityHygieneFinding(
            kind: .possibleOverlap,
            itemIDs: ["alpha|beta", "gamma"],
            explanation: "fixture",
            recommendation: "fixture",
            similarity: 0.75,
            shadowResolution: nil
        )
        let second = CapabilityHygieneFinding(
            kind: .possibleOverlap,
            itemIDs: ["alpha", "beta|gamma"],
            explanation: "fixture",
            recommendation: "fixture",
            similarity: 0.75,
            shadowResolution: nil
        )

        #expect(first.id != second.id)
    }

    /// Distinct provider evidence cannot collapse shadow rows for the same winner and loser.
    @Test func shadowFindingIDsIncludeProviderEvidence() {
        let firstEvidence = CapabilityPrecedenceEvidence(
            provider: .codex,
            ruleIdentifier: "workspace-wins",
            evaluationScope: "/workspace/one",
            winnerItemID: "winner",
            loserItemID: "loser"
        )
        let secondEvidence = CapabilityPrecedenceEvidence(
            provider: .codex,
            ruleIdentifier: "workspace-wins",
            evaluationScope: "/workspace/two",
            winnerItemID: "winner",
            loserItemID: "loser"
        )
        let first = CapabilityHygieneFinding(
            kind: .shadowing,
            itemIDs: ["winner", "loser"],
            explanation: "fixture",
            recommendation: "fixture",
            similarity: nil,
            shadowResolution: CapabilityShadowResolution(
                winnerItemID: "winner",
                loserItemID: "loser",
                evidence: firstEvidence
            )
        )
        let second = CapabilityHygieneFinding(
            kind: .shadowing,
            itemIDs: ["winner", "loser"],
            explanation: "fixture",
            recommendation: "fixture",
            similarity: nil,
            shadowResolution: CapabilityShadowResolution(
                winnerItemID: "winner",
                loserItemID: "loser",
                evidence: secondEvidence
            )
        )

        #expect(first.id != second.id)
    }
}
