//
//  CapabilityHygieneTests.swift
//  CodingBuddyTests
//

import Darwin
import Foundation
import Testing
@testable import CodingBuddy

/// Security, completeness, normalization, and analysis coverage for capability hygiene.
@Suite(.serialized)
struct CapabilityHygieneTests {
    /// Creates an isolated temporary home directory.
    private func makeHome() throws -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath = temporaryPath.hasPrefix("/var/") ? "/private\(temporaryPath)" : temporaryPath
        let home = URL(fileURLWithPath: canonicalTemporaryPath, isDirectory: true)
            .appendingPathComponent("CapabilityHygieneTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Writes UTF-8 text after creating parent directories.
    private func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    /// Writes arbitrary fixture bytes after creating parent directories.
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Creates a complete analyzer fixture with an opaque fingerprint.
    private func item(
        kind: CapabilityKind = .skill,
        consumer: CapabilityConsumer = .codex,
        identity: String,
        sourcePath: String,
        scope: String = "user",
        content: String,
        status: CapabilitySourceStatus = .complete
    ) -> CapabilityInventoryItem {
        CapabilityInventoryItem(
            kind: kind,
            consumer: consumer,
            runtimeIdentity: identity,
            sourcePath: sourcePath,
            effectiveScope: scope,
            registrationState: .installed,
            activationState: .enabled,
            sourceStatus: status,
            canonicalFingerprint: CapabilityFingerprint.publicContent(
                schemaVersion: "test-public-v1",
                data: Data(content.utf8)
            )
        )
    }

    /// Verifies authoritative inventory sources cover all kinds without treating cache as active.
    @Test func scansAllKindsExcludesStaleCacheAndNeverExposesSecretValues() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            """
            [mcp_servers."Remote.API+V2"]
            command = "/usr/bin/helper"
            args = ["--token", "literal-mcp-secret", "--mode=active"]
            env = { MCP_TOKEN = "literal-inline-secret" }

            [plugins."review@catalog"]
            enabled = true
            version = "1.2.3"
            token_env = "$PLUGIN_TOKEN"
            """,
            to: home.appendingPathComponent(".codex/config.toml")
        )
        try write(
            """
            ---
            name: Déploy.Review+
            description: token=literal-skill-secret
            allowed-tools: Read, Bash(git:*)
            secrets: SKILL_TOKEN
            ---
            Use ${RUNTIME_TOKEN}.
            """,
            to: home.appendingPathComponent(".agents/skills/deploy/SKILL.md")
        )
        let install = home.appendingPathComponent(".claude/plugins/installed/triage", isDirectory: true)
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        try write(#"{"name":"triage"}"#, to: install.appendingPathComponent("plugin.json"))
        try write(
            """
            {"plugins":{"triage@catalog":[{"scope":"user","installPath":"\(install.path)","version":"2.0.0","permissions":{"network":true},"env":{"CLAUDE_TOKEN":"literal-plugin-secret"}}]}}
            """,
            to: home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        )
        try write("stale", to: home.appendingPathComponent(".codex/plugins/cache/stale/plugin.json"))

        let result = CapabilityHygieneScanner(homeDirectory: home).scan()

        #expect(
            Set(result.items.map(\.kind)) == Set(CapabilityKind.allCases),
            "sources=\(result.sources), notices=\(result.notices)"
        )
        #expect(result.items.contains { $0.runtimeIdentity == "Remote.API+V2" })
        #expect(result.items.contains { $0.runtimeIdentity == "Déploy.Review+" })
        #expect(!result.items.contains { $0.runtimeIdentity == "review@catalog" })
        #expect(result.items.contains { $0.runtimeIdentity == "triage@catalog" })
        #expect(!result.items.contains { $0.sourcePath.contains("/cache/stale/") })

        let mcp = try #require(result.items.first { $0.kind == .mcpServer })
        #expect(mcp.canonicalFingerprint == nil)
        #expect(mcp.sourceStatus == .partial(.behaviorDefinitionUnavailable))
        #expect(mcp.secretReferenceNames == ["MCP_TOKEN"])
        #expect(mcp.summary == MCPServerTransport.stdio.displayName)

        let claudePlugin = try #require(result.items.first { $0.runtimeIdentity == "triage@catalog" })
        #expect(claudePlugin.secretReferenceNames == ["CLAUDE_TOKEN"])
        #expect(!claudePlugin.supportsExactMatching)
        #expect(claudePlugin.sourceStatus == .partial(.unsupportedFormat))

        let exposedFields: [[String]] = result.items.map { item in
            let scalarFields = [
                item.runtimeIdentity,
                item.searchIdentity,
                item.sourcePath,
                item.summary ?? "",
                item.version ?? "",
            ]
            return scalarFields
                + item.permissionNames
                + item.secretReferenceNames
                + item.headerNames
                + item.repositoryUsage
        }
        let exposed = exposedFields.flatMap { $0 }.joined(separator: " ")
        #expect(!exposed.contains("literal-mcp-secret"))
        #expect(!exposed.contains("literal-inline-secret"))
        #expect(!exposed.contains("literal-plugin-secret"))
        #expect(!exposed.contains("literal-skill-secret"))
    }

    /// Verifies raw bytes and executable mode remain behavior-bearing in skill fingerprints.
    @Test func exactSkillFingerprintPreservesRawLineEndingsAndFileMode() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let content = "---\nname: Review.PR+\n---\nDo work.\n"
        try write(content, to: home.appendingPathComponent(".codex/skills/review/SKILL.md"))
        try write(content, to: home.appendingPathComponent(".codex/skills/review-copy/SKILL.md"))
        try write(content.replacingOccurrences(of: "\n", with: "\r\n"), to: home.appendingPathComponent(".agents/skills/review/SKILL.md"))
        let executable = home.appendingPathComponent(".claude/skills/review/SKILL.md")
        try write(content, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let skills = CapabilityHygieneScanner(homeDirectory: home).scan().items.filter { $0.kind == .skill }
        let findings = CapabilityHygieneAnalyzer.findings(in: skills).filter { $0.kind == .exactDuplicate }

        #expect(skills.count == 4)
        #expect(skills.allSatisfy { $0.supportsExactMatching })
        let codex = try #require(skills.first { $0.sourcePath.contains("/review/SKILL.md") && $0.consumer == .codex })
        let codexCopy = try #require(skills.first { $0.sourcePath.contains("/review-copy/SKILL.md") })
        let shared = try #require(skills.first { $0.consumer == .sharedAgents })
        let claude = try #require(skills.first { $0.consumer == .claudeCode })
        #expect(codex.canonicalFingerprint == codexCopy.canonicalFingerprint)
        #expect(codex.canonicalFingerprint != shared.canonicalFingerprint)
        #expect(shared.canonicalFingerprint != claude.canonicalFingerprint)
        #expect(findings.count == 1)
        #expect(findings[0].itemIDs.count == 2)
    }

    /// Verifies runtime identity is NFC-exact while search identity remains deliberately lossy.
    @Test func runtimeIdentityPreservesCaseAndPunctuationAndExactDuplicateUsesIt() {
        let decomposed = "De\u{301}ploy.PR+"
        let normalized = item(identity: decomposed, sourcePath: "/a", content: "same")
        let same = item(identity: "Déploy.PR+", sourcePath: "/b", content: "same")
        let differentCase = item(identity: "DÉPLOY.PR+", sourcePath: "/c", content: "same")

        #expect(normalized.runtimeIdentity == "Déploy.PR+")
        #expect(normalized.searchIdentity == differentCase.searchIdentity)
        let duplicates = CapabilityHygieneAnalyzer.findings(in: [normalized, same, differentCase])
            .filter { $0.kind == .exactDuplicate }
        #expect(duplicates.count == 1)
        #expect(duplicates[0].itemIDs.count == 2)
    }

    /// Verifies incomplete fingerprints cannot create exact duplicates.
    @Test func exactDuplicateRequiresNonNilCompleteFingerprint() {
        let first = item(identity: "review", sourcePath: "/a", content: "same", status: .partial(.behaviorDefinitionUnavailable))
        let second = item(identity: "review", sourcePath: "/b", content: "same", status: .unsupported(.behaviorDefinitionUnavailable))

        #expect(first.canonicalFingerprint == nil)
        #expect(second.canonicalFingerprint == nil)
        #expect(!CapabilityHygieneAnalyzer.findings(in: [first, second]).contains { $0.kind == .exactDuplicate })
    }

    /// Verifies shadowing requires typed, valid provider precedence evidence.
    @Test func shadowingRequiresExplicitTypedWinnerAndLoserEvidence() throws {
        let winner = item(identity: "review", sourcePath: "/winner", content: "new")
        let loser = item(identity: "review", sourcePath: "/loser", content: "old")
        #expect(!CapabilityHygieneAnalyzer.findings(in: [winner, loser]).contains { $0.kind == .shadowing })

        let evidence = CapabilityPrecedenceEvidence(
            provider: .codex,
            ruleIdentifier: "fixture.codex.user-root-precedes-shared-root",
            evaluationScope: "user",
            winnerItemID: winner.id,
            loserItemID: loser.id
        )
        let finding = try #require(
            CapabilityHygieneAnalyzer.findings(in: [winner, loser], precedenceEvidence: [evidence])
                .first { $0.kind == .shadowing }
        )
        #expect(finding.shadowResolution?.winnerItemID == winner.id)
        #expect(finding.shadowResolution?.loserItemID == loser.id)

        let wrongProvider = CapabilityPrecedenceEvidence(
            provider: .claudeCode,
            ruleIdentifier: "invalid",
            evaluationScope: "user",
            winnerItemID: winner.id,
            loserItemID: loser.id
        )
        #expect(!CapabilityHygieneAnalyzer.findings(in: [winner, loser], precedenceEvidence: [wrongProvider])
            .contains { $0.kind == .shadowing })
    }

    /// Verifies static Claude and Cursor configuration never fabricates effective activation.
    @Test func claudeAndCursorMCPActivationRemainUnknownWithoutProviderPolicy() throws {
        let home = try makeHome()
        let project = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }
        try write(
            """
            {"mcpServers":{"Shared.Name+":{"command":"user"}},"projects":{"\(project.path)":{"mcpServers":{"Shared.Name+":{"command":"local"}}}}}
            """,
            to: home.appendingPathComponent(".claude.json")
        )
        try write(
            #"{"mcpServers":{"Shared.Name+":{"command":"project"}}}"#,
            to: project.appendingPathComponent(".mcp.json")
        )
        try write(
            #"{"mcpServers":{"Shared.Name+":{"command":"cursor"}}}"#,
            to: home.appendingPathComponent(".cursor/mcp.json")
        )

        let result = CapabilityHygieneScanner(homeDirectory: home).scan()
        #expect(result.precedenceEvidence.isEmpty)
        #expect(result.items.filter { $0.consumer == .claudeCode && $0.kind == .mcpServer }
            .allSatisfy { $0.activationState == .unknown })
        #expect(result.items.filter { $0.consumer == .cursor && $0.kind == .mcpServer }
            .allSatisfy { $0.activationState == .unknown })
        let shadowing = CapabilityHygieneAnalyzer.findings(
            in: result.items,
            precedenceEvidence: result.precedenceEvidence
        ).filter { $0.kind == .shadowing }
        #expect(shadowing.isEmpty)
    }

    /// Verifies possible overlap is conservative and cannot cross consumer boundaries.
    @Test func possibleOverlapIsDeterministicAndDoesNotCrossConsumers() throws {
        let first = item(identity: "github-pr-security-review", sourcePath: "/a", content: "a")
        let second = item(identity: "github-security-pr-review", sourcePath: "/b", content: "b")
        let otherConsumer = item(consumer: .claudeCode, identity: "github-review-security-pr", sourcePath: "/c", content: "c")

        let findings = CapabilityHygieneAnalyzer.findings(in: [otherConsumer, second, first])
        let overlap = try #require(findings.first { $0.kind == .possibleOverlap })
        #expect(overlap.itemIDs == [first.id, second.id].sorted())
        #expect(overlap.similarity == 1.0)
        #expect(findings.filter { $0.kind == .possibleOverlap }.count == 1)
    }

    /// Verifies malformed UTF-8 and duplicate JSON keys are rejected with distinct statuses.
    @Test func malformedUTF8AndDuplicateJSONKeysAreRejected() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(Data([0xFF, 0xFE]), to: home.appendingPathComponent(".claude/plugins/installed_plugins.json"))
        try write(
            #"{"mcpServers":{"one":{"command":"a"}},"mcpServers":{"two":{"command":"b"}}}"#,
            to: home.appendingPathComponent(".cursor/mcp.json")
        )

        let result = CapabilityHygieneScanner(homeDirectory: home).scan()

        #expect(result.notices.contains { $0.reason == .malformedUTF8 })
        #expect(result.notices.contains { $0.reason == .malformedJSON })
        #expect(result.sources.contains { $0.sourcePath.hasSuffix("installed_plugins.json") && $0.status == .partial(.malformedUTF8) })
        #expect(result.sources.contains { $0.sourcePath.hasSuffix(".cursor/mcp.json") && $0.status == .partial(.malformedJSON) })
        #expect(result.items.isEmpty)
    }

    /// Verifies FIFO, symlink, and path-escape inputs remain incomplete and unread.
    @Test func specialFilesSymlinksAndPluginPathEscapesAreRefused() throws {
        let home = try makeHome()
        let outside = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        let skillDirectory = home.appendingPathComponent(".codex/skills/safe", isDirectory: true)
        try write("---\nname: safe\n---\nRead only.\n", to: skillDirectory.appendingPathComponent("SKILL.md"))
        let fifo = skillDirectory.appendingPathComponent("input.fifo").path
        #expect(fifo.withCString { Darwin.mkfifo($0, 0o600) } == 0)
        let outsideFile = outside.appendingPathComponent("secret.txt")
        try write("outside-secret", to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: skillDirectory.appendingPathComponent("escaped.txt"),
            withDestinationURL: outsideFile
        )
        try write(
            """
            {"plugins":{"escape@catalog":[{"scope":"user","installPath":"\(outside.path)"}]}}
            """,
            to: home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        )

        let result = CapabilityHygieneScanner(homeDirectory: home).scan()
        let skill = try #require(result.items.first { $0.kind == .skill })
        let plugin = try #require(result.items.first { $0.kind == .plugin })

        #expect(skill.canonicalFingerprint == nil)
        #expect([CapabilitySourceReason.specialFile, .symbolicLink].contains { reason in
            result.notices.contains { $0.reason == reason }
        })
        #expect(result.notices.contains { $0.reason == .specialFile })
        #expect(result.notices.contains { $0.reason == .symbolicLink })
        #expect(plugin.sourceStatus == .refused(.pathEscape))
        #expect(!result.items.map(\.summary).compactMap { $0 }.joined().contains("outside-secret"))
    }

    /// Verifies byte, entry, depth, and root limits surface conservative notices.
    @Test func boundedResourcesProduceConservativeStatuses() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(String(repeating: "x", count: 80), to: home.appendingPathComponent(".codex/skills/large/SKILL.md"))
        try write("---\nname: deep\n---\nbody", to: home.appendingPathComponent(".agents/skills/a/b/c/d/e/SKILL.md"))
        try write("{\"projects\":{\"/tmp/a\":{},\"/tmp/b\":{}}}", to: home.appendingPathComponent(".claude.json"))

        let result = CapabilityHygieneScanner(
            homeDirectory: home,
            limits: .init(
                maximumFileBytes: 64,
                maximumAggregateBytes: 512,
                maximumEntries: 100,
                maximumDepth: 4,
                maximumRoots: 1
            )
        ).scan()

        #expect(result.notices.contains { $0.reason == .fileByteLimit })
        #expect(result.notices.contains { $0.reason == .depthLimit })
        #expect(result.notices.contains { $0.reason == .rootLimit })
    }

    /// Verifies discovered command strings remain inert and output ordering is stable.
    @Test func scanningIsStaticAndOrderingIsDeterministic() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let marker = home.appendingPathComponent("executed-marker")
        try write(
            """
            {"mcpServers":{"z":{"command":"/usr/bin/touch","args":["\(marker.path)"]},"a":{"command":"/bin/false"}}}
            """,
            to: home.appendingPathComponent(".cursor/mcp.json")
        )

        let first = CapabilityHygieneScanner(homeDirectory: home).scan()
        let second = CapabilityHygieneScanner(homeDirectory: home).scan()

        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(first.items.map(\.runtimeIdentity) == second.items.map(\.runtimeIdentity))
        #expect(first.items.map(\.runtimeIdentity) == ["a", "z"])
    }

    /// Verifies long and control-containing provider keys remain exact analyzer identities.
    @Test func longRuntimeIdentitiesAreNeverTruncatedOrCollapsed() throws {
        let home = try makeHome()
        let project = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }
        let identity = String(repeating: "Long.Identity+", count: 40) + "\nExact"
        let encodedIdentity = try #require(
            String(data: JSONSerialization.data(withJSONObject: identity, options: [.fragmentsAllowed]), encoding: .utf8)
        )
        try write(
            "{\"mcpServers\":{\(encodedIdentity):{\"command\":\"user\"}},\"projects\":{\"\(project.path)\":{\"mcpServers\":{\(encodedIdentity):{\"command\":\"local\"}}}}}",
            to: home.appendingPathComponent(".claude.json")
        )
        try write("{\"mcpServers\":{\(encodedIdentity):{\"command\":\"project\"}}}", to: project.appendingPathComponent(".mcp.json"))

        let result = CapabilityHygieneScanner(homeDirectory: home).scan()

        #expect(result.items.filter { $0.runtimeIdentity == identity }.count == 3)
        #expect(result.items.allSatisfy { $0.runtimeIdentity.count > 160 })
        #expect(result.precedenceEvidence.isEmpty)
        #expect(result.items.allSatisfy { $0.activationState == .unknown })
    }

    /// Verifies MCP schema completeness, scan-local exact equality, and value-free metadata.
    @Test func jsonMCPExactFingerprintsPreserveBehaviorWithoutDisclosingSecrets() throws {
        let home = try makeHome()
        let project = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }
        let definition = #"{"type":"stdio","command":"/private/bin/secret-helper","args":["--token","literal-argument-secret"],"env":{"VALID_TOKEN":"literal-env-secret","bad=key":"hidden"},"headers":{"Authorization":"literal-header-secret","X-Good":"ok","Bad Header":"hidden"}}"#
        let reorderedDefinition = #"{"headers":{"Bad Header":"hidden","X-Good":"ok","Authorization":"literal-header-secret"},"env":{"bad=key":"hidden","VALID_TOKEN":"literal-env-secret"},"args":["--token","literal-argument-secret"],"command":"/private/bin/secret-helper","type":"stdio"}"#
        try write("{\"mcpServers\":{\"shared\":\(definition)},\"projects\":{\"\(project.path)\":{}}}", to: home.appendingPathComponent(".claude.json"))
        try write("{\"mcpServers\":{\"shared\":\(reorderedDefinition)}}", to: home.appendingPathComponent(".cursor/mcp.json"))
        try write(#"{"mcpServers":{"shared":{"type":"stdio","command":"/private/bin/secret-helper","args":["literal-argument-secret","--token"],"env":{"VALID_TOKEN":"literal-env-secret","bad=key":"hidden"},"headers":{"Authorization":"literal-header-secret","X-Good":"ok","Bad Header":"hidden"}}}}"#, to: project.appendingPathComponent(".mcp.json"))

        let result = CapabilityHygieneScanner(homeDirectory: home).scan()
        let shared = result.items.filter { $0.kind == .mcpServer && $0.runtimeIdentity == "shared" }
        let claudeUser = try #require(shared.first { $0.consumer == .claudeCode && $0.effectiveScope == "user" })
        let cursor = try #require(shared.first { $0.consumer == .cursor })
        let projectItem = try #require(shared.first { $0.effectiveScope == project.path })

        #expect(claudeUser.supportsExactMatching)
        #expect(claudeUser.canonicalFingerprint == cursor.canonicalFingerprint)
        #expect(claudeUser.canonicalFingerprint != projectItem.canonicalFingerprint)
        #expect(claudeUser.secretReferenceNames == ["VALID_TOKEN"])
        #expect(claudeUser.headerNames == ["Authorization", "X-Good"])
        #expect(claudeUser.summary == MCPServerTransport.stdio.displayName)
        #expect(claudeUser.canonicalFingerprint?.description == "<opaque capability fingerprint>")

        let exposed = shared.flatMap {
            [$0.runtimeIdentity, $0.sourcePath, $0.summary ?? ""]
                + $0.secretReferenceNames + $0.headerNames
        }.joined(separator: " ")
        for secret in ["literal-argument-secret", "literal-env-secret", "literal-header-secret", "/private/bin/secret-helper", "bad=key", "Bad Header"] {
            #expect(!exposed.contains(secret))
        }

        let later = CapabilityHygieneScanner(homeDirectory: home).scan()
        let laterClaude = try #require(later.items.first {
            $0.kind == .mcpServer && $0.runtimeIdentity == "shared" && $0.consumer == .claudeCode && $0.effectiveScope == "user"
        })
        #expect(claudeUser.canonicalFingerprint != laterClaude.canonicalFingerprint)
    }

    /// Verifies malformed MCP containers and unknown behavior fields downgrade source truthfully.
    @Test func malformedMCPSchemasArePartialInsteadOfSilentlyEmpty() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"mcpServers":[]}"#, to: home.appendingPathComponent(".cursor/mcp.json"))
        try write(#"{"mcpServers":{"known":{"command":"tool","unknownBehavior":true}}}"#, to: home.appendingPathComponent(".claude.json"))

        let result = CapabilityHygieneScanner(homeDirectory: home).scan()
        let unknown = try #require(result.items.first { $0.runtimeIdentity == "known" })

        #expect(unknown.sourceStatus == .partial(.unsupportedFormat))
        #expect(unknown.canonicalFingerprint == nil)
        #expect(result.sources.contains { $0.sourcePath.hasSuffix(".cursor/mcp.json") && $0.status == .partial(.unsupportedFormat) })
        #expect(result.sources.contains { $0.sourcePath.hasSuffix(".claude.json") && $0.status == .partial(.unsupportedFormat) })
    }

    /// Verifies recursive JSON and member bombs stop at explicit shared scan budgets.
    @Test func jsonDepthAndMemberLimitsAreEnforcedBeforeFoundationDecoding() throws {
        let deepHome = try makeHome()
        let wideHome = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: deepHome)
            try? FileManager.default.removeItem(at: wideHome)
        }
        try write(#"{"mcpServers":{"x":{"env":{"A":{"b":{"c":"d"}}}}}}"#, to: deepHome.appendingPathComponent(".cursor/mcp.json"))
        try write(#"{"mcpServers":{"a":{"command":"a"},"b":{"command":"b"},"c":{"command":"c"}}}"#, to: wideHome.appendingPathComponent(".cursor/mcp.json"))

        let deep = CapabilityHygieneScanner(
            homeDirectory: deepHome,
            limits: .init(maximumFileBytes: 1_024, maximumAggregateBytes: 4_096, maximumEntries: 100, maximumDepth: 3, maximumRoots: 4)
        ).scan()
        let wide = CapabilityHygieneScanner(
            homeDirectory: wideHome,
            limits: .init(maximumFileBytes: 1_024, maximumAggregateBytes: 4_096, maximumEntries: 4, maximumDepth: 8, maximumRoots: 4)
        ).scan()

        #expect(deep.notices.contains { $0.reason == .depthLimit })
        #expect(wide.notices.contains { $0.reason == .entryLimit })
        #expect(deep.items.isEmpty)
        #expect(wide.items.isEmpty)
    }

    /// Verifies unreadable skill identity metadata downgrades the owning root.
    @Test func malformedSkillMarkdownPropagatesPartialRootStatus() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(Data([0xFF, 0xFE]), to: home.appendingPathComponent(".codex/skills/broken/SKILL.md"))

        let result = CapabilityHygieneScanner(homeDirectory: home).scan()

        #expect(result.items.isEmpty)
        #expect(result.sources.contains {
            $0.sourcePath.hasSuffix(".codex/skills") && $0.status == .partial(.malformedUTF8)
        })
        #expect(result.notices.contains { $0.reason == .malformedUTF8 })
    }

    /// Verifies Codex plugin override tables never masquerade as installed plugins.
    @Test func codexPluginOverridesDoNotCreatePhantomInventory() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("[plugins.\"phantom@catalog\"]\nenabled = true\n", to: home.appendingPathComponent(".codex/config.toml"))

        let result = CapabilityHygieneScanner(homeDirectory: home).scan()

        #expect(!result.items.contains { $0.kind == .plugin && $0.consumer == .codex })
        #expect(!result.items.contains { $0.runtimeIdentity == "phantom@catalog" })
    }

    /// Verifies authoritative Claude install trees enable exact plugin comparison only when complete.
    @Test func claudePluginFingerprintsIncludeRegistryAndBoundedBehaviorTree() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let roots = (0..<3).map { home.appendingPathComponent(".claude/plugins/installed/p\($0)", isDirectory: true) }
        for root in roots { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        try write("same\r\n", to: roots[0].appendingPathComponent("plugin.md"))
        try write("same\r\n", to: roots[1].appendingPathComponent("plugin.md"))
        try write("same\n", to: roots[2].appendingPathComponent("plugin.md"))
        let occurrences = roots.enumerated().map { index, root in
            "{\"scope\":\"user\",\"installPath\":\"\(root.path)\",\"version\":\"1.0.0\",\"installedAt\":\"2026-07-1\(index)T00:00:00Z\"}"
        }.joined(separator: ",")
        try write("{\"plugins\":{\"review@catalog\":[\(occurrences)]}}", to: home.appendingPathComponent(".claude/plugins/installed_plugins.json"))

        let plugins = CapabilityHygieneScanner(homeDirectory: home).scan().items.filter { $0.kind == .plugin }

        #expect(plugins.count == 3)
        #expect(plugins.allSatisfy { $0.supportsExactMatching })
        #expect(plugins[0].canonicalFingerprint == plugins[1].canonicalFingerprint)
        #expect(plugins[1].canonicalFingerprint != plugins[2].canonicalFingerprint)
    }

    /// Verifies same-size in-place mutation is caught by the descriptor post-read metadata check.
    @Test func sourceMutationDuringDescriptorReadIsReportedAsPartial() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent(".cursor/mcp.json")
        try write(#"{"mcpServers":{}}"#, to: source)
        let sourcePath = source.path
        let scanner = CapabilityHygieneScanner(
            homeDirectory: home,
            testingAfterDescriptorRead: { relativePath in
                guard relativePath == ".cursor/mcp.json" else { return }
                try! Data(#"{"mcpServers":[]}"#.utf8).write(to: URL(fileURLWithPath: sourcePath))
            }
        )

        let result = scanner.scan()

        #expect(result.items.isEmpty)
        #expect(result.sources.contains {
            $0.sourcePath.hasSuffix(".cursor/mcp.json") && $0.status == .partial(.unavailable)
        })
        #expect(result.notices.contains { $0.reason == .unavailable })
    }

    /// Verifies Codex's explicit disabled field is preserved instead of assuming availability.
    @Test func codexDisabledMCPIsExcludedFromAnalysis() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            """
            [mcp_servers.review]
            command = "review-server"
            enabled = false
            """,
            to: home.appendingPathComponent(".codex/config.toml")
        )

        let result = CapabilityHygieneScanner(homeDirectory: home).scan()
        let server = try #require(result.items.first { $0.consumer == .codex && $0.runtimeIdentity == "review" })

        #expect(server.activationState == .disabled)
        #expect(CapabilityHygieneAnalyzer.findings(in: result.items).isEmpty)
    }

    /// Verifies Claude plugin activation comes from settings and can remain explicitly disabled.
    @Test func claudePluginActivationUsesEnabledPluginsSettings() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let install = home.appendingPathComponent(".claude/plugins/installed/review", isDirectory: true)
        try write("plugin", to: install.appendingPathComponent("plugin.md"))
        try write(
            #"{"enabledPlugins":{"review@catalog":false}}"#,
            to: home.appendingPathComponent(".claude/settings.json")
        )
        try write(
            """
            {"plugins":{"review@catalog":[{"scope":"user","installPath":"\(install.path)","version":"1.0.0"}]}}
            """,
            to: home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        )

        let result = CapabilityHygieneScanner(homeDirectory: home).scan()
        let plugin = try #require(result.items.first { $0.runtimeIdentity == "review@catalog" })

        #expect(plugin.activationState == .disabled)
    }

    /// Verifies exclusive managed MCP presence suppresses lower-scope activation and precedence.
    @Test func managedClaudeMCPPolicyFailsClosed() throws {
        let home = try makeHome()
        let project = try makeHome()
        let managedDirectory = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: managedDirectory)
        }
        try write(#"{"mcpServers":{}}"#, to: managedDirectory.appendingPathComponent("managed-mcp.json"))
        try write(
            """
            {"mcpServers":{"review":{"command":"user"}},"projects":{"\(project.path)":{"mcpServers":{"review":{"command":"local"}}}}}
            """,
            to: home.appendingPathComponent(".claude.json")
        )
        try write(#"{"mcpServers":{"review":{"command":"project"}}}"#, to: project.appendingPathComponent(".mcp.json"))

        let result = CapabilityHygieneScanner(
            homeDirectory: home,
            claudeManagedMCPDirectory: managedDirectory
        ).scan()
        let claudeServers = result.items.filter { $0.consumer == .claudeCode && $0.kind == .mcpServer }

        #expect(!claudeServers.isEmpty)
        #expect(claudeServers.allSatisfy { $0.activationState == .unknown })
        #expect(result.precedenceEvidence.isEmpty)
        #expect(result.sources.contains {
            $0.sourcePath.hasSuffix("managed-mcp.json")
                && $0.status == .partial(.behaviorDefinitionUnavailable)
        })
    }

    /// Verifies malformed Codex TOML cannot become a complete empty source.
    @Test func malformedCodexTOMLIsReportedAsPartial() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("[mcp_servers.review\ncommand = \"broken\"\n", to: home.appendingPathComponent(".codex/config.toml"))

        let result = CapabilityHygieneScanner(homeDirectory: home).scan()

        #expect(result.items.isEmpty)
        #expect(result.sources.contains {
            $0.sourcePath.hasSuffix(".codex/config.toml") && $0.status == .partial(.malformedTOML)
        })
        #expect(result.notices.contains { $0.reason == .malformedTOML })
    }

    /// Verifies recoverable rows from incomplete Codex TOML cannot enter relation analysis.
    @Test func malformedCodexTOMLRetainsInventoryWithUnknownActivation() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            """
            [mcp_servers.review]
            command = "review"
            enabled = "false" trailing
            """,
            to: home.appendingPathComponent(".codex/config.toml")
        )

        let result = CapabilityHygieneScanner(homeDirectory: home).scan()
        let server = try #require(result.items.first { $0.consumer == .codex && $0.runtimeIdentity == "review" })

        #expect(server.activationState == .unknown)
        #expect(result.sources.contains {
            $0.sourcePath.hasSuffix(".codex/config.toml") && $0.status == .partial(.malformedTOML)
        })
        #expect(CapabilityHygieneAnalyzer.findings(in: result.items).isEmpty)
    }

    /// Verifies every Claude plugin installation root consumes the shared provider budget.
    @Test func claudePluginInstallRootsRespectProviderRootLimit() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let roots = (0..<3).map { home.appendingPathComponent(".claude/plugins/installed/root-\($0)") }
        for root in roots { try write("plugin", to: root.appendingPathComponent("plugin.md")) }
        let occurrences = roots.map { root in
            "{\"scope\":\"user\",\"installPath\":\"\(root.path)\",\"version\":\"1.0.0\"}"
        }.joined(separator: ",")
        try write(
            "{\"plugins\":{\"review@catalog\":[\(occurrences)]}}",
            to: home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        )

        let result = CapabilityHygieneScanner(
            homeDirectory: home,
            limits: .init(
                maximumFileBytes: 256 * 1_024,
                maximumAggregateBytes: 1_024 * 1_024,
                maximumEntries: 1_000,
                maximumDepth: 8,
                maximumRoots: 2
            ),
            claudeManagedMCPDirectory: home.appendingPathComponent("managed")
        ).scan()
        let plugins = result.items.filter { $0.consumer == .claudeCode && $0.kind == .plugin }

        #expect(plugins.count == 3)
        #expect(plugins.filter { $0.sourceStatus == .partial(.rootLimit) }.count == 1)
        #expect(result.notices.contains { $0.reason == .rootLimit })
    }

    /// Verifies Foundation numeric bridging cannot masquerade as a JSON Boolean.
    @Test func numericClaudePluginActivationIsRejected() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let install = home.appendingPathComponent(".claude/plugins/installed/review")
        try write("plugin", to: install.appendingPathComponent("plugin.md"))
        try write(
            #"{"enabledPlugins":{"review@catalog":1}}"#,
            to: home.appendingPathComponent(".claude/settings.json")
        )
        try write(
            "{\"plugins\":{\"review@catalog\":[{\"scope\":\"user\",\"installPath\":\"\(install.path)\",\"version\":\"1.0.0\"}]}}",
            to: home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        )

        let result = CapabilityHygieneScanner(
            homeDirectory: home,
            claudeManagedMCPDirectory: home.appendingPathComponent("managed")
        ).scan()
        let plugin = try #require(result.items.first { $0.runtimeIdentity == "review@catalog" })

        #expect(plugin.activationState == .unknown)
        #expect(result.sources.contains {
            $0.sourcePath.hasSuffix(".claude/settings.json") && $0.status == .partial(.unsupportedFormat)
        })
    }

    /// Verifies VoiceOver receives every visible evidence field as one stable summary.
    @Test func occurrenceAccessibilitySummaryIncludesAllEvidence() {
        let occurrence = item(
            consumer: .codex,
            identity: "review.server",
            sourcePath: "/tmp/config.toml",
            scope: "user",
            content: "review"
        )

        let english = CapabilityHygieneAccessibility.occurrenceSummary(
            for: occurrence,
            labels: .init(
                occurrence: "Occurrence",
                identity: "Identity",
                consumer: "Consumer",
                scope: "Scope",
                sourcePath: "Source path"
            )
        )
        let german = CapabilityHygieneAccessibility.occurrenceSummary(
            for: occurrence,
            labels: .init(
                occurrence: "Vorkommen",
                identity: "Identität",
                consumer: "Consumer",
                scope: "Scope",
                sourcePath: "Quellpfad"
            )
        )

        #expect(english.contains("Identity: review.server"))
        #expect(english.contains("Consumer: Codex"))
        #expect(english.contains("Scope: user"))
        #expect(english.contains("Source path: /tmp/config.toml"))
        #expect(german.contains("Identität: review.server"))
        #expect(german.contains("Quellpfad: /tmp/config.toml"))
    }

    /// Verifies a replace-read-restore ABA sequence cannot produce a complete tree fingerprint.
    @Test func treeSnapshotBindsOpenedFileToEnumeratedIdentity() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent(".codex/skills/review/SKILL.md")
        let original = home.appendingPathComponent("original-SKILL.md")
        let replacement = home.appendingPathComponent("replacement-SKILL.md")
        try write("---\nname: review\n---\noriginal\n", to: source)
        try write("---\nname: review\n---\ntransient\n", to: replacement)
        let sourcePath = source.path
        let originalPath = original.path
        let replacementPath = replacement.path
        let scanner = CapabilityHygieneScanner(
            homeDirectory: home,
            testingAfterDescriptorRead: { relativePath in
                guard relativePath == "SKILL.md", FileManager.default.fileExists(atPath: originalPath) else { return }
                try! FileManager.default.removeItem(atPath: sourcePath)
                try! FileManager.default.moveItem(atPath: originalPath, toPath: sourcePath)
            },
            testingAfterDirectoryEnumeration: { displayPath in
                guard displayPath.hasSuffix("/.codex/skills/review/SKILL.md"),
                      FileManager.default.fileExists(atPath: replacementPath) else { return }
                try! FileManager.default.moveItem(atPath: sourcePath, toPath: originalPath)
                try! FileManager.default.moveItem(atPath: replacementPath, toPath: sourcePath)
            }
        )

        let result = scanner.scan()
        #expect(!result.items.contains { $0.runtimeIdentity == "review" })
        #expect(result.sources.contains {
            $0.sourcePath.hasSuffix(".codex/skills") && $0.status == .partial(.unavailable)
        })
        #expect(result.notices.contains { $0.reason == .unavailable })
    }
}
