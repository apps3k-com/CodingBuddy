//
//  EnvStoreTests.swift
//  EnvVarBuddyTests
//

import Foundation
import Testing
@testable import EnvVarBuddy

@MainActor
struct EnvStoreTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnvVarBuddyTests-\(UUID().uuidString)", isDirectory: true)
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
