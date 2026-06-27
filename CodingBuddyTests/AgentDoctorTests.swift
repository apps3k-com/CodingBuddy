//
//  AgentDoctorTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
@Suite(.serialized)
struct AgentDoctorTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDoctorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func reportsMissingToolDirectories() throws {
        let home = try makeTempDir()

        let diagnostics = AgentDoctorScanner(homeDirectory: home).diagnostics()

        #expect(diagnostics.contains(.missingDirectory(tool: .codex, path: home.appendingPathComponent(".codex").path)))
        #expect(diagnostics.contains(.missingDirectory(tool: .claudeCode, path: home.appendingPathComponent(".claude").path)))
        #expect(diagnostics.contains(.missingDirectory(tool: .cursor, path: home.appendingPathComponent(".cursor").path)))
        #expect(diagnostics.contains(.missingDirectory(tool: .craftAgents, path: home.appendingPathComponent(".craft-agent").path)))
        #expect(diagnostics.contains(.missingDirectory(tool: .mcpAuth, path: home.appendingPathComponent(".mcp-auth").path)))
    }

    @Test func reportsCodexMissingReferencedEnvVarAndUnsafePermissions() throws {
        let home = try makeTempDir()
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)

        let mcpEnv = codex.appendingPathComponent("mcp.env")
        try "OTHER_TOKEN=abc\n".write(to: mcpEnv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: mcpEnv.path)

        try """
        [mcp_servers.apps3k]
        url = "https://example.com/mcp"
        bearer_token_env_var = "MISSING_TOKEN"
        """.write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let diagnostics = AgentDoctorScanner(homeDirectory: home).diagnostics()

        #expect(diagnostics.contains(.missingReferencedEnvVar(
            tool: .codex,
            name: "MISSING_TOKEN",
            source: codex.appendingPathComponent("config.toml").path
        )))
        #expect(diagnostics.contains(.unsafePermissions(
            tool: .codex,
            path: mcpEnv.path,
            actualMode: "644",
            expectedMode: "600"
        )))
    }

    @Test func reportsInvalidJSONAndMCPAuthStatus() throws {
        let home = try makeTempDir()
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let settings = claude.appendingPathComponent("settings.json")
        try "{not-json".write(to: settings, atomically: true, encoding: .utf8)

        let mcpAuth = home.appendingPathComponent(".mcp-auth/mcp-remote-1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: mcpAuth, withIntermediateDirectories: true)
        let incompleteHash = String(repeating: "ab", count: 16)
        let expiredHash = String(repeating: "cd", count: 16)
        try #"{"client_id":"abc"}"#.write(
            to: mcpAuth.appendingPathComponent("\(incompleteHash)_client_info.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"access_token":"x","expires_in":-60}"#.write(
            to: mcpAuth.appendingPathComponent("\(expiredHash)_tokens.json"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = AgentDoctorScanner(homeDirectory: home).diagnostics()

        #expect(diagnostics.contains(.invalidConfigFile(tool: .claudeCode, path: settings.path)))
        #expect(diagnostics.contains {
            $0.code == .incompleteCredential && $0.tool == .mcpAuth && $0.subject == String(incompleteHash.prefix(12))
        })
        #expect(diagnostics.contains {
            $0.code == .expiredCredential && $0.tool == .mcpAuth && $0.subject == String(expiredHash.prefix(12))
        })
    }

    @Test func storeDoesNotScanUntilReload() throws {
        let home = try makeTempDir()
        let store = AgentDoctorStore(homeDirectory: home)

        #expect(store.diagnostics.isEmpty)

        store.reload()

        #expect(store.diagnostics.contains(.missingDirectory(
            tool: .codex,
            path: home.appendingPathComponent(".codex").path
        )))
    }

    @Test func mcpAuthDiagnosticsUseHashSubjectWhenURLContainsCredentials() throws {
        let home = try makeTempDir()
        let secretURL = "https://token-value@example.com/mcp"
        let hash = MCPAuthScanner.md5Hex(secretURL)
        try #"{"mcpServers":{"secret":{"url":"\#(secretURL)"}}}"#.write(
            to: home.appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8
        )

        let mcpAuth = home.appendingPathComponent(".mcp-auth/mcp-remote-1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: mcpAuth, withIntermediateDirectories: true)
        try #"{"access_token":"raw-token-value","expires_in":-60}"#.write(
            to: mcpAuth.appendingPathComponent("\(hash)_tokens.json"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostic = try #require(AgentDoctorScanner(homeDirectory: home).diagnostics().first {
            $0.code == .expiredCredential && $0.tool == .mcpAuth
        })

        #expect(diagnostic.subject == String(hash.prefix(12)))
        #expect(!diagnostic.subject.orEmpty.contains("token-value"))
    }

    @Test func reportsUnsafeMCPAuthCredentialFilePermissions() throws {
        let home = try makeTempDir()
        let mcpAuth = home.appendingPathComponent(".mcp-auth/mcp-remote-1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: mcpAuth, withIntermediateDirectories: true)
        let hash = String(repeating: "12", count: 16)
        let tokens = mcpAuth.appendingPathComponent("\(hash)_tokens.json")
        try #"{"access_token":"raw-token-value","expires_in":3600}"#.write(
            to: tokens,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokens.path)

        let diagnostics = AgentDoctorScanner(homeDirectory: home).diagnostics()
        let expectedSource = tokens.resolvingSymlinksInPath().path

        #expect(diagnostics.contains {
            $0.code == .unsafePermissions
                && $0.tool == .mcpAuth
                && URL(fileURLWithPath: $0.source).resolvingSymlinksInPath().path == expectedSource
        })
    }

    @Test func reportsUnsafeMCPAuthClientInfoPermissions() throws {
        let home = try makeTempDir()
        let mcpAuth = home.appendingPathComponent(".mcp-auth/mcp-remote-1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: mcpAuth, withIntermediateDirectories: true)
        let hash = String(repeating: "34", count: 16)
        let clientInfo = mcpAuth.appendingPathComponent("\(hash)_client_info.json")
        try #"{"client_id":"public","client_secret":"raw-secret-value"}"#.write(
            to: clientInfo,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: clientInfo.path)

        let diagnostics = AgentDoctorScanner(homeDirectory: home).diagnostics()
        let expectedSource = clientInfo.resolvingSymlinksInPath().path

        #expect(diagnostics.contains {
            $0.code == .unsafePermissions
                && $0.tool == .mcpAuth
                && URL(fileURLWithPath: $0.source).resolvingSymlinksInPath().path == expectedSource
        })
    }

    @Test func restrictiveCredentialPermissionsAreNotReportedAsTooBroad() throws {
        let home = try makeTempDir()
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let mcpEnv = codex.appendingPathComponent("mcp.env")
        try "TOKEN=secret\n".write(to: mcpEnv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: mcpEnv.path)

        let diagnostics = AgentDoctorScanner(homeDirectory: home).diagnostics()

        #expect(!diagnostics.contains {
            $0.code == .unsafePermissions && $0.source == mcpEnv.path
        })
    }

    @Test func diagnosticsNeverIncludeSecretValues() throws {
        let home = try makeTempDir()
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)

        try "SECRET_TOKEN=super-secret-value\n".write(
            to: codex.appendingPathComponent("mcp.env"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [mcp_servers.apps3k]
        url = "https://example.com/mcp"
        bearer_token_env_var = "MISSING_TOKEN"
        """.write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let mcpAuth = home.appendingPathComponent(".mcp-auth/mcp-remote-1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: mcpAuth, withIntermediateDirectories: true)
        let hash = String(repeating: "ef", count: 16)
        try #"{"access_token":"raw-token-value","refresh_token":"raw-refresh-value","expires_in":-60}"#.write(
            to: mcpAuth.appendingPathComponent("\(hash)_tokens.json"),
            atomically: true,
            encoding: .utf8
        )

        let rendered = AgentDoctorScanner(homeDirectory: home).diagnostics()
            .map { "\($0.title) \($0.detail) \($0.source) \($0.subject ?? "") \($0.suggestion)" }
            .joined(separator: "\n")

        #expect(!rendered.contains("super-secret-value"))
        #expect(!rendered.contains("raw-token-value"))
        #expect(!rendered.contains("raw-refresh-value"))
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String {
        self ?? ""
    }
}
