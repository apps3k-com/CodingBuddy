//
//  LegacyMigrationTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct LegacyMigrationTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CodingBuddyTests-\(UUID().uuidString)")!
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingBuddyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - UserDefaults

    @Test func copiesLegacyValuesIntoEmptyDomain() {
        let target = makeDefaults()
        LegacyMigration.migrateDefaults(
            from: ["appearanceMode": "dark", "flag.secretsProtection": false],
            into: target
        )
        #expect(target.string(forKey: "appearanceMode") == "dark")
        #expect(target.object(forKey: "flag.secretsProtection") as? Bool == false)
    }

    @Test func neverOverwritesExistingValues() {
        let target = makeDefaults()
        target.set("light", forKey: "appearanceMode")
        LegacyMigration.migrateDefaults(from: ["appearanceMode": "dark"], into: target)
        #expect(target.string(forKey: "appearanceMode") == "light")
    }

    // MARK: - Backup directory

    @Test func movesLegacyBackupsWhenTargetMissing() throws {
        let support = try makeTempDir()
        let old = support.appendingPathComponent("EnvVarBuddy", isDirectory: true)
        let new = support.appendingPathComponent("CodingBuddy", isDirectory: true)
        try FileManager.default.createDirectory(
            at: old.appendingPathComponent("Backups"), withIntermediateDirectories: true)
        try "backup".write(
            to: old.appendingPathComponent("Backups/zshrc-1"), atomically: true, encoding: .utf8)

        LegacyMigration.migrateSupportDirectory(from: old, to: new)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        let migrated = new.appendingPathComponent("Backups/zshrc-1")
        #expect(try String(contentsOf: migrated, encoding: .utf8) == "backup")
    }

    @Test func doesNothingWhenLegacyDirectoryIsAbsent() throws {
        let support = try makeTempDir()
        let old = support.appendingPathComponent("EnvVarBuddy", isDirectory: true)
        let new = support.appendingPathComponent("CodingBuddy", isDirectory: true)

        LegacyMigration.migrateSupportDirectory(from: old, to: new)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    @Test func leavesEverythingWhenTargetExists() throws {
        let support = try makeTempDir()
        let old = support.appendingPathComponent("EnvVarBuddy", isDirectory: true)
        let new = support.appendingPathComponent("CodingBuddy", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)

        LegacyMigration.migrateSupportDirectory(from: old, to: new)

        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.path))
    }
}
