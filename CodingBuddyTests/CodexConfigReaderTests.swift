//
//  CodexConfigReaderTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct CodexConfigReaderTests {

    /// Mirrors the real ~/.codex/config.toml structure, including the
    /// `tools` subtable trap.
    private let fixture = """
    model = "gpt-5"

    [mcp_servers.apps3k]
    url = "https://mcp-auth.apps3k.com/mcp/inngest"
    bearer_token_env_var = "APPS3K_MCP_AUTH_TOKEN"
    enabled = true
    startup_timeout_sec = 20

    [mcp_servers.apps3k.tools.run_query]
    approval_mode = "approve"

    [mcp_servers.context7]
    command = "npx"
    args = ["-y", "@upstash/context7-mcp"]
    env = { API_KEY = "inline-secret" }
    env_vars = ["LOCAL_TOKEN"]

    [shell_environment_policy]
    inherit = "all"
    """

    @Test func mapsServersWithoutTreatingToolSubtablesAsServers() {
        let servers = CodexConfigReader.servers(in: fixture)

        #expect(servers.map(\.name).sorted() == ["apps3k", "context7"])

        let apps3k = servers.first { $0.name == "apps3k" }
        #expect(apps3k?.url == "https://mcp-auth.apps3k.com/mcp/inngest")
        #expect(apps3k?.bearerTokenEnvVar == "APPS3K_MCP_AUTH_TOKEN")
        #expect(apps3k?.command == nil)

        let context7 = servers.first { $0.name == "context7" }
        #expect(context7?.command == "npx")
        #expect(context7?.args == ["-y", "@upstash/context7-mcp"])
        #expect(context7?.inlineEnvKeys == ["API_KEY"])
        #expect(context7?.envVarAllowlist == ["LOCAL_TOKEN"])
    }

    @Test func referencedEnvironmentVariableNamesAreCollected() {
        let servers = CodexConfigReader.servers(in: fixture)
        let referenced = Set(servers.flatMap(\.referencedEnvVarNames))
        #expect(referenced == ["APPS3K_MCP_AUTH_TOKEN", "LOCAL_TOKEN"])
    }

    @Test func omittedEnabledAndEnvVarsUseCodexDefaultsWithoutDiagnostics() throws {
        let result = CodexConfigReader.read("""
        [mcp_servers.review]
        command = "review"
        """)
        let serverResult = try #require(result.serverResults.first)

        #expect(result.isComplete)
        #expect(result.serverResults.count == 1)
        #expect(serverResult.isComplete)
        #expect(serverResult.enabledState == true)
        #expect(serverResult.server.envVarAllowlist == [])
    }

    @Test func invalidEnabledTypeProducesUnknownActivation() throws {
        let result = CodexConfigReader.read("""
        [mcp_servers.review]
        command = "review"
        enabled = "false"
        """)
        let serverResult = try #require(result.serverResults.first)

        #expect(!result.isComplete)
        #expect(result.serverResults.count == 1)
        #expect(!serverResult.isComplete)
        #expect(serverResult.enabledState == nil)
    }

    @Test func invalidEnvVarsTypesProduceIncompleteSchemaWithoutPartialValues() throws {
        let mixedArray = CodexConfigReader.read("""
        [mcp_servers.mixed]
        command = "mixed"
        env_vars = ["TOKEN", 42]
        """)
        let scalar = CodexConfigReader.read("""
        [mcp_servers.scalar]
        command = "scalar"
        env_vars = "TOKEN"
        """)
        let mixedServer = try #require(mixedArray.serverResults.first)
        let scalarServer = try #require(scalar.serverResults.first)

        #expect(!mixedArray.isComplete)
        #expect(!mixedServer.isComplete)
        #expect(mixedServer.enabledState == true)
        #expect(mixedServer.server.envVarAllowlist == [])
        #expect(!scalar.isComplete)
        #expect(!scalarServer.isComplete)
        #expect(scalarServer.enabledState == true)
        #expect(scalarServer.server.envVarAllowlist == [])
    }
}
