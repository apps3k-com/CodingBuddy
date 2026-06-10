//
//  TOMLReaderTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct TOMLReaderTests {

    @Test func parsesBasicKeyValuesAndTables() {
        let table = TOMLReader.parse("""
        model = "gpt-5"
        enabled = true
        timeout = 20
        ratio = 1.5

        [mcp_servers.figma]
        url = "https://mcp.figma.com/mcp"
        bearer_token_env_var = "FIGMA_TOKEN"
        """)

        #expect(table.string(at: ["model"]) == "gpt-5")
        #expect(table.bool(at: ["enabled"]) == true)
        #expect(table.int(at: ["timeout"]) == 20)
        #expect(table.string(at: ["mcp_servers", "figma", "url"]) == "https://mcp.figma.com/mcp")
        #expect(table.string(at: ["mcp_servers", "figma", "bearer_token_env_var"]) == "FIGMA_TOKEN")
    }

    @Test func parsesQuotedAndDottedTableHeaders() {
        let table = TOMLReader.parse("""
        [mcp_servers."shopify.dev"]
        url = "https://shopify.dev/mcp"
        """)
        #expect(table.string(at: ["mcp_servers", "shopify.dev", "url"]) == "https://shopify.dev/mcp")
    }

    @Test func parsesMultilineArraysAndInlineTables() {
        let table = TOMLReader.parse("""
        [mcp_servers.context7]
        command = "npx"
        args = [
          "-y",
          "@upstash/context7-mcp",
        ]
        env = { API_KEY = "literal", SECOND = "x" }
        env_vars = ["LOCAL_TOKEN"]
        """)
        #expect(table.stringArray(at: ["mcp_servers", "context7", "args"]) == ["-y", "@upstash/context7-mcp"])
        #expect(table.string(at: ["mcp_servers", "context7", "env", "API_KEY"]) == "literal")
        #expect(table.stringArray(at: ["mcp_servers", "context7", "env_vars"]) == ["LOCAL_TOKEN"])
    }

    @Test func parsesStringEscapesAndLiteralStrings() {
        let table = TOMLReader.parse(#"""
        escaped = "a \"quote\" and \\ backslash"
        literal = 'C:\path\no-escapes'
        """#)
        #expect(table.string(at: ["escaped"]) == #"a "quote" and \ backslash"#)
        #expect(table.string(at: ["literal"]) == #"C:\path\no-escapes"#)
    }

    @Test func skipsUnsupportedConstructsLeniently() {
        let table = TOMLReader.parse("""
        before = "kept"

        [[array_of_tables]]
        inside = "skipped"

        [normal]
        after = "kept"
        when = 2026-06-10T00:00:00Z
        """)
        #expect(table.string(at: ["before"]) == "kept")
        #expect(table.string(at: ["normal", "after"]) == "kept")
        #expect(table.value(at: ["array_of_tables"]) == nil)
        #expect(table.value(at: ["normal", "when"]) == nil)
    }

    @Test func commentsAndBlankLinesAreIgnored() {
        let table = TOMLReader.parse("""
        # full-line comment
        key = "value"  # trailing comment

        other = 1
        """)
        #expect(table.string(at: ["key"]) == "value")
        #expect(table.int(at: ["other"]) == 1)
    }
}
