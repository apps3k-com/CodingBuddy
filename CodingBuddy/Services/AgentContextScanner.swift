import Foundation

/// Scans a selected repository for known agent context files without parsing their content.
nonisolated struct AgentContextScanner: Sendable {
    /// Files above this size are flagged because they are costly to feed into agents.
    static let oversizedFileByteThreshold = 64 * 1024

    /// Root folder selected by the user.
    let repositoryURL: URL

    /// Filesystem access used for deterministic local metadata inspection.
    private var fileManager: FileManager { .default }

    /// Creates a scanner for a repository root.
    init(repositoryURL: URL) {
        self.repositoryURL = repositoryURL.standardizedFileURL
    }

    /// Returns discovered entries in a deterministic order.
    func items() -> [AgentContextItem] {
        guard let agents = contextItem(kind: .governance, relativePath: "AGENTS.md", includeMissing: true),
              let claude = contextItem(kind: .governance, relativePath: "CLAUDE.md", includeMissing: true)
        else {
            return []
        }

        let bothGovernanceFilesExist = agents.exists && claude.exists

        var rows = [
            withGovernanceWarnings(agents, missingWarning: .missingAgentsMarkdown, bothExist: bothGovernanceFilesExist),
            withGovernanceWarnings(claude, missingWarning: .missingClaudeMarkdown, bothExist: bothGovernanceFilesExist)
        ]

        if let cursorRules = contextItem(kind: .cursorRules, relativePath: ".cursor/rules", includeMissing: false) {
            rows.append(cursorRules)
        }

        if let mcpConfig = contextItem(kind: .mcpConfig, relativePath: ".mcp.json", includeMissing: false) {
            rows.append(appending(.projectLocalMCPConfigPresent, to: mcpConfig))
        }

        if let codexConfig = contextItem(kind: .codexConfig, relativePath: ".codex/config.toml", includeMissing: false) {
            rows.append(appending(.codexProjectConfigPresent, to: codexConfig))
        } else if let codexDirectory = contextItem(kind: .codexConfig, relativePath: ".codex", includeMissing: false) {
            rows.append(appending(.codexProjectConfigPresent, to: codexDirectory))
        }

        for path in Self.documentationPaths {
            if let item = contextItem(kind: .documentation, relativePath: path, includeMissing: false) {
                rows.append(item)
            }
        }

        return rows
    }

    /// Documentation files that commonly contain developer setup instructions.
    private static let documentationPaths = [
        "README.md",
        "CONTRIBUTING.md",
        "DEVELOPMENT.md",
        "docs/Development-Setup.md",
        "docs/wiki/Development-Setup.md"
    ]

    /// Returns one inspected allowlist entry or a missing placeholder when requested.
    private func contextItem(
        kind: AgentContextKind,
        relativePath: String,
        includeMissing: Bool
    ) -> AgentContextItem? {
        let url = url(for: relativePath)
        if let symlinkItem = symlinkItem(kind: kind, relativePath: relativePath, url: url) {
            return symlinkItem
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            guard includeMissing else { return nil }
            return AgentContextItem(
                relativePath: relativePath,
                url: url,
                kind: kind,
                entryType: .missing,
                byteCount: nil,
                modifiedAt: nil,
                warnings: []
            )
        }

        let metadata = metadata(for: url, isDirectory: isDirectory.boolValue)
        let warnings = metadataWarnings(entryType: metadata.entryType, byteCount: metadata.byteCount)

        return AgentContextItem(
            relativePath: relativePath,
            url: url,
            kind: kind,
            entryType: metadata.entryType,
            byteCount: metadata.byteCount,
            modifiedAt: metadata.modifiedAt,
            warnings: warnings
        )
    }

    /// Returns a symlink entry before file existence checks can follow or hide the target.
    private func symlinkItem(kind: AgentContextKind, relativePath: String, url: URL) -> AgentContextItem? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink
        else { return nil }

        let byteCount = (attributes[.size] as? NSNumber).map(\.intValue)
        let modifiedAt = attributes[.modificationDate] as? Date

        return AgentContextItem(
            relativePath: relativePath,
            url: url,
            kind: kind,
            entryType: .symlink,
            byteCount: byteCount,
            modifiedAt: modifiedAt,
            warnings: metadataWarnings(entryType: .symlink, byteCount: byteCount)
        )
    }

    /// Resolves one static allowlist path under the selected root.
    private func url(for relativePath: String) -> URL {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(repositoryURL) { url, pathComponent in
                url.appendingPathComponent(String(pathComponent))
            }
    }

    /// Reads non-secret metadata for a present filesystem entry.
    private func metadata(for url: URL, isDirectory: Bool) -> (
        entryType: AgentContextEntryType,
        byteCount: Int?,
        modifiedAt: Date?
    ) {
        let resourceValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .contentModificationDateKey])
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber).map(\.intValue)
        let modifiedAt = (attributes?[.modificationDate] as? Date) ?? resourceValues?.contentModificationDate

        if resourceValues?.isSymbolicLink == true {
            return (.symlink, byteCount, modifiedAt)
        }

        if isDirectory {
            return (.directory, nil, modifiedAt)
        }

        if attributes?[.type] as? FileAttributeType == .typeRegular {
            return (.file, byteCount, modifiedAt)
        }

        return (.unexpected, byteCount, modifiedAt)
    }

    /// Derives deterministic metadata warnings from entry type and size.
    private func metadataWarnings(
        entryType: AgentContextEntryType,
        byteCount: Int?
    ) -> [AgentContextWarningCode] {
        var warnings: [AgentContextWarningCode] = []

        if entryType == .symlink {
            warnings.append(.symlinkNotTraversed)
        }

        if entryType == .unexpected {
            warnings.append(.unexpectedType)
        }

        guard entryType == .file, let byteCount else { return warnings }

        if byteCount == 0 {
            warnings.append(.emptyFile)
        }

        if byteCount > Self.oversizedFileByteThreshold {
            warnings.append(.oversizedFile)
        }

        return warnings
    }

    /// Adds governance-file warnings that depend on paired AGENTS.md and CLAUDE.md state.
    private func withGovernanceWarnings(
        _ item: AgentContextItem,
        missingWarning: AgentContextWarningCode,
        bothExist: Bool
    ) -> AgentContextItem {
        var warnings = item.warnings

        if !item.exists {
            warnings.append(missingWarning)
        }

        if bothExist {
            warnings.append(.bothGovernanceFilesPresent)
        }

        return AgentContextItem(
            relativePath: item.relativePath,
            url: item.url,
            kind: item.kind,
            entryType: item.entryType,
            byteCount: item.byteCount,
            modifiedAt: item.modifiedAt,
            warnings: warnings
        )
    }

    /// Returns a copy of an item with one additional scanner signal.
    private func appending(
        _ warning: AgentContextWarningCode,
        to item: AgentContextItem
    ) -> AgentContextItem {
        AgentContextItem(
            relativePath: item.relativePath,
            url: item.url,
            kind: item.kind,
            entryType: item.entryType,
            byteCount: item.byteCount,
            modifiedAt: item.modifiedAt,
            warnings: item.warnings + [warning]
        )
    }
}
