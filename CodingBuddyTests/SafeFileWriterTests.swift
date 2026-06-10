//
//  SafeFileWriterTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct SafeFileWriterTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingBuddyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(of url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    @Test func createModeAppliesToNewFiles() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("mcp.env")
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"), createMode: 0o600
        )

        try writer.write("TOKEN=x\n", to: target)

        #expect(try mode(of: target) == 0o600)
        #expect(try String(contentsOf: target, encoding: .utf8) == "TOKEN=x\n")
    }

    @Test func existingPermissionsArePreservedOverCreateMode() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"), createMode: 0o600
        )

        try writer.write("new", to: target)

        #expect(try mode(of: target) == 0o644)
    }

    @Test func backsUpBeforeOverwriting() throws {
        let dir = try makeTempDir()
        let backups = dir.appendingPathComponent("Backups")
        let target = dir.appendingPathComponent(".zshrc")
        try "original".write(to: target, atomically: true, encoding: .utf8)

        try SafeFileWriter(backupDirectory: backups).write("changed", to: target)

        let entries = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        #expect(entries.count == 1)
        #expect(try String(contentsOf: entries[0], encoding: .utf8) == "original")
    }

    @Test func unchangedContentDoesNotBackUp() throws {
        let dir = try makeTempDir()
        let backups = dir.appendingPathComponent("Backups")
        let target = dir.appendingPathComponent("file")
        try "same".write(to: target, atomically: true, encoding: .utf8)

        try SafeFileWriter(backupDirectory: backups).write("same", to: target)

        #expect(!FileManager.default.fileExists(atPath: backups.path))
    }

    @Test func writesThroughSymlinks() throws {
        let dir = try makeTempDir()
        let real = dir.appendingPathComponent("real")
        let link = dir.appendingPathComponent("link")
        try "old".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try SafeFileWriter(backupDirectory: dir.appendingPathComponent("Backups")).write("new", to: link)

        #expect(try String(contentsOf: real, encoding: .utf8) == "new")
        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
    }
}
