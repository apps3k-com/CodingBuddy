//
//  WriterTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct WriterTests {

    private nonisolated static let fixture = """
    # my zshrc
    export EDITOR="vim"
    LANG=de_CH.UTF-8

    alias ll='ls -l'
    export PATH="$PATH:/opt/bin" # tools

    """

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingBuddyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFixtureFile(in dir: URL, content: String = fixture) throws -> URL {
        let url = dir.appendingPathComponent(".zshrc")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeWriter(in dir: URL, retention: Int = 20) -> ShellConfigWriter {
        ShellConfigWriter(
            backupDirectory: dir.appendingPathComponent("Backups"),
            backupRetention: retention
        )
    }

    private func parse(_ url: URL) throws -> [EnvVariable] {
        ShellConfigParser.variables(in: try String(contentsOf: url, encoding: .utf8), file: .zshrc)
    }

    private func content(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func variable(named name: String, in url: URL) throws -> EnvVariable {
        try #require(try parse(url).first { $0.name == name })
    }

    // MARK: - Update

    @Test func updateChangesOnlyTheTargetLine() throws {
        let dir = try makeTempDir()
        let file = try makeFixtureFile(in: dir)
        let editor = try variable(named: "EDITOR", in: file)

        try makeWriter(in: dir).updateVariable(
            editor, newName: "EDITOR", newRawValue: "nano", exported: true, at: file
        )

        let expected = Self.fixture.replacingOccurrences(
            of: "export EDITOR=\"vim\"", with: "export EDITOR=\"nano\""
        )
        #expect(try content(of: file) == expected)
    }

    @Test func updateSwitchesQuotingWhenValueNeedsIt() throws {
        let dir = try makeTempDir()
        let file = try makeFixtureFile(in: dir)
        let lang = try variable(named: "LANG", in: file)

        // A value with spaces cannot stay unquoted.
        try makeWriter(in: dir).updateVariable(
            lang, newName: "LANG", newRawValue: "de_CH.UTF-8 extra", exported: false, at: file
        )

        #expect(try content(of: file).contains("LANG=\"de_CH.UTF-8 extra\""))
    }

    @Test func updateRejectsStaleVariable() throws {
        let dir = try makeTempDir()
        let file = try makeFixtureFile(in: dir)
        let editor = try variable(named: "EDITOR", in: file)

        // External change shifts the lines under the parsed variable.
        try ("# inserted\n" + Self.fixture).write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: ShellConfigWriter.WriteError.fileChangedExternally) {
            try makeWriter(in: dir).updateVariable(
                editor, newName: "EDITOR", newRawValue: "nano", exported: true, at: file
            )
        }
    }

    @Test func updateRejectsReadOnlyLines() throws {
        let dir = try makeTempDir()
        let file = try makeFixtureFile(in: dir, content: "export TODAY=$(date +%F)\n")
        let today = try variable(named: "TODAY", in: file)

        #expect(throws: ShellConfigWriter.WriteError.lineNotEditable) {
            try makeWriter(in: dir).updateVariable(
                today, newName: "TODAY", newRawValue: "x", exported: true, at: file
            )
        }
    }

    @Test func updateRejectsInvalidNamesAndCommandSubstitution() throws {
        let dir = try makeTempDir()
        let file = try makeFixtureFile(in: dir)
        let editor = try variable(named: "EDITOR", in: file)
        let writer = makeWriter(in: dir)

        #expect(throws: ShellConfigWriter.WriteError.invalidName("1BAD")) {
            try writer.updateVariable(editor, newName: "1BAD", newRawValue: "x", exported: true, at: file)
        }
        #expect(throws: ShellConfigWriter.WriteError.commandSubstitutionNotAllowed) {
            try writer.updateVariable(editor, newName: "EDITOR", newRawValue: "$(date)", exported: true, at: file)
        }
    }

    // MARK: - Delete

    @Test func deleteRemovesExactlyTheTargetLine() throws {
        let dir = try makeTempDir()
        let file = try makeFixtureFile(in: dir)
        let lang = try variable(named: "LANG", in: file)

        try makeWriter(in: dir).deleteVariable(lang, at: file)

        let result = try content(of: file)
        #expect(!result.contains("LANG="))
        #expect(result.contains("export EDITOR=\"vim\""))
        #expect(result.contains("alias ll='ls -l'"))
    }

    // MARK: - Add / managed block

    @Test func addCreatesManagedBlockAndMissingFile() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent(".zshrc")

        try makeWriter(in: dir).addVariables([(name: "API_KEY", rawValue: "secret")], to: file)

        let result = try content(of: file)
        #expect(result == """
        \(ShellConfigWriter.managedBlockBegin)
        export API_KEY="secret"
        \(ShellConfigWriter.managedBlockEnd)

        """)
    }

    @Test func addAppendsToExistingManagedBlock() throws {
        let dir = try makeTempDir()
        let file = try makeFixtureFile(in: dir)
        let writer = makeWriter(in: dir)

        try writer.addVariables([(name: "FIRST", rawValue: "1")], to: file)
        try writer.addVariables([(name: "SECOND", rawValue: "2")], to: file)

        let result = try content(of: file)
        #expect(result.components(separatedBy: ShellConfigWriter.managedBlockBegin).count == 2)
        #expect(result.components(separatedBy: ShellConfigWriter.managedBlockEnd).count == 2)
        #expect(result.contains("export FIRST=\"1\"\nexport SECOND=\"2\"\n"))
        // Original content stays untouched in front of the block.
        #expect(result.hasPrefix(Self.fixture))
    }

    // MARK: - Backups

    @Test func writeCreatesBackupOfPreviousContent() throws {
        let dir = try makeTempDir()
        let file = try makeFixtureFile(in: dir)
        let writer = makeWriter(in: dir)
        let editor = try variable(named: "EDITOR", in: file)

        try writer.updateVariable(editor, newName: "EDITOR", newRawValue: "nano", exported: true, at: file)

        let backups = try FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("Backups"), includingPropertiesForKeys: nil
        )
        #expect(backups.count == 1)
        #expect(try content(of: backups[0]) == Self.fixture)
        #expect(backups[0].lastPathComponent.hasPrefix("zshrc-"))
    }

    @Test func backupRetentionPrunesOldBackups() throws {
        let dir = try makeTempDir()
        let file = try makeFixtureFile(in: dir)
        let writer = makeWriter(in: dir, retention: 2)

        for value in ["v1", "v2", "v3", "v4"] {
            let editor = try variable(named: "EDITOR", in: file)
            try writer.updateVariable(editor, newName: "EDITOR", newRawValue: value, exported: true, at: file)
        }

        let backups = try FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("Backups"), includingPropertiesForKeys: nil
        )
        #expect(backups.count == 2)
    }

    @Test func unchangedContentWritesNothing() throws {
        let dir = try makeTempDir()
        let file = try makeFixtureFile(in: dir)
        let editor = try variable(named: "EDITOR", in: file)

        try makeWriter(in: dir).updateVariable(
            editor, newName: "EDITOR", newRawValue: "vim", exported: true, at: file
        )

        #expect(try content(of: file) == Self.fixture)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Backups").path))
    }

    // MARK: - Symlinks and permissions

    @Test func writingThroughSymlinkKeepsTheSymlink() throws {
        let dir = try makeTempDir()
        let realFile = dir.appendingPathComponent("dotfiles-zshrc")
        try Self.fixture.write(to: realFile, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent(".zshrc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)
        let editor = try variable(named: "EDITOR", in: link)

        try makeWriter(in: dir).updateVariable(
            editor, newName: "EDITOR", newRawValue: "nano", exported: true, at: link
        )

        let linkType = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(linkType == .typeSymbolicLink)
        #expect(try content(of: realFile).contains("export EDITOR=\"nano\""))
    }

    @Test func writePreservesPosixPermissions() throws {
        let dir = try makeTempDir()
        let file = try makeFixtureFile(in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let editor = try variable(named: "EDITOR", in: file)

        try makeWriter(in: dir).updateVariable(
            editor, newName: "EDITOR", newRawValue: "nano", exported: true, at: file
        )

        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    // MARK: - Legacy managed block (pre-rename)

    @Test func addVariablesInsertsIntoLegacyEnvVarBuddyBlock() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent(".zshrc")
        try """
        export EDITOR="vim"

        # >>> EnvVarBuddy >>>
        export OLD_VAR="x"
        # <<< EnvVarBuddy <<<

        """.write(to: url, atomically: true, encoding: .utf8)

        try makeWriter(in: dir).addVariables([(name: "NEW_VAR", rawValue: "y")], to: url)

        let lines = try content(of: url).components(separatedBy: "\n")
        // No second block: the variable joins the existing legacy block.
        #expect(!lines.contains(ShellConfigWriter.managedBlockBegin))
        let newIndex = lines.firstIndex(of: "export NEW_VAR=\"y\"")
        let endIndex = lines.firstIndex(of: "# <<< EnvVarBuddy <<<")
        #expect(newIndex != nil)
        #expect(endIndex != nil)
        if let newIndex, let endIndex { #expect(newIndex < endIndex) }
    }

    @Test func addVariablesCreatesNewBlocksWithCodingBuddyMarker() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent(".zshrc")
        try "export EDITOR=\"vim\"\n".write(to: url, atomically: true, encoding: .utf8)

        try makeWriter(in: dir).addVariables([(name: "NEW_VAR", rawValue: "y")], to: url)

        let text = try content(of: url)
        #expect(text.contains("# >>> CodingBuddy >>>"))
        #expect(text.contains("# <<< CodingBuddy <<<"))
        #expect(!text.contains("EnvVarBuddy"))
    }

    // MARK: - Export style (dotenv files)

    @Test func addVariablesWithoutExportStyleWritesPlainAssignments() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("mcp.env")
        try "# codex env\nEXISTING=1\n".write(to: url, atomically: true, encoding: .utf8)

        try makeWriter(in: dir).addVariables(
            [(name: "NEW_TOKEN", rawValue: "abc")], to: url, exportStyle: .none
        )

        let text = try content(of: url)
        #expect(text.contains("NEW_TOKEN=\"abc\""))
        #expect(!text.contains("export NEW_TOKEN"))
        #expect(text.contains("# codex env"))
    }
}
