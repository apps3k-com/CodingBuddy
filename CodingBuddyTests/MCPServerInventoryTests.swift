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
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
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
        #expect(claudeUser.repositoryName == String(localized: "User"))
        #expect(claudeUser.headerKeys == ["Authorization"])

        let projectStdio = try #require(items.first { $0.name == "project-stdio" })
        #expect(projectStdio.scope == project.path)
        #expect(projectStdio.repositoryName == "Project")
        #expect(projectStdio.envVarNames == ["PROJECT_TOKEN"])

        let localOnly = try #require(items.first { $0.name == "local-only" })
        #expect(localOnly.repositoryName == "Project")

        let cursorLinear = try #require(items.first { $0.name == "cursor-linear" })
        #expect(cursorLinear.tool == .cursor)
        #expect(cursorLinear.repositoryName == String(localized: "User"))
        #expect(cursorLinear.transport == .sse)
        #expect(cursorLinear.envVarNames == ["LINEAR_TOKEN"])
    }

    /// Verifies repository display names use the nearest git root or deterministic workspace fallback.
    @Test func repositoryNamesResolveFromNestedAndNonGitProjectScopes() throws {
        let home = try makeTempDir()
        let root = home.appendingPathComponent("RootRepo", isDirectory: true)
        let nested = root.appendingPathComponent("packages/app", isDirectory: true)
        let nonGit = home.appendingPathComponent("LooseWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nonGit, withIntermediateDirectories: true)
        try #"{"mcpServers":{"nested-local":{"command":"node","args":["server.js"]}}}"#
            .write(to: nested.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"loose-local":{"command":"node","args":["server.js"]}}}"#
            .write(to: nonGit.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try """
        {
          "projects": {
            "\(nested.path)": {},
            "\(nonGit.path)": {}
          }
        }
        """.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let items = MCPServerInventoryScanner(homeDirectory: home).items()

        let nestedItem = try #require(items.first { $0.name == "nested-local" })
        #expect(nestedItem.scope == nested.path)
        #expect(nestedItem.repositoryName == "RootRepo")

        let looseItem = try #require(items.first { $0.name == "loose-local" })
        #expect(looseItem.scope == nonGit.path)
        #expect(looseItem.repositoryName == "LooseWorkspace")
    }

    /// Verifies repository names handle worktree gitdir files and malformed `.git` markers safely.
    @Test func repositoryNamesHandleGitdirFilesAndInvalidMarkers() throws {
        let home = try makeTempDir()
        let outer = home.appendingPathComponent("OuterRepo", isDirectory: true)
        let brokenWorkspace = outer.appendingPathComponent("BrokenWorkspace", isDirectory: true)
        let worktree = home.appendingPathComponent("WorktreeRepo", isDirectory: true)
        let metadata = home
            .appendingPathComponent("GitMetadata", isDirectory: true)
            .appendingPathComponent("worktrees/worktree-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: outer.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brokenWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try "not a gitdir marker\n".write(
            to: brokenWorkspace.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: \(metadata.path)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"mcpServers":{"broken-local":{"command":"node","args":["server.js"]}}}"#
            .write(to: brokenWorkspace.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"worktree-local":{"command":"node","args":["server.js"]}}}"#
            .write(to: worktree.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try """
        {
          "projects": {
            "\(brokenWorkspace.path)": {},
            "\(worktree.path)": {}
          }
        }
        """.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let items = MCPServerInventoryScanner(homeDirectory: home).items()

        let brokenItem = try #require(items.first { $0.name == "broken-local" })
        #expect(brokenItem.scope == brokenWorkspace.path)
        #expect(brokenItem.repositoryName == "BrokenWorkspace")

        let worktreeItem = try #require(items.first { $0.name == "worktree-local" })
        #expect(worktreeItem.scope == worktree.path)
        #expect(worktreeItem.repositoryName == "WorktreeRepo")
    }

    /// Verifies symlinked `.git` markers fall back to the selected workspace name.
    @Test func repositoryNamesIgnoreSymlinkGitMarkers() throws {
        let home = try makeTempDir()
        let outer = home.appendingPathComponent("OuterRepo", isDirectory: true)
        let symlinkWorkspace = outer.appendingPathComponent("SymlinkWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: outer.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: symlinkWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkWorkspace.appendingPathComponent(".git"),
            withDestinationURL: outer.appendingPathComponent(".git")
        )
        try #"{"mcpServers":{"symlink-local":{"command":"node","args":["server.js"]}}}"#
            .write(to: symlinkWorkspace.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try """
        {
          "projects": {
            "\(symlinkWorkspace.path)": {}
          }
        }
        """.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let item = try #require(MCPServerInventoryScanner(homeDirectory: home).items().first)

        #expect(item.scope == symlinkWorkspace.path)
        #expect(item.repositoryName == "SymlinkWorkspace")
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
                "https://secret-token.example/mcp?token=next-secret",
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
        #expect(!item.summary.contains("secret-token.example"))
        #expect(!item.summary.contains("password"))
        #expect(!item.summary.contains("query-secret"))
    }

    /// Verifies command summaries hide sensitive header values while retaining useful safe headers.
    @Test func summariesRedactSensitiveHeaderArguments() throws {
        let home = try makeTempDir()
        let cursor = home.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        try """
        {
          "mcpServers": {
            "header-runner": {
              "command": "runner",
              "args": [
                "-H",
                "Authorization: Bearer auth-secret",
                "--header",
                "Proxy-Authorization: Basic proxy-secret",
                "-H",
                "Cookie: session=cookie-secret",
                "--header=Set-Cookie: session=set-cookie-secret",
                "--header=X-API-Key: api-key-secret",
                "--header",
                "X-Service-Token: token-secret",
                "-H",
                "X-Client-Secret: client-secret",
                "-HAuthorization: Bearer ghp_abcd1234",
                "-H=X-API-Key: opaque-5678",
                "--header=Accept: application/json",
                "--header=Accept: application/json, text/event-stream",
                "--header=Accept: application/ghp_abcd1234",
                "--header=Accept: application/*ghp_abcd1234",
                "--header=Content-Type: application/json",
                "--header=X-Debug: Bearer custom-header-secret",
                "--header=Referer: https://user:password@example.com/path?token=referer-secret",
                "--header",
                "Link: <https://user:password@example.org/callback?token=link-secret>; rel=next",
                "-HX-Request-ID: request-attached-123",
                "-H",
                "X-Request-ID: request-123",
                "-HOrigin: https://user:password@example.net/path?token=origin-secret",
                "-H",
                "Authorization Bearer malformed-secret",
                "--header",
                "invalid header ghp_malformed_name_secret: harmless"
              ]
            }
          }
        }
        """.write(to: cursor.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)

        let summary = try #require(MCPServerInventoryScanner(homeDirectory: home).items().first).summary

        #expect(summary.contains("-H Authorization: ••••••••"))
        #expect(summary.contains("--header Proxy-Authorization: ••••••••"))
        #expect(summary.contains("-H Cookie: ••••••••"))
        #expect(summary.contains("--header=Set-Cookie: ••••••••"))
        #expect(summary.contains("--header=X-API-Key: ••••••••"))
        #expect(summary.contains("--header X-Service-Token: ••••••••"))
        #expect(summary.contains("-H X-Client-Secret: ••••••••"))
        #expect(summary.contains("-HAuthorization: ••••••••"))
        #expect(summary.contains("-H=X-API-Key: ••••••••"))
        #expect(summary.contains("--header=Accept: application/json"))
        #expect(summary.contains("--header=Accept: application/json, text/event-stream"))
        #expect(!summary.contains("--header=Accept: application/ghp_abcd1234"))
        #expect(!summary.contains("--header=Accept: application/*ghp_abcd1234"))
        #expect(summary.components(separatedBy: "--header=Accept: ••••••••").count == 3)
        #expect(summary.contains("--header=Content-Type: application/json"))
        #expect(summary.contains("--header=X-Debug: ••••••••"))
        #expect(summary.contains("--header=Referer: ••••••••"))
        #expect(summary.contains("--header Link: ••••••••"))
        #expect(summary.contains("-HX-Request-ID: ••••••••"))
        #expect(summary.contains("-H X-Request-ID: ••••••••"))
        #expect(summary.contains("-HOrigin: ••••••••"))
        #expect(summary.contains("-H ••••••••"))
        #expect(summary.contains("--header ••••••••"))
        #expect(!summary.contains("auth-secret"))
        #expect(!summary.contains("proxy-secret"))
        #expect(!summary.contains("cookie-secret"))
        #expect(!summary.contains("set-cookie-secret"))
        #expect(!summary.contains("api-key-secret"))
        #expect(!summary.contains("custom-header-secret"))
        #expect(!summary.contains("token-secret"))
        #expect(!summary.contains("client-secret"))
        #expect(!summary.contains("ghp_abcd1234"))
        #expect(!summary.contains("opaque-5678"))
        #expect(!summary.contains("referer-secret"))
        #expect(!summary.contains("link-secret"))
        #expect(!summary.contains("origin-secret"))
        #expect(!summary.contains("malformed-secret"))
        #expect(!summary.contains("ghp_malformed_name_secret"))
        #expect(!summary.contains("user:password"))
    }

    /// Verifies same-named Claude project definitions remain distinct across both source files.
    @Test func claudeProjectDefinitionsPreserveSameNamedOccurrences() throws {
        let home = try makeTempDir()
        let project = home.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"mcpServers":{"shared":{"command":"local-runner","args":["local.js"]}}}"#
            .write(to: project.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try """
        {
          "projects": {
            "\(project.path)": {
              "mcpServers": {
                "shared": {
                  "command": "claude-runner",
                  "args": ["claude.js"]
                }
              }
            }
          }
        }
        """.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let occurrences = MCPServerInventoryScanner(homeDirectory: home).items()
            .filter { $0.tool == .claudeCode && $0.scope == project.path && $0.name == "shared" }

        #expect(occurrences.count == 2)
        #expect(Set(occurrences.map(\.sourcePath)) == Set([
            home.appendingPathComponent(".claude.json").path,
            project.appendingPathComponent(".mcp.json").path,
        ]))
        #expect(Set(occurrences.map(\.summary)) == Set(["claude-runner claude.js", "local-runner local.js"]))
        #expect(Set(occurrences.map(\.id)).count == 2)
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
            scope: "/tmp/project-scope",
            repositoryName: "apps3k-repo",
            sourcePath: "/tmp/project-scope/.codex/config.toml",
            transport: .http,
            summary: "https://example.com/mcp",
            envVarNames: ["APPS3K_TOKEN"],
            missingEnvVarNames: ["APPS3K_TOKEN"],
            headerKeys: []
        )

        #expect(item.matches(searchText: "apps3k"))
        #expect(item.matches(searchText: "codex"))
        #expect(item.matches(searchText: "apps3k-repo"))
        #expect(item.matches(searchText: "project-scope"))
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
