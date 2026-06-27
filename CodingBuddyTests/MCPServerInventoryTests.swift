//
//  MCPServerInventoryTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
@Suite(.serialized)
struct MCPServerInventoryTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPServerInventoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func waitForItems(in store: MCPServerInventoryStore) async throws -> [MCPServerInventoryItem] {
        for _ in 0..<100 {
            if !store.items.isEmpty {
                return store.items
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return store.items
    }

    @Test func loadsSupportedToolsAndFlagsMissingCodexEnv() throws {
        let home = try makeTempDir()
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try "LOCAL_TOKEN=present\n".write(
            to: codex.appendingPathComponent("mcp.env"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [mcp_servers.apps3k]
        url = "https://mcp-auth.apps3k.com/mcp"
        bearer_token_env_var = "APPS3K_TOKEN"

        [mcp_servers.context7]
        command = "npx"
        args = ["-y", "@upstash/context7-mcp"]
        env_vars = ["LOCAL_TOKEN"]
        """.write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let project = home.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"mcpServers":{"local-only":{"command":"swift","args":["run"],"env":{"LOCAL_PROJECT_TOKEN":"x"}}}}"#
            .write(to: project.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try """
        {
          "mcpServers": {
            "claude-user": {
              "type": "http",
              "url": "https://claude.example/mcp",
              "headers": { "Authorization": "Bearer token" }
            }
          },
          "projects": {
            "\(project.path)": {
              "mcpServers": {
                "project-stdio": {
                  "command": "node",
                  "args": ["server.js"],
                  "env": { "PROJECT_TOKEN": "x" }
                }
              }
            }
          }
        }
        """.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let cursor = home.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        try """
        {
          "mcpServers": {
            "cursor-linear": {
              "type": "sse",
              "url": "https://mcp.linear.app/sse",
              "env": { "LINEAR_TOKEN": "x" }
            }
          }
        }
        """.write(to: cursor.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)

        let items = MCPServerInventoryScanner(homeDirectory: home).items()

        #expect(items.map(\.name).sorted() == [
            "apps3k",
            "claude-user",
            "context7",
            "cursor-linear",
            "local-only",
            "project-stdio",
        ])

        let apps3k = try #require(items.first { $0.name == "apps3k" })
        #expect(apps3k.tool == .codex)
        #expect(apps3k.transport == .http)
        #expect(apps3k.envVarNames == ["APPS3K_TOKEN"])
        #expect(apps3k.missingEnvVarNames == ["APPS3K_TOKEN"])

        let context7 = try #require(items.first { $0.name == "context7" })
        #expect(context7.transport == .stdio)
        #expect(context7.envVarNames == ["LOCAL_TOKEN"])
        #expect(context7.missingEnvVarNames.isEmpty)

        let claudeUser = try #require(items.first { $0.name == "claude-user" })
        #expect(claudeUser.tool == .claudeCode)
        #expect(claudeUser.scope == String(localized: "User"))
        #expect(claudeUser.headerKeys == ["Authorization"])

        let projectStdio = try #require(items.first { $0.name == "project-stdio" })
        #expect(projectStdio.scope == project.path)
        #expect(projectStdio.envVarNames == ["PROJECT_TOKEN"])

        let cursorLinear = try #require(items.first { $0.name == "cursor-linear" })
        #expect(cursorLinear.tool == .cursor)
        #expect(cursorLinear.transport == .sse)
        #expect(cursorLinear.envVarNames == ["LINEAR_TOKEN"])
    }

    @Test func summariesRedactSecretBearingURLsAndArguments() throws {
        let home = try makeTempDir()
        let cursor = home.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        try """
        {
          "mcpServers": {
            "secret-runner": {
              "command": "npx",
              "args": [
                "--api-key=secret-value",
                "--token",
                "next-secret",
                "https://user:password@example.com/mcp?token=query-secret#fragment",
                "--endpoint=https://user:password@api.example/mcp?token=query-secret"
              ]
            }
          }
        }
        """.write(to: cursor.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)

        let item = try #require(MCPServerInventoryScanner(homeDirectory: home).items().first)

        #expect(item.summary.contains("--api-key=••••••••"))
        #expect(item.summary.contains("--token ••••••••"))
        #expect(item.summary.contains("https://example.com/mcp"))
        #expect(item.summary.contains("--endpoint=https://api.example/mcp"))
        #expect(!item.summary.contains("secret-value"))
        #expect(!item.summary.contains("next-secret"))
        #expect(!item.summary.contains("password"))
        #expect(!item.summary.contains("query-secret"))
    }

    @Test func malformedURLSummariesFailClosedWithoutLeakingSecrets() throws {
        let home = try makeTempDir()
        let cursor = home.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        try """
        {
          "mcpServers": {
            "invalid-url": {
              "url": "https://user:password@exa mple.com/mcp?token=query-secret#fragment"
            },
            "invalid-arg": {
              "command": "node",
              "args": [
                "--endpoint=https://user:password@exa mple.com/mcp?token=query-secret"
              ]
            }
          }
        }
        """.write(to: cursor.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)

        let summaries = MCPServerInventoryScanner(homeDirectory: home).items().map(\.summary).joined(separator: "\n")

        #expect(summaries.contains(String(localized: "Invalid URL")))
        #expect(!summaries.contains("user:password"))
        #expect(!summaries.contains("password"))
        #expect(!summaries.contains("query-secret"))
        #expect(!summaries.contains("fragment"))
    }

    @Test func searchMatchesServerToolScopeAndEnvVar() {
        let item = MCPServerInventoryItem(
            tool: .codex,
            name: "apps3k",
            scope: "/tmp/project",
            sourcePath: "/tmp/project/.codex/config.toml",
            transport: .http,
            summary: "https://example.com/mcp",
            envVarNames: ["APPS3K_TOKEN"],
            missingEnvVarNames: ["APPS3K_TOKEN"],
            headerKeys: []
        )

        #expect(item.matches(searchText: "apps3k"))
        #expect(item.matches(searchText: "codex"))
        #expect(item.matches(searchText: "project"))
        #expect(item.matches(searchText: "APPS3K_TOKEN"))
        #expect(!item.matches(searchText: "cursor"))
    }

    @Test func storeDoesNotScanUntilReload() async throws {
        let home = try makeTempDir()
        let cursor = home.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        try #"{"mcpServers":{"linear":{"url":"https://mcp.linear.app/mcp"}}}"#
            .write(to: cursor.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        let store = MCPServerInventoryStore(homeDirectory: home)

        #expect(store.items.isEmpty)

        store.reload()
        let items = try await waitForItems(in: store)

        #expect(items.contains { $0.name == "linear" && $0.tool == .cursor })
    }
}
