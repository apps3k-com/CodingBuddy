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

    @Test func diagnosticsRejectCanonicalDuplicateKeysWithoutOverwritingFirstValue() {
        let result = TOMLReader.parseWithDiagnostics("""
        key = "first"
        "key" = "second"
        """)

        #expect(!result.isComplete)
        #expect(result.table.string(at: ["key"]) == "first")
    }

    @Test func diagnosticsRejectCanonicalDuplicateTablesWithTrailingComments() {
        let result = TOMLReader.parseWithDiagnostics("""
        [mcp_servers.review] # first declaration
        command = "review"

        [mcp_servers."review"] # duplicate canonical path
        enabled = false
        """)

        #expect(!result.isComplete)
        #expect(result.table.string(at: ["mcp_servers", "review", "command"]) == "review")
        #expect(result.table.value(at: ["mcp_servers", "review", "enabled"]) == nil)
    }

    /// Rejected headers suppress their body without preventing a later valid table from parsing.
    @Test func diagnosticsSkipRejectedTableBodyUntilNextValidHeader() {
        let result = TOMLReader.parseWithDiagnostics("""
        [mcp_servers.review]
        command = "review"

        [mcp_servers.review]
        leaked = "must-not-merge"

        [mcp_servers.context]
        command = "context"
        """)

        #expect(!result.isComplete)
        #expect(result.table.value(at: ["mcp_servers", "review", "leaked"]) == nil)
        #expect(result.table.string(at: ["mcp_servers", "context", "command"]) == "context")
    }

    @Test func diagnosticsRejectValueThenTablePathCollision() {
        let result = TOMLReader.parseWithDiagnostics("""
        mcp_servers.review = { command = "first" }

        [mcp_servers.review]
        command = "second"
        """)

        #expect(!result.isComplete)
        #expect(result.table.string(at: ["mcp_servers", "review", "command"]) == "first")
    }

    @Test func diagnosticsRejectTableThenValuePathCollision() {
        let result = TOMLReader.parseWithDiagnostics("""
        [mcp_servers.review]
        command = "first"

        [mcp_servers]
        review = { command = "second" }
        """)

        #expect(!result.isComplete)
        #expect(result.table.string(at: ["mcp_servers", "review", "command"]) == "first")
    }

    @Test func diagnosticsRejectDottedKeyParentReopenedAsTable() {
        let result = TOMLReader.parseWithDiagnostics("""
        mcp_servers.review.command = "first"

        [mcp_servers.review]
        enabled = true
        """)

        #expect(!result.isComplete)
        #expect(result.table.string(at: ["mcp_servers", "review", "command"]) == "first")
    }

    @Test func deeperHeaderMayDeclareItsImplicitParentLater() {
        let result = TOMLReader.parseWithDiagnostics("""
        [mcp_servers.review.tools.inspect]
        enabled = true

        [mcp_servers.review]
        command = "review"
        """)

        #expect(result.isComplete)
        #expect(result.table.string(at: ["mcp_servers", "review", "command"]) == "review")
        #expect(result.table.bool(at: ["mcp_servers", "review", "tools", "inspect", "enabled"]) == true)
    }

    @Test func dottedTraversalClosesAnImplicitHeaderParent() {
        let result = TOMLReader.parseWithDiagnostics("""
        [a.b.c]
        x = 1

        [a]
        b.d = 2

        [a.b]
        e = 3
        """)

        #expect(!result.isComplete)
        #expect(result.table.int(at: ["a", "b", "c", "x"]) == 1)
        #expect(result.table.int(at: ["a", "b", "d"]) == 2)
    }

    @Test func diagnosticsRejectEmptyArrayAndInlineTableMembers() {
        let arrayResult = TOMLReader.parseWithDiagnostics("values = [1,,2]")
        let tableResult = TOMLReader.parseWithDiagnostics("values = { a = 1,, b = 2 }")

        #expect(!arrayResult.isComplete)
        #expect(arrayResult.table.value(at: ["values"]) == nil)
        #expect(!tableResult.isComplete)
        #expect(tableResult.table.value(at: ["values"]) == nil)
    }

    @Test func diagnosticsRejectDuplicateCanonicalInlineTableKeys() {
        let result = TOMLReader.parseWithDiagnostics("values = { key = 1, \"key\" = 2 }")

        #expect(!result.isComplete)
        #expect(result.table.value(at: ["values"]) == nil)
    }

    @Test func emptyContainersAndTrailingArrayCommaRemainValid() {
        let result = TOMLReader.parseWithDiagnostics("""
        empty_array = []
        empty_table = {}
        values = [1, 2,]
        """)

        #expect(result.isComplete)
        #expect(result.table.value(at: ["empty_array"]) == .array([]))
        #expect(result.table.value(at: ["empty_table"]) == .table([:]))
        #expect(result.table.value(at: ["values"]) == .array([.int(1), .int(2)]))
    }

    /// Rejects trailing tokens after strings instead of accepting a misleading partial value.
    @Test func diagnosticsRejectTrailingStringTokens() {
        let result = TOMLReader.parseWithDiagnostics("""
        [mcp_servers.review]
        command = "review"
        enabled = "false" trailing
        """)

        #expect(!result.isComplete)
        #expect(result.table.string(at: ["mcp_servers", "review", "command"]) == "review")
        #expect(result.table.value(at: ["mcp_servers", "review", "enabled"]) == nil)
    }

    /// Keeps bounded adversarial multiline arrays linear enough for an interactive scan.
    @Test func largeMultilineArrayParsesWithinInteractiveBudget() {
        let values = Array(repeating: "  \"argument\",", count: 12_000).joined(separator: "\n")
        let input = "args = [\n\(values)\n]\n"
        let clock = ContinuousClock()
        let start = clock.now

        let result = TOMLReader.parseWithDiagnostics(input)
        let elapsed = clock.now - start

        #expect(result.isComplete)
        #expect(result.table.stringArray(at: ["args"])?.count == 12_000)
        #expect(elapsed < .seconds(5))
    }
}
