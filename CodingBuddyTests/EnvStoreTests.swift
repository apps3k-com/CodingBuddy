//
//  EnvStoreTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct EnvStoreTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingBuddyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(zshenv: String? = nil, zshrc: String? = nil) throws -> EnvStore {
        let home = try makeTempDir()
        if let zshenv {
            try zshenv.write(to: ShellConfigFile.zshenv.url(in: home), atomically: true, encoding: .utf8)
        }
        if let zshrc {
            try zshrc.write(to: ShellConfigFile.zshrc.url(in: home), atomically: true, encoding: .utf8)
        }
        return EnvStore(homeDirectory: home, backupDirectory: home.appendingPathComponent("Backups"))
    }

    /// Creates a store whose supported files can be prepared as raw filesystem fixtures.
    private func makeStore(home: URL) -> EnvStore {
        EnvStore(homeDirectory: home, backupDirectory: home.appendingPathComponent("Backups"))
    }

    // MARK: - Access states

    @Test func missingFilesAreCompleteAndRemainCreatable() throws {
        let home = try makeTempDir()
        let store = makeStore(home: home)

        for file in ShellConfigFile.allCases {
            #expect(store.accessState(for: file) == .missing)
            #expect(store.accessState(in: file) == .complete)
            #expect(store.accessState(in: file).allowsActions)
        }
        #expect(store.accessState(in: nil) == .complete)
        #expect(store.accessState(in: nil).allowsActions)
        #expect(store.variables.isEmpty)
    }

    @Test func validUTF8FileIsLoadedAndActionsRemainAvailable() throws {
        let store = try makeStore(zshrc: "export READY=yes\n")

        #expect(store.accessState(for: .zshrc) == .loaded)
        #expect(store.accessState(in: .zshrc) == .complete)
        #expect(store.accessState(in: nil).allowsActions)
        #expect(store.variables(in: .zshrc).map(\.name) == ["READY"])
        #expect(store.existingFiles.contains(.zshrc))
    }

    @Test func unreadableExistingFileIsRefusedWithoutLeakingItsPath() throws {
        let home = try makeTempDir()
        let url = ShellConfigFile.zshrc.url(in: home)
        try "export SECRET=value\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        let store = makeStore(home: home)
        let expected = EnvScopeAccessState.refused([
            EnvFileRefusal(file: .zshrc, reason: .unreadable)
        ])

        #expect(store.accessState(for: .zshrc) == .refused(.unreadable))
        #expect(store.accessState(in: .zshrc) == expected)
        #expect(!store.accessState(in: .zshrc).allowsActions)
        #expect(store.variables(in: .zshrc).isEmpty)
        #expect(!EnvFileRefusalReason.unreadable.localizedDescription.contains(home.path))
    }

    @Test func nonUTF8ExistingFileIsRefused() throws {
        let home = try makeTempDir()
        try Data([0x66, 0x6f, 0x80, 0x6f]).write(to: ShellConfigFile.zshrc.url(in: home))
        let store = makeStore(home: home)

        #expect(store.accessState(for: .zshrc) == .refused(.invalidUTF8))
        #expect(store.accessState(in: .zshrc) == .refused([
            EnvFileRefusal(file: .zshrc, reason: .invalidUTF8)
        ]))
        #expect(!store.accessState(in: .zshrc).allowsActions)
        #expect(store.variables(in: .zshrc).isEmpty)
    }

    @Test func danglingSymlinkIsRefusedRatherThanReportedAsCreatable() throws {
        let home = try makeTempDir()
        let target = home.appendingPathComponent("missing-target")
        try FileManager.default.createSymbolicLink(
            at: ShellConfigFile.zshrc.url(in: home),
            withDestinationURL: target
        )
        let store = makeStore(home: home)

        #expect(store.accessState(for: .zshrc) == .refused(.unreadable))
        #expect(!store.accessState(in: .zshrc).allowsActions)
        #expect(store.existingFiles.contains(.zshrc))
    }

    @Test func mixedScopePreservesLoadedRowsButReportsIncompleteData() throws {
        let home = try makeTempDir()
        try "export SAFE=visible\n".write(
            to: ShellConfigFile.zshenv.url(in: home),
            atomically: true,
            encoding: .utf8
        )
        try Data([0xff]).write(to: ShellConfigFile.zshrc.url(in: home))
        let store = makeStore(home: home)
        let refusal = EnvFileRefusal(file: .zshrc, reason: .invalidUTF8)

        #expect(store.accessState(in: nil) == .partial([refusal]))
        #expect(!store.accessState(in: nil).allowsActions)
        #expect(store.variables.map(\.name) == ["SAFE"])
        #expect(store.accessState(in: .zshenv) == .complete)
        #expect(store.accessState(in: .zshenv).allowsActions)
        #expect(store.accessState(in: .zprofile) == .complete)
        #expect(store.accessState(in: .zprofile).allowsActions)
        #expect(!store.accessState(in: .zshrc).allowsActions)
    }

    @Test func failedMutationReloadsAFileThatBecameInvalid() throws {
        let store = try makeStore(zshrc: "export VALUE=before\n")
        let variable = try #require(store.variables(in: .zshrc).first)
        try Data([0xff]).write(to: ShellConfigFile.zshrc.url(in: store.homeDirectory))

        let updated = store.update(variable, name: "VALUE", rawValue: "after", exported: true)

        #expect(!updated)
        #expect(store.accessState(for: .zshrc) == .refused(.invalidUTF8))
        #expect(!store.accessState(in: .zshrc).allowsActions)
        #expect(store.variables(in: .zshrc).isEmpty)
        #expect(store.lastError != nil)
    }

    @Test func refusedTargetRejectsDirectMutationAndReloadsSafely() throws {
        let home = try makeTempDir()
        try Data([0xff]).write(to: ShellConfigFile.zshrc.url(in: home))
        let store = makeStore(home: home)

        let added = store.addAll([(name: "UNSAFE", rawValue: "value")], to: .zshrc)

        #expect(!added)
        #expect(store.accessState(for: .zshrc) == .refused(.invalidUTF8))
        #expect(store.variables(in: .zshrc).isEmpty)
        #expect(store.lastError == String(localized: "This shell file is unavailable. Retry before making changes."))
    }

    // MARK: - Hiding overridden assignments

    @Test func hidingKeepsOnlyTheEffectiveAssignments() throws {
        let store = try makeStore(
            zshenv: "export FOO=a\n",
            zshrc: "export FOO=b\nexport BAR=c\nexport FOO=d\n"
        )

        let visible = store.variables(in: nil, hidingOverridden: true)
        #expect(visible.map(\.name).sorted() == ["BAR", "FOO"])
        #expect(visible.first { $0.name == "FOO" }?.rawValue == "d")
    }

    @Test func hidingAppliesGlobalPrecedenceInsideAFileScope() throws {
        // FOO in .zshenv is shadowed by .zshrc, so the .zshenv scope shows
        // nothing when overridden assignments are hidden.
        let store = try makeStore(
            zshenv: "export FOO=a\n",
            zshrc: "export FOO=b\n"
        )

        #expect(store.variables(in: .zshenv, hidingOverridden: true).isEmpty)
        #expect(store.variables(in: .zshrc, hidingOverridden: true).map(\.rawValue) == ["b"])
    }

    @Test func notHidingReturnsEveryAssignment() throws {
        let store = try makeStore(
            zshenv: "export FOO=a\n",
            zshrc: "export FOO=b\n"
        )

        #expect(store.variables(in: nil, hidingOverridden: false).count == 2)
        #expect(store.variables(in: nil).count == 2)
    }
}
