//
//  CapabilityHygieneScanner.swift
//  CodingBuddy
//

import CryptoKit
import CoreFoundation
import Darwin
import Foundation

/// Static, descriptor-bound scanner for authoritative local capability sources.
nonisolated struct CapabilityHygieneScanner: Sendable {
    /// Resource limits shared across one complete scan.
    struct Limits: Equatable, Sendable {
        /// Maximum bytes read from one regular file.
        let maximumFileBytes: Int
        /// Maximum aggregate bytes read across the scan.
        let maximumAggregateBytes: Int
        /// Maximum directory entries inspected across the scan.
        let maximumEntries: Int
        /// Maximum skill-tree depth below a supported root.
        let maximumDepth: Int
        /// Maximum external project/provider roots opened during one scan.
        let maximumRoots: Int

        /// Conservative production defaults.
        static let standard = Limits(
            maximumFileBytes: 256 * 1024,
            maximumAggregateBytes: 8 * 1024 * 1024,
            maximumEntries: 10_000,
            maximumDepth: 8,
            maximumRoots: 128
        )
    }

    /// Home directory whose static configuration is inspected.
    let homeDirectory: URL
    /// Explicit production or fixture limits.
    let limits: Limits
    /// System directory that may impose Claude's exclusive managed MCP inventory.
    let claudeManagedMCPDirectory: URL
    /// Test-only observer invoked after bytes are read but before descriptor metadata is revalidated.
    private let testingAfterDescriptorRead: (@Sendable (String) -> Void)?
    /// Test-only observer invoked after a tree directory is enumerated and before children open.
    private let testingAfterDirectoryEnumeration: (@Sendable (String) -> Void)?

    /// Creates a scanner rooted at a real or temporary home directory.
    init(
        homeDirectory: URL,
        limits: Limits = .standard,
        claudeManagedMCPDirectory: URL = URL(
            fileURLWithPath: "/Library/Application Support/ClaudeCode",
            isDirectory: true
        ),
        testingAfterDescriptorRead: (@Sendable (String) -> Void)? = nil,
        testingAfterDirectoryEnumeration: (@Sendable (String) -> Void)? = nil
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.limits = limits
        self.claudeManagedMCPDirectory = claudeManagedMCPDirectory.standardizedFileURL
        self.testingAfterDescriptorRead = testingAfterDescriptorRead
        self.testingAfterDirectoryEnumeration = testingAfterDirectoryEnumeration
    }

    /// Performs one bounded scan without executing discovered commands or provider CLIs.
    func scan() -> CapabilityScanResult {
        var budget = ScanBudget(limits: limits)
        let secretFingerprintKey = SymmetricKey(size: .bits256)
        var items: [CapabilityInventoryItem] = []
        var sources: [CapabilitySourceRecord] = []
        var notices: [CapabilityScanNotice] = []

        guard let homeDescriptor = SecureDescriptorIO.openAbsoluteDirectory(homeDirectory.path) else {
            let status: CapabilitySourceStatus = .refused(.symbolicLink)
            sources.append(.init(sourcePath: homeDirectory.path, kind: nil, status: status))
            notices.append(.init(reason: .symbolicLink, sourcePath: homeDirectory.path))
            return .init(items: [], sources: sources, notices: notices, precedenceEvidence: [])
        }
        defer { Darwin.close(homeDescriptor) }

        scanSkillRoots(
            homeDescriptor: homeDescriptor,
            budget: &budget,
            items: &items,
            sources: &sources,
            notices: &notices
        )
        scanCodexConfig(
            homeDescriptor: homeDescriptor,
            budget: &budget,
            items: &items,
            sources: &sources,
            notices: &notices
        )
        _ = detectExclusiveClaudeManagedMCP(
            budget: &budget,
            sources: &sources,
            notices: &notices
        )
        scanClaudeConfiguration(
            homeDescriptor: homeDescriptor,
            budget: &budget,
            items: &items,
            sources: &sources,
            notices: &notices,
            secretFingerprintKey: secretFingerprintKey
        )
        scanCursorConfiguration(
            homeDescriptor: homeDescriptor,
            budget: &budget,
            items: &items,
            sources: &sources,
            notices: &notices,
            secretFingerprintKey: secretFingerprintKey
        )
        scanClaudePlugins(
            homeDescriptor: homeDescriptor,
            budget: &budget,
            items: &items,
            sources: &sources,
            notices: &notices,
            secretFingerprintKey: secretFingerprintKey
        )

        return CapabilityScanResult(
            items: items.sorted(by: Self.itemOrder),
            sources: Array(Set(sources)).sorted(by: Self.sourceOrder),
            notices: Array(Set(notices)).sorted(by: Self.noticeOrder),
            precedenceEvidence: []
        )
    }

    /// Scans standalone skill roots with descriptor-held traversal and complete tree snapshots.
    private func scanSkillRoots(
        homeDescriptor: Int32,
        budget: inout ScanBudget,
        items: inout [CapabilityInventoryItem],
        sources: inout [CapabilitySourceRecord],
        notices: inout [CapabilityScanNotice]
    ) {
        let roots: [(String, CapabilityConsumer)] = [
            (".codex/skills", .codex),
            (".agents/skills", .sharedAgents),
            (".claude/skills", .claudeCode),
        ]
        for (relativePath, consumer) in roots {
            let displayPath = homeDirectory.appendingPathComponent(relativePath).path
            switch SecureDescriptorIO.openDirectory(relativePath, beneath: homeDescriptor) {
            case .failure(.missing):
                sources.append(.init(sourcePath: displayPath, kind: .skill, status: .missing))
            case let .failure(failure):
                let reason = failure.reason
                sources.append(.init(sourcePath: displayPath, kind: .skill, status: .refused(reason)))
                notices.append(.init(reason: reason, sourcePath: displayPath))
            case let .success(rootDescriptor):
                defer { Darwin.close(rootDescriptor) }
                var rootStatus: CapabilitySourceStatus = .complete
                discoverSkills(
                    directoryDescriptor: rootDescriptor,
                    relativeDirectory: "",
                    displayRoot: displayPath,
                    consumer: consumer,
                    depth: 0,
                    budget: &budget,
                    items: &items,
                    rootStatus: &rootStatus,
                    notices: &notices
                )
                sources.append(.init(sourcePath: displayPath, kind: .skill, status: rootStatus))
            }
        }
    }

    /// Recursively discovers directories containing `SKILL.md` without following links.
    private func discoverSkills(
        directoryDescriptor: Int32,
        relativeDirectory: String,
        displayRoot: String,
        consumer: CapabilityConsumer,
        depth: Int,
        budget: inout ScanBudget,
        items: inout [CapabilityInventoryItem],
        rootStatus: inout CapabilitySourceStatus,
        notices: inout [CapabilityScanNotice]
    ) {
        guard depth <= limits.maximumDepth else {
            rootStatus = .partial(.depthLimit)
            notices.append(.init(reason: .depthLimit, sourcePath: displayRoot + "/" + relativeDirectory))
            return
        }
        let entries: [SecureDirectoryEntry]
        do {
            entries = try SecureDescriptorIO.entries(in: directoryDescriptor, budget: &budget)
        } catch let failure as SecureReadFailure {
            rootStatus = .partial(failure.reason)
            notices.append(.init(reason: failure.reason, sourcePath: displayRoot + "/" + relativeDirectory))
            return
        } catch { return }

        if entries.contains(where: { $0.name == "SKILL.md" }) {
            let result = skillItem(
                directoryDescriptor: directoryDescriptor,
                relativeDirectory: relativeDirectory,
                displayRoot: displayRoot,
                consumer: consumer,
                budget: &budget,
                notices: &notices
            )
            if let item = result.item { items.append(item) }
            if result.status != .complete { rootStatus = result.status }
        }

        for entry in entries where entry.kind == .directory {
            let childRelative = relativeDirectory.isEmpty ? entry.name : relativeDirectory + "/" + entry.name
            switch SecureDescriptorIO.openChildDirectory(
                named: entry.name,
                beneath: directoryDescriptor,
                expectedIdentity: entry.identity
            ) {
            case let .success(childDescriptor):
                discoverSkills(
                    directoryDescriptor: childDescriptor,
                    relativeDirectory: childRelative,
                    displayRoot: displayRoot,
                    consumer: consumer,
                    depth: depth + 1,
                    budget: &budget,
                    items: &items,
                    rootStatus: &rootStatus,
                    notices: &notices
                )
                Darwin.close(childDescriptor)
            case let .failure(failure):
                rootStatus = .partial(failure.reason)
                notices.append(.init(reason: failure.reason, sourcePath: displayRoot + "/" + childRelative))
            }
        }
    }

    /// Builds one skill occurrence from a complete bounded no-follow tree snapshot.
    private func skillItem(
        directoryDescriptor: Int32,
        relativeDirectory: String,
        displayRoot: String,
        consumer: CapabilityConsumer,
        budget: inout ScanBudget,
        notices: inout [CapabilityScanNotice]
    ) -> SkillItemResult {
        let sourcePath = displayRoot + (relativeDirectory.isEmpty ? "" : "/" + relativeDirectory) + "/SKILL.md"
        let snapshot = skillTreeSnapshot(
            directoryDescriptor: directoryDescriptor,
            relativeDirectory: "",
            displayPath: sourcePath,
            depth: 0,
            budget: &budget,
            notices: &notices
        )
        guard let skillData = snapshot.files.first(where: { $0.path == "SKILL.md" })?.data else {
            let status = snapshot.status == .complete ? .partial(.unavailable) : snapshot.status
            if snapshot.status == .complete {
                notices.append(.init(reason: .unavailable, sourcePath: sourcePath))
            }
            return .init(item: nil, status: status)
        }
        guard let skillText = String(data: skillData, encoding: .utf8) else {
            notices.append(.init(reason: .malformedUTF8, sourcePath: sourcePath))
            return .init(item: nil, status: .partial(.malformedUTF8))
        }
        let metadata = Self.skillMetadata(skillText)
        let fallback = URL(fileURLWithPath: sourcePath).deletingLastPathComponent().lastPathComponent
        let identity = Self.safeIdentity(metadata["name"] ?? fallback, fallback: fallback)
        let fingerprint = snapshot.status == .complete
            ? CapabilityFingerprint.publicContent(
                schemaVersion: "skill-tree-v2-raw-mode",
                data: Self.canonicalBehaviorTree(snapshot.files, nodes: snapshot.nodes)
            )
            : nil
        let item = CapabilityInventoryItem(
            kind: .skill,
            consumer: consumer,
            runtimeIdentity: identity,
            sourcePath: sourcePath,
            effectiveScope: "user",
            version: Self.safeVersion(metadata["version"]),
            summary: nil,
            permissionNames: Self.permissionNames(from: metadata),
            secretReferenceNames: Self.secretReferenceNames(in: skillText, metadata: metadata),
            registrationState: .installed,
            activationState: .enabled,
            sourceStatus: snapshot.status,
            canonicalFingerprint: fingerprint
        )
        return .init(item: item, status: snapshot.status)
    }

    /// Captures all behavior-supporting files below one skill directory or marks the tree incomplete.
    private func skillTreeSnapshot(
        directoryDescriptor: Int32,
        relativeDirectory: String,
        displayPath: String,
        depth: Int,
        budget: inout ScanBudget,
        notices: inout [CapabilityScanNotice]
    ) -> SkillTreeSnapshot {
        guard depth <= limits.maximumDepth else {
            notices.append(.init(reason: .depthLimit, sourcePath: displayPath))
            return .init(files: [], nodes: [], status: .partial(.depthLimit))
        }
        let entries: [SecureDirectoryEntry]
        do {
            entries = try SecureDescriptorIO.entries(in: directoryDescriptor, budget: &budget)
        } catch let failure as SecureReadFailure {
            notices.append(.init(reason: failure.reason, sourcePath: displayPath))
            return .init(files: [], nodes: [], status: .partial(failure.reason))
        } catch { return .init(files: [], nodes: [], status: .partial(.unavailable)) }
        testingAfterDirectoryEnumeration?(displayPath)

        var files: [SkillTreeFile] = []
        var nodes = entries.map { entry in
            BehaviorTreeNode(
                path: relativeDirectory.isEmpty ? entry.name : relativeDirectory + "/" + entry.name,
                kind: entry.kind,
                identity: entry.identity
            )
        }
        var status: CapabilitySourceStatus = .complete
        for entry in entries {
            let relative = relativeDirectory.isEmpty ? entry.name : relativeDirectory + "/" + entry.name
            switch entry.kind {
            case .regularFile:
                do {
                    let file = try SecureDescriptorIO.readFileSnapshot(
                        named: entry.name,
                        beneath: directoryDescriptor,
                        expectedIdentity: entry.identity,
                        budget: &budget,
                        afterRead: { testingAfterDescriptorRead?(relative) }
                    )
                    files.append(.init(path: relative, mode: file.mode, data: file.data))
                } catch let failure as SecureReadFailure {
                    status = .partial(failure.reason)
                    notices.append(.init(reason: failure.reason, sourcePath: displayPath + "/" + relative))
                } catch { status = .partial(.unavailable) }
            case .directory:
                switch SecureDescriptorIO.openChildDirectory(
                    named: entry.name,
                    beneath: directoryDescriptor,
                    expectedIdentity: entry.identity
                ) {
                case let .success(childDescriptor):
                    let child = skillTreeSnapshot(
                        directoryDescriptor: childDescriptor,
                        relativeDirectory: relative,
                        displayPath: displayPath,
                        depth: depth + 1,
                        budget: &budget,
                        notices: &notices
                    )
                    Darwin.close(childDescriptor)
                    files += child.files
                    nodes += child.nodes
                    if child.status != .complete { status = child.status }
                case let .failure(failure):
                    status = .partial(failure.reason)
                    notices.append(.init(reason: failure.reason, sourcePath: displayPath + "/" + relative))
                }
            case .symbolicLink:
                status = .partial(.symbolicLink)
                notices.append(.init(reason: .symbolicLink, sourcePath: displayPath + "/" + relative))
            case .special:
                status = .partial(.specialFile)
                notices.append(.init(reason: .specialFile, sourcePath: displayPath + "/" + relative))
            }
        }
        do {
            let finalEntries = try SecureDescriptorIO.entries(in: directoryDescriptor, budget: &budget)
            if finalEntries != entries {
                status = .partial(.unavailable)
                notices.append(.init(reason: .unavailable, sourcePath: displayPath))
            }
        } catch let failure as SecureReadFailure {
            status = .partial(failure.reason)
            notices.append(.init(reason: failure.reason, sourcePath: displayPath))
        } catch {
            status = .partial(.unavailable)
            notices.append(.init(reason: .unavailable, sourcePath: displayPath))
        }
        if relativeDirectory.isEmpty, status == .complete {
            do {
                let verification = try behaviorTreeMetadataSnapshot(
                    directoryDescriptor: directoryDescriptor,
                    relativeDirectory: "",
                    depth: 0,
                    budget: &budget
                )
                if verification != nodes.sorted(by: { $0.path < $1.path }) {
                    status = .partial(.unavailable)
                    notices.append(.init(reason: .unavailable, sourcePath: displayPath))
                }
            } catch let failure as SecureReadFailure {
                status = .partial(failure.reason)
                notices.append(.init(reason: failure.reason, sourcePath: displayPath))
            } catch {
                status = .partial(.unavailable)
                notices.append(.init(reason: .unavailable, sourcePath: displayPath))
            }
        }
        return .init(
            files: files.sorted { $0.path < $1.path },
            nodes: nodes.sorted { $0.path < $1.path },
            status: status
        )
    }

    /// Re-enumerates a captured behavior tree after traversal without reading file bytes again.
    private func behaviorTreeMetadataSnapshot(
        directoryDescriptor: Int32,
        relativeDirectory: String,
        depth: Int,
        budget: inout ScanBudget
    ) throws -> [BehaviorTreeNode] {
        guard depth <= limits.maximumDepth else { throw SecureReadFailure.depthLimit }
        let entries = try SecureDescriptorIO.entries(in: directoryDescriptor, budget: &budget)
        var nodes = entries.map { entry in
            BehaviorTreeNode(
                path: relativeDirectory.isEmpty ? entry.name : relativeDirectory + "/" + entry.name,
                kind: entry.kind,
                identity: entry.identity
            )
        }
        for entry in entries where entry.kind == .directory {
            let childRelative = relativeDirectory.isEmpty ? entry.name : relativeDirectory + "/" + entry.name
            switch SecureDescriptorIO.openChildDirectory(
                named: entry.name,
                beneath: directoryDescriptor,
                expectedIdentity: entry.identity
            ) {
            case let .success(childDescriptor):
                let childNodes: [BehaviorTreeNode]
                do {
                    defer { Darwin.close(childDescriptor) }
                    childNodes = try behaviorTreeMetadataSnapshot(
                        directoryDescriptor: childDescriptor,
                        relativeDirectory: childRelative,
                        depth: depth + 1,
                        budget: &budget
                    )
                }
                nodes += childNodes
            case let .failure(failure):
                throw failure
            }
        }
        return nodes.sorted { $0.path < $1.path }
    }

    /// Reads Codex MCP declarations; plugin override tables are not an installation registry.
    private func scanCodexConfig(
        homeDescriptor: Int32,
        budget: inout ScanBudget,
        items: inout [CapabilityInventoryItem],
        sources: inout [CapabilitySourceRecord],
        notices: inout [CapabilityScanNotice]
    ) {
        let relativePath = ".codex/config.toml"
        let displayPath = homeDirectory.appendingPathComponent(relativePath).path
        guard let data = readSource(
            relativePath,
            displayPath: displayPath,
            kind: .mcpServer,
            beneath: homeDescriptor,
            budget: &budget,
            sources: &sources,
            notices: &notices
        ), let text = String(data: data, encoding: .utf8) else {
            if sources.last?.sourcePath == displayPath, sources.last?.status == .complete {
                sources[sources.count - 1] = .init(sourcePath: displayPath, kind: .mcpServer, status: .partial(.malformedUTF8))
                notices.append(.init(reason: .malformedUTF8, sourcePath: displayPath))
            }
            return
        }
        if Self.hasDuplicateTOMLDeclarations(text) {
            sources[sources.count - 1] = .init(sourcePath: displayPath, kind: .mcpServer, status: .partial(.malformedTOML))
            notices.append(.init(reason: .malformedTOML, sourcePath: displayPath))
            return
        }

        let parseResult = TOMLReader.parseWithDiagnostics(text)
        if !parseResult.isComplete {
            markSourcePartial(
                displayPath,
                kind: .mcpServer,
                reason: .malformedTOML,
                sources: &sources,
                notices: &notices
            )
        }
        let serversInConfig = CodexConfigReader.servers(in: parseResult.table)
        for server in serversInConfig {
            items.append(mcpItem(
                name: server.name,
                consumer: .codex,
                sourcePath: displayPath + "#/mcp_servers/" + Self.pointerComponent(server.name),
                scope: "user",
                repositoryUsage: [],
                transport: .infer(type: nil, url: server.url, command: server.command),
                secretNames: server.referencedEnvVarNames + server.inlineEnvKeys,
                headerNames: [],
                activationState: parseResult.isComplete
                    ? (server.isEnabled ? .enabled : .disabled)
                    : .unknown,
                canonicalFingerprint: nil,
                sourceStatus: .partial(.behaviorDefinitionUnavailable)
            ))
        }
        if !serversInConfig.isEmpty {
            markSourcePartial(
                displayPath,
                kind: .mcpServer,
                reason: .behaviorDefinitionUnavailable,
                sources: &sources,
                notices: &notices
            )
        }
    }

    /// Detects Claude's exclusive system MCP policy so incomplete coverage remains visible.
    ///
    /// v1 deliberately does not interpret managed policy filters. Presence or an unreadable
    /// policy path is recorded explicitly; all Claude MCP activation remains unknown in v1.
    private func detectExclusiveClaudeManagedMCP(
        budget: inout ScanBudget,
        sources: inout [CapabilitySourceRecord],
        notices: inout [CapabilityScanNotice]
    ) -> Bool {
        let directoryPath = claudeManagedMCPDirectory.path
        let sourcePath = claudeManagedMCPDirectory.appendingPathComponent("managed-mcp.json").path
        var directoryInfo = Darwin.stat()
        let statResult = directoryPath.withCString { Darwin.lstat($0, &directoryInfo) }
        guard statResult == 0 else {
            guard errno != ENOENT else { return false }
            sources.append(.init(sourcePath: sourcePath, kind: .mcpServer, status: .partial(.unavailable)))
            notices.append(.init(reason: .unavailable, sourcePath: sourcePath))
            return true
        }
        let directoryType = directoryInfo.st_mode & S_IFMT
        guard directoryType == S_IFDIR else {
            let reason: CapabilitySourceReason = directoryType == S_IFLNK ? .symbolicLink : .specialFile
            sources.append(.init(sourcePath: sourcePath, kind: .mcpServer, status: .refused(reason)))
            notices.append(.init(reason: reason, sourcePath: sourcePath))
            return true
        }
        guard let descriptor = SecureDescriptorIO.openAbsoluteDirectory(directoryPath) else {
            sources.append(.init(sourcePath: sourcePath, kind: .mcpServer, status: .partial(.unavailable)))
            notices.append(.init(reason: .unavailable, sourcePath: sourcePath))
            return true
        }
        defer { Darwin.close(descriptor) }
        do {
            _ = try SecureDescriptorIO.readFile(
                relativePath: "managed-mcp.json",
                beneath: descriptor,
                budget: &budget
            )
            sources.append(.init(
                sourcePath: sourcePath,
                kind: .mcpServer,
                status: .partial(.behaviorDefinitionUnavailable)
            ))
            notices.append(.init(reason: .behaviorDefinitionUnavailable, sourcePath: sourcePath))
            return true
        } catch SecureReadFailure.missing {
            return false
        } catch let failure as SecureReadFailure {
            let status: CapabilitySourceStatus = failure == .symbolicLink || failure == .specialFile
                ? .refused(failure.reason) : .partial(failure.reason)
            sources.append(.init(sourcePath: sourcePath, kind: .mcpServer, status: status))
            notices.append(.init(reason: failure.reason, sourcePath: sourcePath))
            return true
        } catch {
            sources.append(.init(sourcePath: sourcePath, kind: .mcpServer, status: .partial(.unavailable)))
            notices.append(.init(reason: .unavailable, sourcePath: sourcePath))
            return true
        }
    }

    /// Reads Claude's strict JSON config and descriptor-bound project-local MCP sources.
    private func scanClaudeConfiguration(
        homeDescriptor: Int32,
        budget: inout ScanBudget,
        items: inout [CapabilityInventoryItem],
        sources: inout [CapabilitySourceRecord],
        notices: inout [CapabilityScanNotice],
        secretFingerprintKey: SymmetricKey
    ) {
        let relativePath = ".claude.json"
        let displayPath = homeDirectory.appendingPathComponent(relativePath).path
        guard let data = readJSONSource(
            relativePath,
            displayPath: displayPath,
            kind: .mcpServer,
            beneath: homeDescriptor,
            budget: &budget,
            sources: &sources,
            notices: &notices
        ) else { return }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            markSourcePartial(displayPath, kind: .mcpServer, reason: .unsupportedFormat, sources: &sources, notices: &notices)
            return
        }

        if let userServers = root["mcpServers"] as? [String: Any] {
            let extraction = jsonMCPItems(
                userServers,
                consumer: .claudeCode,
                sourcePath: displayPath,
                scope: "user",
                repositoryUsage: [],
                activationState: .unknown,
                secretFingerprintKey: secretFingerprintKey
            )
            items += extraction.items
            if let reason = extraction.incompleteReason {
                markSourcePartial(displayPath, kind: .mcpServer, reason: reason, sources: &sources, notices: &notices)
            }
        } else if root.keys.contains("mcpServers") {
            markSourcePartial(displayPath, kind: .mcpServer, reason: .unsupportedFormat, sources: &sources, notices: &notices)
        }
        let projects: [String: Any]
        if let value = root["projects"] as? [String: Any] {
            projects = value
        } else if root.keys.contains("projects") {
            projects = [:]
            markSourcePartial(displayPath, kind: .mcpServer, reason: .unsupportedFormat, sources: &sources, notices: &notices)
        } else {
            projects = [:]
        }
        for projectPath in projects.keys.sorted() {
            guard budget.consumeRoot() else {
                notices.append(.init(reason: .rootLimit, sourcePath: projectPath))
                sources.append(.init(sourcePath: projectPath, kind: .mcpServer, status: .partial(.rootLimit)))
                break
            }
            if let project = projects[projectPath] as? [String: Any],
               let servers = project["mcpServers"] as? [String: Any] {
                let extraction = jsonMCPItems(
                    servers,
                    consumer: .claudeCode,
                    sourcePath: displayPath,
                    scope: projectPath,
                    repositoryUsage: [projectPath],
                    activationState: .unknown,
                    secretFingerprintKey: secretFingerprintKey
                )
                items += extraction.items
                if let reason = extraction.incompleteReason {
                    markSourcePartial(displayPath, kind: .mcpServer, reason: reason, sources: &sources, notices: &notices)
                }
            } else if let project = projects[projectPath] as? [String: Any], project.keys.contains("mcpServers") {
                markSourcePartial(displayPath, kind: .mcpServer, reason: .unsupportedFormat, sources: &sources, notices: &notices)
            } else if projects[projectPath] as? [String: Any] == nil {
                markSourcePartial(displayPath, kind: .mcpServer, reason: .unsupportedFormat, sources: &sources, notices: &notices)
            }
            _ = scanProjectMCP(
                projectPath: projectPath,
                budget: &budget,
                items: &items,
                sources: &sources,
                notices: &notices,
                secretFingerprintKey: secretFingerprintKey
            )
        }
    }

    /// Reads a project-local `.mcp.json` below an already validated absolute project descriptor.
    private func scanProjectMCP(
        projectPath: String,
        budget: inout ScanBudget,
        items: inout [CapabilityInventoryItem],
        sources: inout [CapabilitySourceRecord],
        notices: inout [CapabilityScanNotice],
        secretFingerprintKey: SymmetricKey
    ) -> Bool {
        let sourcePath = URL(fileURLWithPath: projectPath).appendingPathComponent(".mcp.json").path
        guard let projectDescriptor = SecureDescriptorIO.openAbsoluteDirectory(projectPath) else {
            sources.append(.init(sourcePath: sourcePath, kind: .mcpServer, status: .refused(.symbolicLink)))
            notices.append(.init(reason: .symbolicLink, sourcePath: sourcePath))
            return false
        }
        defer { Darwin.close(projectDescriptor) }
        guard let data = readJSONSource(
            ".mcp.json",
            displayPath: sourcePath,
            kind: .mcpServer,
            beneath: projectDescriptor,
            budget: &budget,
            sources: &sources,
            notices: &notices
        ) else { return true }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            markSourcePartial(sourcePath, kind: .mcpServer, reason: .unsupportedFormat, sources: &sources, notices: &notices)
            return true
        }
        guard let servers = root["mcpServers"] as? [String: Any] else {
            markSourcePartial(sourcePath, kind: .mcpServer, reason: .unsupportedFormat, sources: &sources, notices: &notices)
            return true
        }
        let extraction = jsonMCPItems(
            servers,
            consumer: .claudeCode,
            sourcePath: sourcePath,
            scope: projectPath,
            repositoryUsage: [projectPath],
            activationState: .unknown,
            secretFingerprintKey: secretFingerprintKey
        )
        items += extraction.items
        if let reason = extraction.incompleteReason {
            markSourcePartial(sourcePath, kind: .mcpServer, reason: reason, sources: &sources, notices: &notices)
        }
        return true
    }

    /// Reads Cursor's single authoritative user MCP source.
    private func scanCursorConfiguration(
        homeDescriptor: Int32,
        budget: inout ScanBudget,
        items: inout [CapabilityInventoryItem],
        sources: inout [CapabilitySourceRecord],
        notices: inout [CapabilityScanNotice],
        secretFingerprintKey: SymmetricKey
    ) {
        let relativePath = ".cursor/mcp.json"
        let displayPath = homeDirectory.appendingPathComponent(relativePath).path
        guard let data = readJSONSource(
            relativePath,
            displayPath: displayPath,
            kind: .mcpServer,
            beneath: homeDescriptor,
            budget: &budget,
            sources: &sources,
            notices: &notices
        ) else { return }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            markSourcePartial(displayPath, kind: .mcpServer, reason: .unsupportedFormat, sources: &sources, notices: &notices)
            return
        }
        guard let servers = root["mcpServers"] as? [String: Any] else {
            markSourcePartial(displayPath, kind: .mcpServer, reason: .unsupportedFormat, sources: &sources, notices: &notices)
            return
        }
        let extraction = jsonMCPItems(
            servers,
            consumer: .cursor,
            sourcePath: displayPath,
            scope: "user",
            repositoryUsage: [],
            activationState: .unknown,
            secretFingerprintKey: secretFingerprintKey
        )
        items += extraction.items
        if let reason = extraction.incompleteReason {
            markSourcePartial(displayPath, kind: .mcpServer, reason: reason, sources: &sources, notices: &notices)
        }
    }

    /// Reads only Claude's authoritative installed-plugin registry and validates install roots.
    private func scanClaudePlugins(
        homeDescriptor: Int32,
        budget: inout ScanBudget,
        items: inout [CapabilityInventoryItem],
        sources: inout [CapabilitySourceRecord],
        notices: inout [CapabilityScanNotice],
        secretFingerprintKey: SymmetricKey
    ) {
        let userActivationStates = readClaudeUserPluginActivationStates(
            homeDescriptor: homeDescriptor,
            budget: &budget,
            sources: &sources,
            notices: &notices
        )
        let relativePath = ".claude/plugins/installed_plugins.json"
        let displayPath = homeDirectory.appendingPathComponent(relativePath).path
        guard let data = readJSONSource(
            relativePath,
            displayPath: displayPath,
            kind: .plugin,
            beneath: homeDescriptor,
            budget: &budget,
            sources: &sources,
            notices: &notices
        ) else { return }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            markSourcePartial(displayPath, kind: .plugin, reason: .unsupportedFormat, sources: &sources, notices: &notices)
            return
        }
        guard let plugins = root["plugins"] as? [String: Any] else {
            markSourcePartial(displayPath, kind: .plugin, reason: .unsupportedFormat, sources: &sources, notices: &notices)
            return
        }
        let registrySchemaComplete = Set(root.keys).isSubset(of: ["version", "plugins"])
            && (root["version"] == nil || root["version"] is NSNumber)
        if !registrySchemaComplete {
            markSourcePartial(displayPath, kind: .plugin, reason: .unsupportedFormat, sources: &sources, notices: &notices)
        }

        for identity in plugins.keys.sorted() {
            guard let occurrences = plugins[identity] as? [[String: Any]] else {
                markSourcePartial(displayPath, kind: .plugin, reason: .unsupportedFormat, sources: &sources, notices: &notices)
                continue
            }
            for (index, occurrence) in occurrences.enumerated() {
                let installPath = occurrence["installPath"] as? String
                let hasRootBudget = installPath == nil || budget.consumeRoot()
                let installStatus: CapabilitySourceStatus = hasRootBudget
                    ? validateClaudeInstallPath(installPath, homeDescriptor: homeDescriptor)
                    : .partial(.rootLimit)
                if !hasRootBudget {
                    notices.append(.init(reason: .rootLimit, sourcePath: displayPath))
                }
                if case let .refused(reason) = installStatus {
                    notices.append(.init(reason: reason, sourcePath: displayPath))
                }
                let scope = Self.safeScope(occurrence["scope"] as? String)
                var itemStatus = installStatus
                var fingerprint: CapabilityFingerprint?
                if installStatus == .complete,
                   let installPath,
                   registrySchemaComplete,
                   let canonicalRegistry = Self.canonicalPluginRegistryOccurrence(
                       occurrence,
                       registryVersion: root["version"]
                   ) {
                    let candidate = URL(fileURLWithPath: installPath, relativeTo: homeDirectory).standardizedFileURL
                    let relative = String(candidate.path.dropFirst(homeDirectory.path.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    switch SecureDescriptorIO.openDirectory(relative, beneath: homeDescriptor) {
                    case let .success(descriptor):
                        let tree = skillTreeSnapshot(
                            directoryDescriptor: descriptor,
                            relativeDirectory: "",
                            displayPath: candidate.path,
                            depth: 0,
                            budget: &budget,
                            notices: &notices
                        )
                        Darwin.close(descriptor)
                        if tree.status == .complete, !tree.files.isEmpty {
                            var canonical = Data("R\(canonicalRegistry.count):".utf8)
                            canonical.append(canonicalRegistry)
                            let treeData = Self.canonicalBehaviorTree(tree.files, nodes: tree.nodes)
                            canonical.append(Data("T\(treeData.count):".utf8))
                            canonical.append(treeData)
                            fingerprint = CapabilityFingerprint.secretBearingContent(
                                schemaVersion: "claude-installed-plugin-v1",
                                data: canonical,
                                key: secretFingerprintKey
                            )
                            itemStatus = .complete
                        } else {
                            itemStatus = tree.status == .complete
                                ? .partial(.behaviorDefinitionUnavailable) : tree.status
                        }
                    case let .failure(failure):
                        itemStatus = .partial(failure.reason)
                    }
                } else if installStatus == .complete {
                    itemStatus = .partial(.unsupportedFormat)
                }
                if itemStatus != .complete {
                    let reason = itemStatus.reason ?? .behaviorDefinitionUnavailable
                    markSourcePartial(displayPath, kind: .plugin, reason: reason, sources: &sources, notices: &notices)
                }
                items.append(CapabilityInventoryItem(
                    kind: .plugin,
                    consumer: .claudeCode,
                    runtimeIdentity: Self.safeIdentity(identity, fallback: "unknown-plugin-\(index)"),
                    sourcePath: displayPath + "#/plugins/" + Self.pointerComponent(identity) + "/\(index)",
                    effectiveScope: scope,
                    repositoryUsage: Self.repositoryUsage(from: occurrence, scope: scope),
                    version: Self.safeVersion(occurrence["version"] as? String),
                    summary: nil,
                    permissionNames: Self.permissionNames(fromJSON: occurrence),
                    secretReferenceNames: Self.secretReferenceNames(inJSON: occurrence),
                    registrationState: .installed,
                    activationState: scope == "user"
                        ? userActivationStates[identity] ?? .unknown
                        : .unknown,
                    sourceStatus: itemStatus,
                    canonicalFingerprint: fingerprint
                ))
            }
        }
    }

    /// Reads user-scope Claude plugin activation without inventing project or managed overrides.
    private func readClaudeUserPluginActivationStates(
        homeDescriptor: Int32,
        budget: inout ScanBudget,
        sources: inout [CapabilitySourceRecord],
        notices: inout [CapabilityScanNotice]
    ) -> [String: CapabilityActivationState] {
        let relativePath = ".claude/settings.json"
        let displayPath = homeDirectory.appendingPathComponent(relativePath).path
        guard let data = readJSONSource(
            relativePath,
            displayPath: displayPath,
            kind: .plugin,
            beneath: homeDescriptor,
            budget: &budget,
            sources: &sources,
            notices: &notices
        ) else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            markSourcePartial(displayPath, kind: .plugin, reason: .unsupportedFormat, sources: &sources, notices: &notices)
            return [:]
        }
        guard let enabledPlugins = root["enabledPlugins"] as? [String: Any] else {
            if root.keys.contains("enabledPlugins") {
                markSourcePartial(displayPath, kind: .plugin, reason: .unsupportedFormat, sources: &sources, notices: &notices)
            }
            return [:]
        }
        var result: [String: CapabilityActivationState] = [:]
        for (identity, value) in enabledPlugins {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else {
                markSourcePartial(displayPath, kind: .plugin, reason: .unsupportedFormat, sources: &sources, notices: &notices)
                continue
            }
            result[identity.precomposedStringWithCanonicalMapping] = number.boolValue ? .enabled : .disabled
        }
        return result
    }

    /// Validates a registry install path without crawling unrelated cache entries.
    private func validateClaudeInstallPath(_ path: String?, homeDescriptor: Int32) -> CapabilitySourceStatus {
        guard let path, !path.isEmpty else { return .partial(.behaviorDefinitionUnavailable) }
        let candidate = URL(fileURLWithPath: path, relativeTo: homeDirectory).standardizedFileURL
        let expectedRoot = homeDirectory.appendingPathComponent(".claude/plugins", isDirectory: true).standardizedFileURL
        guard candidate.path == expectedRoot.path || candidate.path.hasPrefix(expectedRoot.path + "/") else {
            return .refused(.pathEscape)
        }
        let relative = String(candidate.path.dropFirst(homeDirectory.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch SecureDescriptorIO.openDirectory(relative, beneath: homeDescriptor) {
        case let .success(descriptor):
            Darwin.close(descriptor)
            return .complete
        case .failure(.missing):
            return .partial(.unavailable)
        case let .failure(failure):
            return .refused(failure.reason)
        }
    }

    /// Converts strict JSON MCP dictionaries into schema-validated, exact occurrences when possible.
    private func jsonMCPItems(
        _ servers: [String: Any],
        consumer: CapabilityConsumer,
        sourcePath: String,
        scope: String,
        repositoryUsage: [String],
        activationState: CapabilityActivationState,
        secretFingerprintKey: SymmetricKey
    ) -> JSONMCPExtraction {
        var items: [CapabilityInventoryItem] = []
        var incompleteReason: CapabilitySourceReason?
        for name in servers.keys.sorted() {
            guard let server = servers[name] as? [String: Any] else {
                incompleteReason = .unsupportedFormat
                continue
            }
            let validation = Self.validateJSONMCPServer(server)
            if validation.reason != nil { incompleteReason = validation.reason }
            let type = server["type"] as? String
            let url = server["url"] as? String
            let command = server["command"] as? String
            let envKeys = (server["env"] as? [String: Any])?.keys.filter(Self.isSafeSecretName) ?? []
            let headerKeys = (server["headers"] as? [String: Any])?.keys.filter(Self.isSafeHeaderName) ?? []
            let fingerprint = validation.canonicalData.map {
                CapabilityFingerprint.secretBearingContent(
                    schemaVersion: "json-mcp-server-v1",
                    data: $0,
                    key: secretFingerprintKey
                )
            }
            items.append(mcpItem(
                name: name,
                consumer: consumer,
                sourcePath: sourcePath + "#/mcpServers/" + Self.pointerComponent(name),
                scope: scope,
                repositoryUsage: repositoryUsage,
                transport: .infer(type: type, url: url, command: command),
                secretNames: envKeys,
                headerNames: headerKeys,
                activationState: activationState,
                canonicalFingerprint: fingerprint,
                sourceStatus: validation.reason.map { .partial($0) } ?? .complete
            ))
        }
        return .init(items: items, incompleteReason: incompleteReason)
    }

    /// Builds an MCP occurrence while explicitly withholding an incomplete exact fingerprint.
    private func mcpItem(
        name: String,
        consumer: CapabilityConsumer,
        sourcePath: String,
        scope: String,
        repositoryUsage: [String],
        transport: MCPServerTransport,
        secretNames: [String],
        headerNames: [String],
        activationState: CapabilityActivationState,
        canonicalFingerprint: CapabilityFingerprint?,
        sourceStatus: CapabilitySourceStatus
    ) -> CapabilityInventoryItem {
        CapabilityInventoryItem(
            kind: .mcpServer,
            consumer: consumer,
            runtimeIdentity: Self.safeIdentity(name, fallback: "unknown-server"),
            sourcePath: sourcePath,
            effectiveScope: scope,
            repositoryUsage: repositoryUsage,
            summary: Self.transportSummary(transport: transport),
            secretReferenceNames: secretNames.filter(Self.isSafeSecretName),
            headerNames: headerNames.filter(Self.isSafeHeaderName),
            registrationState: .configured,
            activationState: activationState,
            sourceStatus: sourceStatus,
            canonicalFingerprint: canonicalFingerprint
        )
    }

    /// Reads one source and records missing, refused, partial, or complete status.
    private func readSource(
        _ relativePath: String,
        displayPath: String,
        kind: CapabilityKind?,
        beneath rootDescriptor: Int32,
        budget: inout ScanBudget,
        sources: inout [CapabilitySourceRecord],
        notices: inout [CapabilityScanNotice]
    ) -> Data? {
        do {
            let data = try SecureDescriptorIO.readFile(
                relativePath: relativePath,
                beneath: rootDescriptor,
                budget: &budget,
                afterRead: { testingAfterDescriptorRead?(relativePath) }
            )
            sources.append(.init(sourcePath: displayPath, kind: kind, status: .complete))
            return data
        } catch let failure as SecureReadFailure {
            let status: CapabilitySourceStatus
            switch failure {
            case .missing:
                status = .missing
            case .symbolicLink, .specialFile:
                status = .refused(failure.reason)
            case .fileByteLimit, .aggregateByteLimit, .entryLimit, .depthLimit, .unavailable:
                status = .partial(failure.reason)
            }
            sources.append(.init(sourcePath: displayPath, kind: kind, status: status))
            if failure != .missing { notices.append(.init(reason: failure.reason, sourcePath: displayPath)) }
            return nil
        } catch {
            sources.append(.init(sourcePath: displayPath, kind: kind, status: .refused(.unavailable)))
            notices.append(.init(reason: .unavailable, sourcePath: displayPath))
            return nil
        }
    }

    /// Reads one source and rejects malformed syntax or duplicate JSON object keys.
    private func readJSONSource(
        _ relativePath: String,
        displayPath: String,
        kind: CapabilityKind?,
        beneath rootDescriptor: Int32,
        budget: inout ScanBudget,
        sources: inout [CapabilitySourceRecord],
        notices: inout [CapabilityScanNotice]
    ) -> Data? {
        guard let data = readSource(
            relativePath,
            displayPath: displayPath,
            kind: kind,
            beneath: rootDescriptor,
            budget: &budget,
            sources: &sources,
            notices: &notices
        ) else { return nil }
        guard String(data: data, encoding: .utf8) != nil else {
            sources[sources.count - 1] = .init(
                sourcePath: displayPath,
                kind: kind,
                status: .partial(.malformedUTF8)
            )
            notices.append(.init(reason: .malformedUTF8, sourcePath: displayPath))
            return nil
        }
        switch StrictJSONValidator.validate(
            data,
            maximumDepth: limits.maximumDepth,
            maximumMembers: budget.remainingEntries
        ) {
        case let .valid(memberCount):
            do {
                try budget.consume(entries: memberCount)
            } catch let failure as SecureReadFailure {
                markSourcePartial(displayPath, kind: kind, reason: failure.reason, sources: &sources, notices: &notices)
                return nil
            } catch {
                markSourcePartial(displayPath, kind: kind, reason: .unavailable, sources: &sources, notices: &notices)
                return nil
            }
        case let .invalid(reason):
            markSourcePartial(displayPath, kind: kind, reason: reason, sources: &sources, notices: &notices)
            return nil
        }
        return data
    }

    /// Downgrades one previously read source without losing a stronger refusal or earlier limit reason.
    private func markSourcePartial(
        _ sourcePath: String,
        kind: CapabilityKind?,
        reason: CapabilitySourceReason,
        sources: inout [CapabilitySourceRecord],
        notices: inout [CapabilityScanNotice]
    ) {
        if let index = sources.lastIndex(where: { $0.sourcePath == sourcePath }) {
            switch sources[index].status {
            case .complete:
                sources[index] = .init(sourcePath: sourcePath, kind: kind, status: .partial(reason))
            case .missing, .partial, .refused, .unsupported:
                break
            }
        } else {
            sources.append(.init(sourcePath: sourcePath, kind: kind, status: .partial(reason)))
        }
        notices.append(.init(reason: reason, sourcePath: sourcePath))
    }

    /// Supplies deterministic inventory ordering.
    private static func itemOrder(_ lhs: CapabilityInventoryItem, _ rhs: CapabilityInventoryItem) -> Bool {
        (lhs.kind, lhs.consumer, lhs.effectiveScope, lhs.runtimeIdentity, lhs.sourcePath, lhs.id)
            < (rhs.kind, rhs.consumer, rhs.effectiveScope, rhs.runtimeIdentity, rhs.sourcePath, rhs.id)
    }

    /// Supplies deterministic source ordering.
    private static func sourceOrder(_ lhs: CapabilitySourceRecord, _ rhs: CapabilitySourceRecord) -> Bool {
        (lhs.sourcePath, lhs.kind?.rawValue ?? "") < (rhs.sourcePath, rhs.kind?.rawValue ?? "")
    }

    /// Supplies deterministic notice ordering.
    private static func noticeOrder(_ lhs: CapabilityScanNotice, _ rhs: CapabilityScanNotice) -> Bool {
        (lhs.reason.rawValue, lhs.sourcePath) < (rhs.reason.rawValue, rhs.sourcePath)
    }

}

/// Extracts a conservative reason from non-complete occurrence status.
private nonisolated extension CapabilitySourceStatus {
    var reason: CapabilitySourceReason? {
        switch self {
        case .missing, .complete:
            nil
        case let .partial(reason), let .refused(reason), let .unsupported(reason):
            reason
        }
    }
}

/// Mutable aggregate scan budget kept local to one scanner invocation.
private nonisolated struct ScanBudget {
    /// Immutable scan limits.
    let limits: CapabilityHygieneScanner.Limits
    /// Aggregate bytes consumed.
    private(set) var bytes = 0
    /// Aggregate entries consumed.
    private(set) var entries = 0
    /// External roots consumed.
    private(set) var roots = 0

    /// Reserves bytes before a descriptor-bound read.
    mutating func consume(bytes count: Int) throws {
        guard count >= 0, count <= limits.maximumFileBytes else { throw SecureReadFailure.fileByteLimit }
        guard count <= limits.maximumAggregateBytes else { throw SecureReadFailure.aggregateByteLimit }
        guard bytes <= limits.maximumAggregateBytes - count else { throw SecureReadFailure.aggregateByteLimit }
        bytes += count
    }

    /// Reserves one enumerated entry.
    mutating func consumeEntry() throws {
        guard entries < limits.maximumEntries else { throw SecureReadFailure.entryLimit }
        entries += 1
    }

    /// Reserves parser members against the same aggregate entry budget as filesystem entries.
    mutating func consume(entries count: Int) throws {
        guard count >= 0, count <= remainingEntries else { throw SecureReadFailure.entryLimit }
        entries += count
    }

    /// Remaining aggregate entries available to structured parsers.
    var remainingEntries: Int { max(0, limits.maximumEntries - entries) }

    /// Reserves one external project/provider root.
    mutating func consumeRoot() -> Bool {
        guard roots < limits.maximumRoots else { return false }
        roots += 1
        return true
    }
}

/// Descriptor-bound read failure with a stable source-completeness reason.
private nonisolated enum SecureReadFailure: Error, Equatable {
    /// Entry is absent.
    case missing
    /// Symbolic-link traversal was refused.
    case symbolicLink
    /// Entry is neither a regular file nor directory where required.
    case specialFile
    /// Per-file byte limit was exceeded.
    case fileByteLimit
    /// Aggregate byte limit was exceeded.
    case aggregateByteLimit
    /// Entry limit was exceeded.
    case entryLimit
    /// Tree traversal exceeded the configured depth.
    case depthLimit
    /// Descriptor operation failed.
    case unavailable

    /// Public completeness reason for the failure.
    var reason: CapabilitySourceReason {
        switch self {
        case .missing: .unavailable
        case .symbolicLink: .symbolicLink
        case .specialFile: .specialFile
        case .fileByteLimit: .fileByteLimit
        case .aggregateByteLimit: .aggregateByteLimit
        case .entryLimit: .entryLimit
        case .depthLimit: .depthLimit
        case .unavailable: .unavailable
        }
    }
}

/// Filesystem shape captured with `fstatat(..., AT_SYMLINK_NOFOLLOW)`.
private nonisolated enum SecureEntryKind: Equatable {
    /// Regular file.
    case regularFile
    /// Directory.
    case directory
    /// Symbolic link.
    case symbolicLink
    /// FIFO, socket, device, or other unsupported entry.
    case special
}

/// One descriptor-enumerated directory entry.
private nonisolated struct SecureDirectoryEntry: Equatable {
    /// Single path component.
    let name: String
    /// Non-followed filesystem shape.
    let kind: SecureEntryKind
    /// Stable metadata used to detect replacement or mutation during traversal.
    let identity: SecureFileIdentity
}

/// Descriptor metadata compared before and after reads and directory snapshots.
private nonisolated struct SecureFileIdentity: Equatable {
    /// Device containing the inode.
    let device: UInt64
    /// Inode number.
    let inode: UInt64
    /// File mode including type and executable bits.
    let mode: UInt32
    /// Byte size for regular files.
    let size: Int64
    /// Modification timestamp at nanosecond precision.
    let modificationSeconds: Int64
    /// Modification timestamp nanoseconds.
    let modificationNanoseconds: Int64
    /// Metadata-change timestamp at nanosecond precision.
    let changeSeconds: Int64
    /// Metadata-change timestamp nanoseconds.
    let changeNanoseconds: Int64

    /// Captures only metadata relevant to replacement and content/mode mutation.
    init(_ info: Darwin.stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        mode = UInt32(info.st_mode)
        size = Int64(info.st_size)
        modificationSeconds = Int64(info.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changeSeconds = Int64(info.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }
}

/// One descriptor-bound regular-file snapshot.
private nonisolated struct SecureFileSnapshot {
    /// Exact bytes read from the held descriptor.
    let data: Data
    /// Behavior-bearing file mode and type.
    let mode: UInt32
}

/// POSIX helpers that keep every read bound to held no-follow descriptors.
private nonisolated enum SecureDescriptorIO {
    /// Opens an absolute directory one component at a time without following links.
    static func openAbsoluteDirectory(_ path: String) -> Int32? {
        guard path.hasPrefix("/") else { return nil }
        let path = expandedMacOSSystemAlias(path)
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        for component in path.split(separator: "/").map(String.init) {
            let next = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            }
            Darwin.close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }
        return descriptor
    }

    /// Expands only immutable macOS root aliases before no-follow descriptor traversal.
    private static func expandedMacOSSystemAlias(_ path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    /// Opens a relative directory chain beneath a held root descriptor.
    static func openDirectory(_ path: String, beneath root: Int32) -> Result<Int32, SecureReadFailure> {
        var descriptor = Darwin.dup(root)
        guard descriptor >= 0 else { return .failure(.unavailable) }
        for component in path.split(separator: "/").map(String.init) {
            guard validComponent(component) else {
                Darwin.close(descriptor)
                return .failure(.symbolicLink)
            }
            let next = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            }
            let savedErrno = errno
            Darwin.close(descriptor)
            guard next >= 0 else {
                return .failure(savedErrno == ENOENT ? .missing : (savedErrno == ELOOP ? .symbolicLink : .unavailable))
            }
            descriptor = next
        }
        return .success(descriptor)
    }

    /// Opens one child directory beneath a held parent descriptor.
    static func openChildDirectory(
        named name: String,
        beneath parent: Int32,
        expectedIdentity: SecureFileIdentity? = nil
    ) -> Result<Int32, SecureReadFailure> {
        guard validComponent(name) else { return .failure(.symbolicLink) }
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            return .failure(errno == ELOOP ? .symbolicLink : (errno == ENOENT ? .missing : .unavailable))
        }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              expectedIdentity.map({ SecureFileIdentity(info) == $0 }) ?? true else {
            Darwin.close(descriptor)
            return .failure(.unavailable)
        }
        return .success(descriptor)
    }

    /// Reads one relative regular file through descriptor-held parent directories.
    static func readFile(
        relativePath: String,
        beneath root: Int32,
        budget: inout ScanBudget,
        afterRead: (@Sendable () -> Void)? = nil
    ) throws -> Data {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let leaf = components.last, components.allSatisfy(validComponent) else {
            throw SecureReadFailure.symbolicLink
        }
        var parent = Darwin.dup(root)
        guard parent >= 0 else { throw SecureReadFailure.unavailable }
        for component in components.dropLast() {
            let next = component.withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            }
            let savedErrno = errno
            Darwin.close(parent)
            guard next >= 0 else {
                throw savedErrno == ENOENT ? SecureReadFailure.missing
                    : (savedErrno == ELOOP ? SecureReadFailure.symbolicLink : SecureReadFailure.unavailable)
            }
            parent = next
        }
        defer { Darwin.close(parent) }
        return try readFile(named: leaf, beneath: parent, budget: &budget, afterRead: afterRead)
    }

    /// Opens and reads one regular leaf with `O_NOFOLLOW`; special files are never consumed.
    static func readFile(
        named name: String,
        beneath parent: Int32,
        budget: inout ScanBudget,
        afterRead: (@Sendable () -> Void)? = nil
    ) throws -> Data {
        try readFileSnapshot(named: name, beneath: parent, budget: &budget, afterRead: afterRead).data
    }

    /// Reads a regular file and returns exact bytes plus stable behavior-bearing mode.
    static func readFileSnapshot(
        named name: String,
        beneath parent: Int32,
        expectedIdentity: SecureFileIdentity? = nil,
        budget: inout ScanBudget,
        afterRead: (@Sendable () -> Void)? = nil
    ) throws -> SecureFileSnapshot {
        guard validComponent(name) else { throw SecureReadFailure.symbolicLink }
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw errno == ENOENT ? SecureReadFailure.missing
                : (errno == ELOOP ? SecureReadFailure.symbolicLink : SecureReadFailure.unavailable)
        }
        defer { Darwin.close(descriptor) }
        var beforeInfo = Darwin.stat()
        guard Darwin.fstat(descriptor, &beforeInfo) == 0 else { throw SecureReadFailure.unavailable }
        guard (beforeInfo.st_mode & S_IFMT) == S_IFREG else { throw SecureReadFailure.specialFile }
        let before = SecureFileIdentity(beforeInfo)
        let expected = Int(beforeInfo.st_size)
        try budget.consume(bytes: expected)
        var data = Data()
        data.reserveCapacity(expected)
        var buffer = [UInt8](repeating: 0, count: min(16 * 1024, max(expected + 1, 1)))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw SecureReadFailure.unavailable }
            if count == 0 { break }
            guard count <= expected - data.count else { throw SecureReadFailure.unavailable }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == expected else { throw SecureReadFailure.unavailable }
        afterRead?()
        var afterInfo = Darwin.stat()
        guard Darwin.fstat(descriptor, &afterInfo) == 0,
              SecureFileIdentity(afterInfo) == before,
              expectedIdentity.map({ before == $0 }) ?? true else { throw SecureReadFailure.unavailable }
        return .init(data: data, mode: UInt32(afterInfo.st_mode))
    }

    /// Enumerates names and lstat-style entry types through a duplicate directory descriptor.
    static func entries(in descriptor: Int32, budget: inout ScanBudget) throws -> [SecureDirectoryEntry] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, Darwin.lseek(duplicate, 0, SEEK_SET) >= 0,
              let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw SecureReadFailure.unavailable
        }
        defer { Darwin.closedir(directory) }
        var result: [SecureDirectoryEntry] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw SecureReadFailure.unavailable }
            guard name != ".", name != ".." else { continue }
            guard validComponent(name) else { throw SecureReadFailure.symbolicLink }
            try budget.consumeEntry()
            var info = Darwin.stat()
            guard name.withCString({ Darwin.fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw SecureReadFailure.unavailable
            }
            let type = info.st_mode & S_IFMT
            let kind: SecureEntryKind = type == S_IFREG ? .regularFile
                : (type == S_IFDIR ? .directory : (type == S_IFLNK ? .symbolicLink : .special))
            result.append(.init(name: name, kind: kind, identity: SecureFileIdentity(info)))
            errno = 0
        }
        guard errno == 0 else { throw SecureReadFailure.unavailable }
        return result.sorted { $0.name < $1.name }
    }

    /// Accepts one ordinary path component and rejects traversal markers.
    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }
}

/// One complete supporting file in a skill tree.
private nonisolated struct SkillTreeFile: Equatable {
    /// Skill-root-relative path.
    let path: String
    /// POSIX file mode, including type and executable bits.
    let mode: UInt32
    /// Descriptor-read bytes.
    let data: Data
}

/// Skill construction outcome that propagates unreadable or malformed `SKILL.md` to its root.
private nonisolated struct SkillItemResult {
    /// Inventory item when identity metadata could be decoded safely.
    let item: CapabilityInventoryItem?
    /// Complete only when the entire behavior tree and `SKILL.md` were read.
    let status: CapabilitySourceStatus
}

/// One file or directory metadata record in a complete behavior-tree snapshot.
private nonisolated struct BehaviorTreeNode: Equatable {
    /// Root-relative path.
    let path: String
    /// Non-followed filesystem type.
    let kind: SecureEntryKind
    /// Replacement- and mutation-sensitive metadata.
    let identity: SecureFileIdentity
}

/// Bounded tree capture used to decide whether exact skill matching is available.
private nonisolated struct SkillTreeSnapshot: Equatable {
    /// Complete files captured before canonical hashing.
    let files: [SkillTreeFile]
    /// Complete entry metadata captured with the bytes.
    let nodes: [BehaviorTreeNode]
    /// Complete only when every behavior-supporting entry was read safely.
    let status: CapabilitySourceStatus
}

/// MCP extraction outcome with source-level schema completeness.
private nonisolated struct JSONMCPExtraction {
    /// Occurrences that retained a trustworthy runtime identity.
    let items: [CapabilityInventoryItem]
    /// First conservative reason exact matching was unavailable.
    let incompleteReason: CapabilitySourceReason?
}

/// One supported MCP server's canonicalization result.
private nonisolated struct JSONMCPValidation {
    /// Canonical behavior bytes only when all supported fields have valid types.
    let canonicalData: Data?
    /// Conservative reason when canonical behavior is unavailable.
    let reason: CapabilitySourceReason?
}

/// Bounded duplicate-aware JSON validation outcome.
private nonisolated enum StrictJSONValidationResult {
    /// Syntax, duplicate keys, and resource budgets are valid.
    case valid(memberCount: Int)
    /// Stable source reason for rejection.
    case invalid(CapabilitySourceReason)
}

/// Strict JSON syntax validator that rejects duplicate object keys before Foundation parsing.
private nonisolated struct StrictJSONValidator {
    /// Source bytes.
    private let bytes: [UInt8]
    /// Current parser offset.
    private var index = 0
    /// Maximum nested object/array depth.
    private let maximumDepth: Int
    /// Maximum aggregate object members and array elements.
    private let maximumMembers: Int
    /// Members consumed by this document.
    private var memberCount = 0
    /// First resource-limit failure, if any.
    private var failureReason: CapabilitySourceReason?

    /// Validates one complete JSON value with duplicate-key, depth, and member limits.
    static func validate(
        _ data: Data,
        maximumDepth: Int,
        maximumMembers: Int
    ) -> StrictJSONValidationResult {
        var parser = StrictJSONValidator(
            bytes: Array(data),
            maximumDepth: max(0, maximumDepth),
            maximumMembers: max(0, maximumMembers)
        )
        let isValid = parser.parseValue(depth: 0)
            && parser.skipWhitespace()
            && parser.index == parser.bytes.count
        if let reason = parser.failureReason { return .invalid(reason) }
        return isValid ? .valid(memberCount: parser.memberCount) : .invalid(.malformedJSON)
    }

    /// Parses one JSON value recursively.
    private mutating func parseValue(depth: Int) -> Bool {
        guard depth <= maximumDepth else {
            failureReason = .depthLimit
            return false
        }
        guard skipWhitespace(), index < bytes.count else { return false }
        switch bytes[index] {
        case 0x7B: return parseObject(depth: depth)
        case 0x5B: return parseArray(depth: depth)
        case 0x22: return parseString() != nil
        case 0x74: return consume("true")
        case 0x66: return consume("false")
        case 0x6E: return consume("null")
        default: return parseNumber()
        }
    }

    /// Parses one object and rejects semantically duplicate decoded keys.
    private mutating func parseObject(depth: Int) -> Bool {
        index += 1
        var keys = Set<String>()
        guard skipWhitespace() else { return false }
        if consumeByte(0x7D) { return true }
        while true {
            guard registerMember(), let key = parseString(), keys.insert(key).inserted,
                  skipWhitespace(), consumeByte(0x3A), parseValue(depth: depth + 1), skipWhitespace() else {
                return false
            }
            if consumeByte(0x7D) { return true }
            guard consumeByte(0x2C), skipWhitespace() else { return false }
        }
    }

    /// Parses one array.
    private mutating func parseArray(depth: Int) -> Bool {
        index += 1
        guard skipWhitespace() else { return false }
        if consumeByte(0x5D) { return true }
        while true {
            guard registerMember(), parseValue(depth: depth + 1), skipWhitespace() else { return false }
            if consumeByte(0x5D) { return true }
            guard consumeByte(0x2C), skipWhitespace() else { return false }
        }
    }

    /// Accounts one object member or array element before descending further.
    private mutating func registerMember() -> Bool {
        guard memberCount < maximumMembers else {
            failureReason = .entryLimit
            return false
        }
        memberCount += 1
        return true
    }

    /// Parses and decodes one JSON string for duplicate-key comparison.
    private mutating func parseString() -> String? {
        guard index < bytes.count, bytes[index] == 0x22 else { return nil }
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                index += 1
                let raw = Data(bytes[start..<index])
                return (try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])) as? String
            } else if byte < 0x20 {
                return nil
            }
            index += 1
        }
        return nil
    }

    /// Parses a strict JSON number token.
    private mutating func parseNumber() -> Bool {
        let start = index
        if consumeByte(0x2D), index >= bytes.count { return false }
        if consumeByte(0x30) {
            if index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { return false }
        } else {
            guard consumeDigits(minimum: 1) else { return false }
        }
        if consumeByte(0x2E), !consumeDigits(minimum: 1) { return false }
        if index < bytes.count, (bytes[index] == 0x65 || bytes[index] == 0x45) {
            index += 1
            _ = consumeByte(0x2B) || consumeByte(0x2D)
            guard consumeDigits(minimum: 1) else { return false }
        }
        return index > start
    }

    /// Consumes at least the requested count of ASCII digits.
    private mutating func consumeDigits(minimum: Int) -> Bool {
        let start = index
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
        return index - start >= minimum
    }

    /// Consumes one ASCII literal.
    private mutating func consume(_ literal: String) -> Bool {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count,
              Array(bytes[index..<(index + literalBytes.count)]) == literalBytes else { return false }
        index += literalBytes.count
        return true
    }

    /// Consumes one expected byte.
    private mutating func consumeByte(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    /// Advances over JSON whitespace.
    @discardableResult
    private mutating func skipWhitespace() -> Bool {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        return true
    }
}

/// Pure normalization and redaction helpers for static provider metadata.
private nonisolated extension CapabilityHygieneScanner {
    /// Canonicalizes a complete behavior tree with raw bytes and POSIX mode/type metadata.
    static func canonicalBehaviorTree(
        _ files: [SkillTreeFile],
        nodes: [BehaviorTreeNode]
    ) -> Data {
        var result = Data()
        for node in nodes.sorted(by: { $0.path < $1.path }) {
            let path = Data(node.path.utf8)
            result.append(Data("N\(path.count):".utf8))
            result.append(path)
            result.append(Data("M\(node.identity.mode):".utf8))
        }
        for file in files.sorted(by: { $0.path < $1.path }) {
            let path = Data(file.path.utf8)
            result.append(Data("P\(path.count):".utf8))
            result.append(path)
            result.append(Data("M\(file.mode):".utf8))
            result.append(Data("D\(file.data.count):".utf8))
            result.append(file.data)
        }
        return result
    }

    /// Parses flat and list-style skill frontmatter for display-safe metadata only.
    static func skillMetadata(_ text: String) -> [String: String] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var values: [String: String] = [:]
        var currentKey: String?
        for line in lines[1..<end] {
            if let separator = line.firstIndex(of: ":"), !line[..<separator].contains(" ") {
                let key = line[..<separator].lowercased()
                values[key] = unquote(String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces))
                currentKey = key
            } else if let currentKey {
                let value = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
                if !value.isEmpty { values[currentKey, default: ""] += (values[currentKey]?.isEmpty == false ? "," : "") + value }
            }
        }
        return values
    }

    /// Rejects duplicate table names or duplicate keys within one TOML table.
    static func hasDuplicateTOMLDeclarations(_ text: String) -> Bool {
        var tables = Set<String>()
        var keys = Set<String>()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let table = String(line.dropFirst().dropLast())
                if !tables.insert(table).inserted { return true }
                keys = []
            } else if let separator = line.firstIndex(of: "=") {
                let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                if !keys.insert(key).inserted { return true }
            }
        }
        return false
    }

    /// Produces a fixed classification that cannot disclose commands, URLs, or arguments.
    static func transportSummary(transport: MCPServerTransport) -> String {
        transport.displayName
    }

    /// Preserves the provider's exact identity, applying only Unicode canonical composition.
    static func safeIdentity(_ value: String, fallback: String) -> String {
        value.isEmpty ? fallback.precomposedStringWithCanonicalMapping
            : value.precomposedStringWithCanonicalMapping
    }

    /// Returns a conservative scope string.
    static func safeScope(_ value: String?) -> String {
        guard let value else { return "user" }
        let scalars = value.precomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let scope = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty, !scope.contains("=") else { return "user" }
        return String(scope.prefix(1_024))
    }

    /// Validates every behavior-bearing field in the common JSON MCP schema.
    static func validateJSONMCPServer(_ server: [String: Any]) -> JSONMCPValidation {
        let supportedKeys: Set<String> = ["type", "url", "command", "args", "env", "headers"]
        guard Set(server.keys).isSubset(of: supportedKeys) else {
            return .init(canonicalData: nil, reason: .unsupportedFormat)
        }
        for key in ["type", "url", "command"] where server.keys.contains(key) {
            guard server[key] is String else { return .init(canonicalData: nil, reason: .unsupportedFormat) }
        }
        if server.keys.contains("args"), !(server["args"] is [String]) {
            return .init(canonicalData: nil, reason: .unsupportedFormat)
        }
        for key in ["env", "headers"] where server.keys.contains(key) {
            guard let dictionary = server[key] as? [String: Any],
                  dictionary.values.allSatisfy({ $0 is String }) else {
                return .init(canonicalData: nil, reason: .unsupportedFormat)
            }
        }
        guard server["command"] is String || server["url"] is String,
              let canonical = try? JSONSerialization.data(withJSONObject: server, options: [.sortedKeys]) else {
            return .init(canonicalData: nil, reason: .behaviorDefinitionUnavailable)
        }
        return .init(canonicalData: canonical, reason: nil)
    }

    /// Canonicalizes behavior identity while excluding scope, paths, and installation timestamps.
    static func canonicalPluginRegistryOccurrence(
        _ occurrence: [String: Any],
        registryVersion: Any?
    ) -> Data? {
        let supportedKeys: Set<String> = [
            "gitCommitSha",
            "installPath",
            "installedAt",
            "lastUpdated",
            "projectPath",
            "scope",
            "version",
        ]
        guard Set(occurrence.keys).isSubset(of: supportedKeys),
              occurrence["installPath"] is String,
              occurrence.allSatisfy({ _, value in value is String }) else { return nil }
        let behaviorIdentity: [String: Any] = [
            "gitCommitSha": occurrence["gitCommitSha"] ?? NSNull(),
            "version": occurrence["version"] ?? NSNull(),
        ]
        let canonical: [String: Any] = [
            "registryVersion": registryVersion ?? NSNull(),
            "behaviorIdentity": behaviorIdentity,
        ]
        return try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])
    }

    /// Returns conventional bounded version metadata only.
    static func safeVersion(_ value: String?) -> String? {
        guard let value = unquote(value), value.count <= 80,
              value.range(of: #"^[A-Za-z0-9._+\-]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// Extracts permission names from recognized skill metadata.
    static func permissionNames(from metadata: [String: String]) -> [String] {
        uniqueSorted(["allowed-tools", "allowed_tools", "tools", "permissions", "permission"]
            .flatMap { splitNames(metadata[$0]) })
    }

    /// Extracts permission names from recognized plugin registry fields.
    static func permissionNames(fromJSON object: [String: Any]) -> [String] {
        var names: [String] = []
        for key in ["allowedTools", "allowed_tools", "tools", "permissions", "permission"] {
            if let array = object[key] as? [String] { names += array }
            if let dictionary = object[key] as? [String: Any] { names += dictionary.keys }
            if let value = object[key] as? String { names += splitNames(value) }
        }
        return uniqueSorted(names.filter(isSafeReferenceName))
    }

    /// Extracts secret-reference names without retaining referenced values.
    static func secretReferenceNames(in text: String, metadata: [String: String]) -> [String] {
        var names = regexCaptures(#"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#, in: text)
        names += regexCaptures(#"\$([A-Z_][A-Z0-9_]*)\b"#, in: text)
        for (key, value) in metadata where key.contains("secret") || key.contains("env") {
            names += splitNames(value)
        }
        return uniqueSorted(names.filter(isSafeSecretName))
    }

    /// Recursively extracts only reference names from plugin JSON metadata.
    static func secretReferenceNames(inJSON value: Any) -> [String] {
        var names: [String] = []
        func visit(_ value: Any, key: String?) {
            if let dictionary = value as? [String: Any] {
                if let key, ["env", "environment", "secrets", "secretReferences"].contains(key) {
                    names += dictionary.keys.filter(isSafeSecretName)
                }
                for child in dictionary.keys.sorted() { visit(dictionary[child] as Any, key: child) }
            } else if let array = value as? [Any] {
                if let key, ["envNames", "secretNames", "secretReferenceNames"].contains(key) {
                    names += array.compactMap { $0 as? String }.filter(isSafeSecretName)
                }
                array.forEach { visit($0, key: key) }
            } else if let string = value as? String {
                names += secretReferenceNames(in: string, metadata: [:])
            }
        }
        visit(value, key: nil)
        return uniqueSorted(names)
    }

    /// Derives explicit project usage from registry metadata only.
    static func repositoryUsage(from object: [String: Any], scope: String) -> [String] {
        guard scope != "user" else { return [] }
        return uniqueSorted([object["projectPath"] as? String, object["repository"] as? String]
            .compactMap { $0 }
            .map { safeScope($0) }
            .filter { $0 != "user" })
    }

    /// Splits bounded list-style names and excludes values, URLs, and paths.
    static func splitNames(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .components(separatedBy: CharacterSet(charactersIn: ", \t\n"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter(isSafeReferenceName)
    }

    /// Captures one regex group without returning surrounding source text.
    static func regexCaptures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard $0.numberOfRanges > 1, let range = Range($0.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    /// Accepts permission/reference names only.
    static func isSafeReferenceName(_ value: String) -> Bool {
        value.count <= 100
            && value.range(of: #"^[A-Za-z0-9_.:()@*+\-]+$"#, options: .regularExpression) != nil
            && !value.contains("=") && !value.contains("/")
    }

    /// Accepts conventional environment-reference names only.
    static func isSafeSecretName(_ value: String) -> Bool {
        value.count <= 128
            && value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// Accepts bounded RFC 7230 token-style HTTP header names only.
    static func isSafeHeaderName(_ value: String) -> Bool {
        value.count <= 128
            && value.range(
                of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#,
                options: .regularExpression
            ) != nil
    }

    /// Removes matching scalar quotes.
    static func unquote(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let first = trimmed.first, first == trimmed.last,
              first == "\"" || first == "'" else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    /// Escapes a JSON-pointer component used only in value-free source references.
    static func pointerComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    /// Removes duplicate names and applies stable ordering.
    static func uniqueSorted(_ values: [String]) -> [String] { Array(Set(values)).sorted() }
}
