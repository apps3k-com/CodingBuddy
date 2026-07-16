//
//  MCPAuthRecoveryTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct MCPAuthRecoveryTests {

    private struct Fixture {
        let home: URL
        let root: URL
        let version: URL
        let support: URL
        let staging: URL
        let recoveryRecord: URL
        let hash: String
    }

    private func makeFixture() throws -> Fixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPAuthRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let root = home.appendingPathComponent(".mcp-auth", isDirectory: true)
        let version = root.appendingPathComponent("mcp-remote-test", isDirectory: true)
        try FileManager.default.createDirectory(
            at: version,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let hash = String(repeating: "ab", count: 16)
        try #"{"access_token":"token","expires_in":3600}"#.write(
            to: version.appendingPathComponent("\(hash)_tokens.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"client_id":"client"}"#.write(
            to: version.appendingPathComponent("\(hash)_client_info.json"),
            atomically: true,
            encoding: .utf8
        )

        let support = home.appendingPathComponent("AppSupport", isDirectory: true)
        return Fixture(
            home: home,
            root: root,
            version: version,
            support: support,
            staging: support.appendingPathComponent("ResetStaging", isDirectory: true),
            recoveryRecord: support.appendingPathComponent("MCPAuthRecovery.json"),
            hash: hash
        )
    }

    private func makeStore(
        fixture: Fixture,
        trashItem: @escaping (URL) throws -> URL,
        recoveryRecordURL: URL? = nil,
        beforeRecoveryRename: @escaping (Int, URL) throws -> Void = { _, _ in }
    ) -> MCPAuthStore {
        MCPAuthStore(
            rootDirectory: fixture.root,
            configHomeDirectory: fixture.home,
            backupDirectory: fixture.support.appendingPathComponent("Backups", isDirectory: true),
            resetStagingDirectory: fixture.staging,
            recoveryRecordURL: recoveryRecordURL ?? fixture.recoveryRecord,
            trashItem: trashItem,
            beforeRecoveryRename: beforeRecoveryRename
        )
    }

    private func permissions(of url: URL) throws -> Int {
        try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        )
    }

    @Test func rollbackRetainsTransactionWhenParentIsReplacedAfterPreflight() throws {
        struct TrashFailure: Error {}
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let movedParent = fixture.root.appendingPathComponent("mcp-remote-moved", isDirectory: true)
        let replacementMarker = fixture.version.appendingPathComponent("replacement-marker")
        var replacedParent = false
        let store = makeStore(
            fixture: fixture,
            trashItem: { _ in throw TrashFailure() },
            beforeRecoveryRename: { index, _ in
                guard index == 0, !replacedParent else { return }
                replacedParent = true
                try FileManager.default.moveItem(at: fixture.version, to: movedParent)
                try FileManager.default.createDirectory(
                    at: fixture.version,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                try "replacement".write(
                    to: replacementMarker,
                    atomically: true,
                    encoding: .utf8
                )
            }
        )
        let entry = try #require(store.entries.first { $0.hash == fixture.hash })

        store.reset(entry)

        let recovery = try #require(store.lastRecoveryDirectory)
        let stagedNames = try FileManager.default.contentsOfDirectory(atPath: recovery.path)
        #expect(replacedParent)
        #expect(store.lastFailureKind == .recoveryRequired(recovery))
        #expect(stagedNames.count == entry.files.count)
        #expect(try FileManager.default.contentsOfDirectory(atPath: movedParent.path).isEmpty)
        #expect(try String(contentsOf: replacementMarker, encoding: .utf8) == "replacement")
    }

    @Test func freshStoreRediscoversRecoveryAfterTransactionMovesToTrash() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let trash = fixture.home.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(
            at: trash,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let unrelatedResult = fixture.home.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unrelatedResult,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        var movedTransaction: URL?
        do {
            let store = makeStore(
                fixture: fixture,
                trashItem: { stagedURL in
                    let destination = trash.appendingPathComponent(
                        stagedURL.lastPathComponent,
                        isDirectory: true
                    )
                    try FileManager.default.moveItem(at: stagedURL, to: destination)
                    movedTransaction = destination
                    let occupiedURL = fixture.version.appendingPathComponent(
                        "\(fixture.hash)_client_info.json"
                    )
                    try "concurrent replacement".write(
                        to: occupiedURL,
                        atomically: true,
                        encoding: .utf8
                    )
                    return unrelatedResult
                }
            )
            let entry = try #require(store.entries.first { $0.hash == fixture.hash })

            store.reset(entry)

            let recovery = try #require(store.lastRecoveryDirectory)
            #expect(recovery == movedTransaction)
            #expect(store.lastFailureKind == .recoveryRequired(recovery))
            #expect(FileManager.default.fileExists(atPath: fixture.recoveryRecord.path))
            #expect(try permissions(of: fixture.recoveryRecord) == 0o600)
        }

        let expectedRecovery = try #require(movedTransaction)
        var freshTrashCalls = 0
        let freshStore = makeStore(
            fixture: fixture,
            trashItem: { url in
                freshTrashCalls += 1
                return url
            }
        )

        #expect(freshStore.lastRecoveryDirectory == expectedRecovery)

        freshStore.resetAll()

        #expect(freshTrashCalls == 0)
        #expect(freshStore.lastRecoveryDirectory == expectedRecovery)
        #expect(freshStore.lastFailureKind == .recoveryRequired(expectedRecovery))
        #expect(FileManager.default.fileExists(atPath: expectedRecovery.path))
    }

    /// Verifies an intermediate link prevents reading or clearing an external recovery record.
    @Test func recoveryRecordRejectsIntermediateSymlinkWithoutTouchingExternalFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let external = fixture.home.appendingPathComponent("external-record", isDirectory: true)
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let externalRecord = external.appendingPathComponent("MCPAuthRecovery.json")
        try "external-record-must-survive".write(
            to: externalRecord,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: externalRecord.path
        )
        let configured = fixture.home.appendingPathComponent("configured-record", isDirectory: true)
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: false)
        let redirect = configured.appendingPathComponent("redirect", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: external)
        let configuredRecord = redirect.appendingPathComponent("MCPAuthRecovery.json")
        var trashCalls = 0
        let store = makeStore(
            fixture: fixture,
            trashItem: { url in
                trashCalls += 1
                return url
            },
            recoveryRecordURL: configuredRecord
        )

        store.resetAll()

        #expect(trashCalls == 0)
        #expect(store.lastRecoveryDirectory == configuredRecord)
        #expect(store.lastFailureKind == .recoveryRequired(configuredRecord))
        #expect(
            try String(contentsOf: externalRecord, encoding: .utf8)
                == "external-record-must-survive"
        )
        #expect(FileManager.default.fileExists(atPath: fixture.version.path))
    }

    /// Verifies a recovery-parent symlink swap cannot redirect durable record creation.
    @Test func recoveryPersistenceRejectsIntermediateSymlinkWithoutWritingExternalState() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let recordParent = fixture.home.appendingPathComponent("RecoveryParent", isDirectory: true)
        let displacedRecordParent = fixture.home
            .appendingPathComponent("RecoveryParentOriginal", isDirectory: true)
        let recoveryRecord = recordParent.appendingPathComponent("MCPAuthRecovery.json")
        try FileManager.default.createDirectory(
            at: recordParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let external = fixture.home.appendingPathComponent("external-persistence", isDirectory: true)
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let marker = external.appendingPathComponent("marker")
        try "external-safe".write(to: marker, atomically: true, encoding: .utf8)
        let trash = fixture.home.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(
            at: trash,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let unrelatedResult = fixture.home.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedResult, withIntermediateDirectories: false)
        let occupiedURL = fixture.version.appendingPathComponent("\(fixture.hash)_client_info.json")
        var movedTransaction: URL?
        var swapped = false
        let store = makeStore(
            fixture: fixture,
            trashItem: { stagedURL in
                let destination = trash.appendingPathComponent(
                    stagedURL.lastPathComponent,
                    isDirectory: true
                )
                try FileManager.default.moveItem(at: stagedURL, to: destination)
                movedTransaction = destination
                try "concurrent replacement".write(
                    to: occupiedURL,
                    atomically: true,
                    encoding: .utf8
                )
                try FileManager.default.moveItem(at: recordParent, to: displacedRecordParent)
                try FileManager.default.createSymbolicLink(
                    at: recordParent,
                    withDestinationURL: external
                )
                swapped = true
                return unrelatedResult
            },
            recoveryRecordURL: recoveryRecord
        )
        let entry = try #require(store.entries.first { $0.hash == fixture.hash })

        #expect(!store.reset(entry))

        let movedRecovery = try #require(movedTransaction)
        #expect(swapped)
        #expect(store.lastRecoveryDirectory == recoveryRecord)
        #expect(store.lastFailureKind == .recoveryRequired(movedRecovery))
        #expect(FileManager.default.fileExists(atPath: movedRecovery.path))
        #expect(!FileManager.default.fileExists(
            atPath: external.appendingPathComponent("MCPAuthRecovery.json").path
        ))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: external.path)) == ["marker"])
        #expect(try String(contentsOf: marker, encoding: .utf8) == "external-safe")
    }

    /// Verifies reset-all re-enumerates through the bounded descriptor path and
    /// refuses a cache that grows beyond the top-level ceiling after launch.
    @Test func resetAllRefusesExcessiveRootEntryCountAtActionTime() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        var trashCalls = 0
        let store = makeStore(
            fixture: fixture,
            trashItem: { url in
                trashCalls += 1
                return url
            }
        )
        #expect(store.recoveryDiscoveryRefusedAt == nil)

        for index in 0..<MCPAuthScanner.maximumVersionDirectoryCount {
            try FileManager.default.createDirectory(
                at: fixture.root.appendingPathComponent("unexpected-\(index)", isDirectory: true),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        store.resetAll()

        #expect(trashCalls == 0)
        #expect(store.recoveryDiscoveryRefusedAt == fixture.root)
        #expect(store.lastFailureKind == .other)
        #expect(store.lastError != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.version.path))
    }

    /// Verifies app-launch recovery discovery also bounds the private staging
    /// root and exposes a fail-closed state instead of silently returning none.
    @Test func storeReportsExcessiveRecoveryStagingEntryCount() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try FileManager.default.createDirectory(
            at: fixture.staging,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for index in 0...MCPAuthScanner.maximumVersionDirectoryCount {
            try FileManager.default.createDirectory(
                at: fixture.staging.appendingPathComponent("unexpected-\(index)", isDirectory: true),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let store = makeStore(fixture: fixture, trashItem: { $0 })

        #expect(store.recoveryDiscoveryRefusedAt == fixture.staging)
        #expect(store.lastRecoveryDirectory == nil)
        #expect(!store.entries.isEmpty)
    }
}
