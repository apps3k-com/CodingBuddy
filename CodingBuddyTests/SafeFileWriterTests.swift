//
//  SafeFileWriterTests.swift
//  CodingBuddyTests
//

import Darwin
import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct SafeFileWriterTests {
    /// Provides a stable bundle anchor for locating the app around the test plug-in.
    private final class BundleMarker: NSObject {}

    /// Resolves the built app bundle in both Xcode-hosted and direct `xctest` runs.
    private var applicationBundle: Bundle? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main
        }

        let appURL = Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return Bundle(url: appURL)
    }


    private enum InjectedFailure: Error, Equatable {
        case stop
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingBuddyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(of url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    private func recoveryFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("codingbuddy-recovery-") }
    }

    private func swapEntries(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func expectRecovery(
        commitState: SafeFileWriter.RecoveryError.CommitState,
        _ operation: () throws -> Void
    ) -> [SafeFileWriter.RecoveryArtifact] {
        do {
            try operation()
            Issue.record("Expected RecoveryError, but the operation succeeded")
            return []
        } catch let error as SafeFileWriter.RecoveryError {
            #expect(error.commitState == commitState)
            return error.artifacts
        } catch {
            Issue.record("Expected RecoveryError, got \(error)")
            return []
        }
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
        #expect(try recoveryFiles(in: dir).isEmpty)
    }

    @Test func firstDirectorySyncFailureRollsBackNewFile() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("new-file")
        var syncCalls = 0
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            syncDirectory: { descriptor in
                syncCalls += 1
                if syncCalls == 1 { throw InjectedFailure.stop }
                guard fsync(descriptor) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        )

        #expect(throws: InjectedFailure.stop) {
            try writer.write("new", to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try recoveryFiles(in: dir).isEmpty)
        #expect(syncCalls == 2)
    }

    @Test func firstDirectorySyncFailureRestoresDisplacedOriginal() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("existing-file")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        var syncCalls = 0
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            syncDirectory: { descriptor in
                syncCalls += 1
                if syncCalls == 1 { throw InjectedFailure.stop }
                guard fsync(descriptor) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        )

        #expect(throws: InjectedFailure.stop) {
            try writer.write("new", to: target, expectedOriginal: "old")
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        #expect(try recoveryFiles(in: dir).isEmpty)
        #expect(syncCalls == 2)
    }

    @Test func cleanupDirectorySyncFailureDoesNotInventRecoveryArtifact() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("existing-file")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        var syncCalls = 0
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            syncDirectory: { descriptor in
                syncCalls += 1
                if syncCalls == 2 { throw InjectedFailure.stop }
                guard fsync(descriptor) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        )

        do {
            try writer.write("new", to: target, expectedOriginal: "old")
            Issue.record("Expected CleanupDurabilityError, but the operation succeeded")
        } catch let error as SafeFileWriter.CleanupDurabilityError {
            #expect(error == SafeFileWriter.CleanupDurabilityError())
            #expect(error.errorDescription != nil)
        } catch {
            Issue.record("Expected CleanupDurabilityError, got \(error)")
        }

        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        #expect(try recoveryFiles(in: dir).isEmpty)
        #expect(syncCalls == 2)
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
        #expect(try recoveryFiles(in: dir).isEmpty)
        #expect(try recoveryFiles(in: backups).isEmpty)
    }

    /// Verifies non-positive retention input cannot remove the only recovery copy.
    @Test func nonPositiveBackupRetentionStillKeepsNewestBackup() throws {
        for retention in [0, -3] {
            let dir = try makeTempDir()
            let backups = dir.appendingPathComponent("Backups")
            let target = dir.appendingPathComponent("file")
            try "old".write(to: target, atomically: true, encoding: .utf8)

            try SafeFileWriter(backupDirectory: backups, backupRetention: retention)
                .write("new", to: target, expectedOriginal: "old")

            let entries = try FileManager.default.contentsOfDirectory(
                at: backups,
                includingPropertiesForKeys: nil
            )
            #expect(entries.count == 1)
            #expect(try String(contentsOf: entries[0], encoding: .utf8) == "old")
            #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        }
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

    @Test func macOSTemporaryDirectoryAliasDoesNotTriggerFalseSymlinkLoop() throws {
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: "/var")
        #expect(destination == "private/var")
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")

        try SafeFileWriter(backupDirectory: dir.appendingPathComponent("Backups"))
            .write("new", to: target)

        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
    }

    @Test func realIntermediateSymlinkCycleIsRejected() throws {
        let dir = try makeTempDir()
        let first = dir.appendingPathComponent("first")
        let second = dir.appendingPathComponent("second")
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: second)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)

        #expect(throws: POSIXError(.ELOOP)) {
            try SafeFileWriter(backupDirectory: dir.appendingPathComponent("Backups"))
                .write("new", to: first.appendingPathComponent("file"))
        }
    }

    /// Verifies bounded no-follow snapshots permit the macOS `/var` alias but
    /// still reject an intermediate symlink controlled inside the user path.
    @Test func noFollowSnapshotRejectsUserControlledIntermediateSymlink() throws {
        let dir = try makeTempDir()
        let realDirectory = dir.appendingPathComponent("real", isDirectory: true)
        let linkedDirectory = dir.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: false
        )
        try "secret".write(
            to: realDirectory.appendingPathComponent("credential.json"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: realDirectory
        )

        #expect(throws: SafeFileWriter.WriteError.unsafeTarget) {
            _ = try SafeFileWriter(backupDirectory: dir.appendingPathComponent("Backups"))
                .noFollowSnapshot(
                    at: linkedDirectory.appendingPathComponent("credential.json"),
                    maximumByteCount: 1024
                )
        }
    }

    @Test func expectedOriginalRejectsStaleContentBeforeBackup() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")
        let backups = dir.appendingPathComponent("Backups")
        try "outside".write(to: target, atomically: true, encoding: .utf8)

        #expect(throws: SafeFileWriter.WriteError.staleOriginal) {
            try SafeFileWriter(backupDirectory: backups)
                .write("new", to: target, expectedOriginal: "old")
        }

        #expect(try String(contentsOf: target, encoding: .utf8) == "outside")
        #expect(!FileManager.default.fileExists(atPath: backups.path))
    }

    @Test func inPlaceMutationBeforeCommitIsRejected() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            transactionHook: { point in
                guard case .beforeCommit = point else { return }
                let handle = try FileHandle(forWritingTo: target)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data("outside".utf8))
                try handle.close()
            }
        )

        #expect(throws: SafeFileWriter.WriteError.staleOriginal) {
            try writer.write("new", to: target, expectedOriginal: "old")
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "outside")
        #expect(try recoveryFiles(in: dir).isEmpty)
    }

    @Test func atomicReplacementAfterFinalValidationIsRestoredWithoutRecovery() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            transactionHook: { point in
                guard case .afterFinalValidation = point else { return }
                try "outside".write(to: target, atomically: true, encoding: .utf8)
            }
        )

        #expect(throws: SafeFileWriter.WriteError.staleOriginal) {
            try writer.write("new", to: target, expectedOriginal: "old")
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "outside")
        #expect(try recoveryFiles(in: dir).isEmpty)
    }

    @Test func secondRaceBeforeRollbackPreservesForeignFiles() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            transactionHook: { point in
                switch point {
                case .afterFinalValidation:
                    try "first-race".write(to: target, atomically: true, encoding: .utf8)
                case .beforeRollback:
                    try "second-race".write(to: target, atomically: true, encoding: .utf8)
                default:
                    break
                }
            }
        )

        let artifacts = expectRecovery(commitState: .unknown) {
            try writer.write("new", to: target, expectedOriginal: "old")
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "second-race")
        #expect(artifacts.count == 2)
        #expect(artifacts.map(\.context) == [.uncertainTarget, .uncertainDisplaced])

        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".codingbuddy-recovery-") }
        #expect(recoveryFiles.count == 1)
        #expect(try String(contentsOf: recoveryFiles[0], encoding: .utf8) == "first-race")
    }

    @Test func newFileParentReplacementAfterRenameCleansStagedFile() throws {
        let dir = try makeTempDir()
        let parent = dir.appendingPathComponent("parent", isDirectory: true)
        let movedParent = dir.appendingPathComponent("parent-moved", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("file")
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            transactionHook: { point in
                guard case .afterNewFileCommit = point else { return }
                try FileManager.default.moveItem(at: parent, to: movedParent)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
        )

        #expect(throws: SafeFileWriter.WriteError.staleOriginal) {
            try writer.write("new", to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: movedParent.appendingPathComponent("file").path))
        #expect(try recoveryFiles(in: movedParent).isEmpty)
    }

    @Test func newFileSymlinkRetargetAfterRenameIsRejected() throws {
        let dir = try makeTempDir()
        let original = dir.appendingPathComponent("original", isDirectory: true)
        let other = dir.appendingPathComponent("other", isDirectory: true)
        let link = dir.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            transactionHook: { point in
                guard case .afterNewFileCommit = point else { return }
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
            }
        )

        #expect(throws: SafeFileWriter.WriteError.staleOriginal) {
            try writer.write("new", to: link.appendingPathComponent("file"))
        }
        #expect(!FileManager.default.fileExists(atPath: original.appendingPathComponent("file").path))
        #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent("file").path))
        #expect(try recoveryFiles(in: original).isEmpty)
    }

    @Test func newFileForeignReplacementAfterRenameIsNeverUnlinked() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            transactionHook: { point in
                guard case .afterNewFileCommit = point else { return }
                try "outside".write(to: target, atomically: true, encoding: .utf8)
            }
        )

        let artifacts = expectRecovery(commitState: .unknown) {
            try writer.write("new", to: target)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "outside")
        #expect(artifacts.map(\.context) == [.stagedWrite])
    }

    @Test func cleanupReplacementAfterQuarantineValidationIsNeverDeleted() throws {
        let dir = try makeTempDir()
        let parent = dir.appendingPathComponent("parent", isDirectory: true)
        let movedParent = dir.appendingPathComponent("parent-moved", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("file")
        let movedTarget = movedParent.appendingPathComponent("file")
        let replacement = movedParent.appendingPathComponent("replacement")
        var racedCleanup = false
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            transactionHook: { point in
                switch point {
                case .afterNewFileCommit:
                    try FileManager.default.moveItem(at: parent, to: movedParent)
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    try "outside".write(to: replacement, atomically: true, encoding: .utf8)
                case .afterQuarantineValidation where !racedCleanup:
                    racedCleanup = true
                    guard let quarantine = try recoveryFiles(in: movedParent).first else {
                        throw InjectedFailure.stop
                    }
                    try swapEntries(quarantine, replacement)
                default:
                    break
                }
            }
        )

        let artifacts = expectRecovery(commitState: .unknown) {
            try writer.write("new", to: target)
        }
        #expect(racedCleanup)
        #expect(artifacts.map(\.context) == [.stagedWrite])
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: movedTarget.path))
        #expect(try String(contentsOf: replacement, encoding: .utf8) == "new")
        let recovery = try recoveryFiles(in: movedParent)
        #expect(recovery.count == 1)
        #expect(try String(contentsOf: recovery[0], encoding: .utf8) == "outside")
    }

    @Test func recoveryErrorsExplainCommitStateAndRetainedPath() {
        let path = "/tmp/codingbuddy-recovery-file"
        let artifact = SafeFileWriter.RecoveryArtifact(
            lastKnownPath: path,
            context: .stagedWrite
        )

        let notCommitted = SafeFileWriter.RecoveryError(
            commitState: .notCommitted,
            artifacts: [artifact]
        ).localizedDescription
        let committed = SafeFileWriter.RecoveryError(
            commitState: .committed,
            artifacts: [artifact]
        ).localizedDescription
        let unknown = SafeFileWriter.RecoveryError(
            commitState: .unknown,
            artifacts: [artifact]
        ).localizedDescription

        #expect(notCommitted.contains(path))
        #expect(committed.contains(path))
        #expect(unknown.contains(path))
        #expect(Set([notCommitted, committed, unknown]).count == 3)
    }

    @Test func safeWriterErrorCopyHasGermanTranslations() throws {
        let germanResources = try #require(
            applicationBundle?.url(forResource: "de", withExtension: "lproj")
        )
        let germanBundle = try #require(Bundle(url: germanResources))
        let keys = [
            "CodingBuddy did not save the requested change. Review the retained recovery file at %@ before retrying.",
            "CodingBuddy saved the requested change, but cleanup stopped. Review the retained recovery file at %@ before editing again.",
            "CodingBuddy cannot confirm the final save state. Review the retained recovery file at %@ before editing again.",
            "CodingBuddy saved the requested change, but macOS could not confirm that cleanup was durable. Verify the current file before editing again."
        ]

        for key in keys {
            let value = germanBundle.localizedString(forKey: key, value: nil, table: "Localizable")
            #expect(!value.isEmpty)
            #expect(value != key)
            #expect(value.contains("%@") == key.contains("%@"))
        }
    }

    @Test func appearingNewTargetCannotBeOverwritten() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            transactionHook: { point in
                guard case .afterFinalValidation = point else { return }
                try "outside".write(to: target, atomically: true, encoding: .utf8)
            }
        )

        #expect(throws: SafeFileWriter.WriteError.staleOriginal) {
            try writer.write("new", to: target)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "outside")
        #expect(try recoveryFiles(in: dir).isEmpty)
    }

    @Test func finalSymlinkRetargetBeforeCommitIsRejected() throws {
        let dir = try makeTempDir()
        let original = dir.appendingPathComponent("original")
        let other = dir.appendingPathComponent("other")
        let link = dir.appendingPathComponent("link")
        try "old".write(to: original, atomically: true, encoding: .utf8)
        try "other".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            transactionHook: { point in
                guard case .beforeCommit = point else { return }
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
            }
        )

        #expect(throws: SafeFileWriter.WriteError.staleOriginal) {
            try writer.write("new", to: link, expectedOriginal: "old")
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "old")
        #expect(try String(contentsOf: other, encoding: .utf8) == "other")
    }

    @Test func intermediateSymlinkParentReplacementBeforeCommitIsRejected() throws {
        let dir = try makeTempDir()
        let links = dir.appendingPathComponent("links", isDirectory: true)
        let movedLinks = dir.appendingPathComponent("links-moved", isDirectory: true)
        let real = dir.appendingPathComponent("real")
        let link = links.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        try "old".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let writer = SafeFileWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            transactionHook: { point in
                guard case .beforeCommit = point else { return }
                try FileManager.default.moveItem(at: links, to: movedLinks)
                try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    at: links.appendingPathComponent("target"),
                    withDestinationURL: real
                )
            }
        )

        #expect(throws: SafeFileWriter.WriteError.staleOriginal) {
            try writer.write("new", to: link, expectedOriginal: "old")
        }
        #expect(try String(contentsOf: real, encoding: .utf8) == "old")
    }

    @Test func danglingFinalSymlinkIsRejected() throws {
        let dir = try makeTempDir()
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: dir.appendingPathComponent("missing")
        )

        #expect(throws: SafeFileWriter.WriteError.danglingSymlink) {
            try SafeFileWriter(backupDirectory: dir.appendingPathComponent("Backups"))
                .write("new", to: link)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func failedBackupCleanupRetainsPostValidationReplacement() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")
        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        let replacement = backups.appendingPathComponent("replacement")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try "outside".write(to: replacement, atomically: true, encoding: .utf8)
        var racedCleanup = false
        let writer = SafeFileWriter(
            backupDirectory: backups,
            transactionHook: { point in
                switch point {
                case .beforeBackupSync:
                    throw InjectedFailure.stop
                case .afterQuarantineValidation where !racedCleanup:
                    racedCleanup = true
                    guard let quarantine = try recoveryFiles(in: backups).first else {
                        throw InjectedFailure.stop
                    }
                    try swapEntries(quarantine, replacement)
                default:
                    break
                }
            }
        )

        let artifacts = expectRecovery(commitState: .notCommitted) {
            try writer.write("new", to: target, expectedOriginal: "old")
        }

        #expect(racedCleanup)
        #expect(artifacts.map(\.context) == [.failedBackup])
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        #expect(try String(contentsOf: replacement, encoding: .utf8) == "old")
        let recovery = try recoveryFiles(in: backups)
        #expect(recovery.count == 1)
        #expect(try String(contentsOf: recovery[0], encoding: .utf8) == "outside")
    }

    @Test func pruningRetainsPostValidationReplacementOutsideActiveBackups() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")
        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        let oldest = backups.appendingPathComponent("file-2000-01-01-000000-000")
        let older = backups.appendingPathComponent("file-2001-01-01-000000-000")
        let replacement = backups.appendingPathComponent("replacement")
        try "current-old".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try "oldest".write(to: oldest, atomically: true, encoding: .utf8)
        try "older".write(to: older, atomically: true, encoding: .utf8)
        try "outside".write(to: replacement, atomically: true, encoding: .utf8)
        var racedCleanup = false
        let writer = SafeFileWriter(
            backupDirectory: backups,
            backupRetention: 1,
            transactionHook: { point in
                guard case .afterQuarantineValidation = point, !racedCleanup else { return }
                racedCleanup = true
                guard let quarantine = try recoveryFiles(in: backups).first else {
                    throw InjectedFailure.stop
                }
                try swapEntries(quarantine, replacement)
            }
        )

        let artifacts = expectRecovery(commitState: .notCommitted) {
            try writer.write("new", to: target, expectedOriginal: "current-old")
        }

        #expect(racedCleanup)
        #expect(artifacts.map(\.context) == [.prunedBackup])
        #expect(try String(contentsOf: target, encoding: .utf8) == "current-old")
        #expect(try String(contentsOf: replacement, encoding: .utf8) == "oldest")
        let activeBackups = try FileManager.default.contentsOfDirectory(
            at: backups,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("file-") }
        #expect(activeBackups.count == 1)
        #expect(try String(contentsOf: activeBackups[0], encoding: .utf8) == "current-old")
        let recovery = try recoveryFiles(in: backups)
        #expect(recovery.count == 1)
        let recoveryContents = try recovery.map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(recoveryContents == ["outside"])
    }

    /// Verifies a full backup directory stops the write before a backup or target mutation is attempted.
    @Test func backupCapacityOverflowStopsBeforeTargetMutation() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")
        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        try "old".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        for name in ["unrelated-a", "unrelated-b", "unrelated-c"] {
            try "noise".write(
                to: backups.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
        let writer = SafeFileWriter(
            backupDirectory: backups,
            maximumBackupDirectoryEntryCount: 3
        )

        #expect(throws: SafeFileWriter.WriteError.backupDirectoryTooLarge(maximum: 3)) {
            try writer.write("new", to: target, expectedOriginal: "old")
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        let entries = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        #expect(Set(entries) == Set(["unrelated-a", "unrelated-b", "unrelated-c"]))
    }

    /// Verifies retention rechecks its bound after backup creation and refuses racing growth.
    @Test func retentionOverflowAfterBackupCreationStopsBeforeTargetMutation() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")
        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        try "old".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try "noise".write(
            to: backups.appendingPathComponent("unrelated-existing"),
            atomically: true,
            encoding: .utf8
        )
        var addedRacingEntries = false
        let writer = SafeFileWriter(
            backupDirectory: backups,
            maximumBackupDirectoryEntryCount: 3,
            transactionHook: { point in
                guard case .beforeBackupSync = point, !addedRacingEntries else { return }
                addedRacingEntries = true
                try "noise".write(
                    to: backups.appendingPathComponent("unrelated-race-a"),
                    atomically: true,
                    encoding: .utf8
                )
                try "noise".write(
                    to: backups.appendingPathComponent("unrelated-race-b"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        )

        #expect(throws: SafeFileWriter.WriteError.backupDirectoryTooLarge(maximum: 3)) {
            try writer.write("new", to: target, expectedOriginal: "old")
        }
        #expect(addedRacingEntries)
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        let entries = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        #expect(entries.count == 4)
        #expect(entries.contains { $0.hasPrefix("file-") })
    }

    @Test func symlinkedBackupDirectoryIsRejected() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        try "old".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: backups, withDestinationURL: outside)

        #expect(throws: SafeFileWriter.WriteError.unsafeBackupDirectory) {
            try SafeFileWriter(backupDirectory: backups)
                .write("new", to: target, expectedOriginal: "old")
        }

        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func backupDirectoryIsPrivate() throws {
        let dir = try makeTempDir()
        let target = dir.appendingPathComponent("file")
        let backups = dir.appendingPathComponent("Backups")
        try "old".write(to: target, atomically: true, encoding: .utf8)

        try SafeFileWriter(backupDirectory: backups)
            .write("new", to: target, expectedOriginal: "old")

        #expect(try mode(of: backups) == 0o700)
    }
}
