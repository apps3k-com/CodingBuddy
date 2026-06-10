//
//  EnvFileCodecTests.swift
//  CodingBuddyTests
//

import Testing
@testable import CodingBuddy

@MainActor
struct EnvFileCodecTests {

    @Test func decodeSkipsCommentsBlanksAndComplexLines() {
        let content = """
        # comment
        API_KEY=secret
        export QUOTED="hello world"

        DYNAMIC=$(date)
        """
        let entries = EnvFileCodec.decode(content)
        #expect(entries.map(\.name) == ["API_KEY", "QUOTED"])
        #expect(entries.map(\.rawValue) == ["secret", "hello world"])
    }

    @Test func encodeQuotesOnlyWhenNeeded() {
        let variables = ShellConfigParser.variables(
            in: "export PLAIN=simple\nexport SPACED=\"a b\"\nexport LOCKED=$(date)\n",
            file: .zshrc
        )
        let encoded = EnvFileCodec.encode(variables)
        #expect(encoded == "PLAIN=simple\nSPACED=\"a b\"\n")
    }

    @Test func encodeDecodeRoundTrip() {
        let variables = ShellConfigParser.variables(
            in: "export A=\"x y\"\nB=plain\n",
            file: .zshrc
        )
        let entries = EnvFileCodec.decode(EnvFileCodec.encode(variables))
        #expect(entries.map(\.name) == ["A", "B"])
        #expect(entries.map(\.rawValue) == ["x y", "plain"])
    }
}
