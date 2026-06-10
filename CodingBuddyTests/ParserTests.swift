//
//  ParserTests.swift
//  CodingBuddyTests
//

import Testing
@testable import CodingBuddy

@MainActor
struct ParserTests {

    // MARK: - Simple assignments

    @Test func exportWithDoubleQuotes() {
        let assignment = ShellConfigParser.parseLine("export EDITOR=\"vim\"")
        #expect(assignment?.name == "EDITOR")
        #expect(assignment?.rawValue == "vim")
        #expect(assignment?.quoting == .double)
        #expect(assignment?.hasExport == true)
        #expect(assignment?.isEditable == true)
    }

    @Test func assignmentWithoutExport() {
        let assignment = ShellConfigParser.parseLine("LANG=de_CH.UTF-8")
        #expect(assignment?.name == "LANG")
        #expect(assignment?.rawValue == "de_CH.UTF-8")
        #expect(assignment?.quoting == ValueQuoting.none)
        #expect(assignment?.hasExport == false)
        #expect(assignment?.isEditable == true)
    }

    @Test func singleQuotedValue() {
        let assignment = ShellConfigParser.parseLine("export GREETING='hello world'")
        #expect(assignment?.rawValue == "hello world")
        #expect(assignment?.quoting == .single)
        #expect(assignment?.isEditable == true)
    }

    @Test func emptyValues() {
        #expect(ShellConfigParser.parseLine("FOO=")?.rawValue == "")
        #expect(ShellConfigParser.parseLine("FOO=")?.isEditable == true)
        #expect(ShellConfigParser.parseLine("FOO=\"\"")?.rawValue == "")
        #expect(ShellConfigParser.parseLine("FOO=\"\"")?.quoting == .double)
    }

    @Test func variableReferencesStayUnexpanded() {
        let assignment = ShellConfigParser.parseLine("export PATH=\"$PATH:/usr/local/bin\"")
        #expect(assignment?.rawValue == "$PATH:/usr/local/bin")
        #expect(assignment?.isEditable == true)
    }

    @Test func escapedDoubleQuoteInsideValue() {
        let assignment = ShellConfigParser.parseLine(#"export MSG="say \"hi\"""#)
        #expect(assignment?.rawValue == #"say \"hi\""#)
        #expect(assignment?.isEditable == true)
    }

    // MARK: - Round-trip fidelity

    @Test(arguments: [
        "export EDITOR=\"vim\"",
        "  export   SPACED=\"x\"  ",
        "LANG=de_CH.UTF-8",
        "export PATH=\"$PATH:/opt/bin\" # added by installer",
        "FOO='a b c'",
        "EMPTY=",
    ])
    func editableLinesRenderByteForByte(line: String) {
        let assignment = ShellConfigParser.parseLine(line)
        #expect(assignment != nil)
        #expect(assignment?.rendered == line)
    }

    // MARK: - Non-assignments are ignored

    @Test(arguments: [
        "# export EDITOR=vim",
        "alias ll='ls -l'",
        "if [ -f ~/.fzf.zsh ]; then",
        "source ~/.profile",
        "",
        "eval \"$(starship init zsh)\"",
        "1INVALID=x",
    ])
    func nonAssignmentsReturnNil(line: String) {
        #expect(ShellConfigParser.parseLine(line) == nil)
    }

    // MARK: - Unsafe lines are read-only

    @Test(arguments: [
        "export TODAY=$(date +%F)",
        "export TODAY=`date`",
        "export NESTED=\"$(brew --prefix)/bin\"",
        "export A=1 B=2",
        "FOO=1 ./run.sh",
        "BROKEN=\"unclosed",
        "BROKEN='unclosed",
        "GLOB=*.txt",
        "CHAIN=1;echo hi",
        "CONCAT=ab\"cd\"",
    ])
    func unsafeLinesAreReadOnly(line: String) {
        let assignment = ShellConfigParser.parseLine(line)
        #expect(assignment != nil)
        #expect(assignment?.isEditable == false)
    }

    @Test func commentWithoutSpaceAfterQuoteIsReadOnly() {
        // `#` right after the closing quote is not a comment in zsh.
        let assignment = ShellConfigParser.parseLine("FOO=\"a\"# not a comment")
        #expect(assignment?.isEditable == false)
    }

    // MARK: - Whole-file parsing

    @Test func parsesFileAndKeepsLineIndices() {
        let content = """
        # my zshrc
        export EDITOR="vim"

        alias ll='ls -l'
        LANG=de_CH.UTF-8
        """
        let variables = ShellConfigParser.variables(in: content, file: .zshrc)
        #expect(variables.count == 2)
        #expect(variables[0].name == "EDITOR")
        #expect(variables[0].lineIndex == 1)
        #expect(variables[1].name == "LANG")
        #expect(variables[1].lineIndex == 4)
        #expect(variables[1].file == .zshrc)
    }
}
