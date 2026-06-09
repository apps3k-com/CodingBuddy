//
//  MCPAuthScanner.swift
//  EnvVarBuddy
//

import CryptoKit
import Foundation

/// Reads the `~/.mcp-auth` credential cache that `mcp-remote` maintains for
/// OAuth-connected MCP servers. Pure file inspection — never logs or exposes
/// token values itself.
nonisolated enum MCPAuthScanner {

    /// `mcp-remote` names files `<md5(serverURL)>_<kind>`; the URL itself is
    /// not stored. We recover it by hashing the server URLs found in the
    /// local Claude configuration files.
    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Collects every http(s) URL mentioned in the Claude config files —
    /// candidates for MCP server URLs. Over-collecting is harmless: only
    /// exact md5 matches are ever used.
    static func configuredServerURLs(homeDirectory: URL) -> [String] {
        let configFiles = [
            homeDirectory.appendingPathComponent(".claude.json"),
            homeDirectory.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
        ]
        var urls: Set<String> = []
        for file in configFiles {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            collectHTTPStrings(in: json, into: &urls)
        }
        return Array(urls)
    }

    static func scan(root: URL, knownServerURLs: [String]) -> [MCPAuthEntry] {
        let fileManager = FileManager.default
        let urlByHash = Dictionary(
            knownServerURLs.map { (md5Hex($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        guard let versionDirectories = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var entries: [MCPAuthEntry] = []
        for directory in versionDirectories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let fileURLs = try? fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
                  ) else { continue }

            let grouped = Dictionary(grouping: fileURLs.compactMap(authFile), by: \.hash)
            for (hash, hashedFiles) in grouped {
                var entry = MCPAuthEntry(
                    hash: hash,
                    versionDirectory: directory.lastPathComponent,
                    files: hashedFiles.map(\.file).sorted { $0.fileName < $1.fileName },
                    serverURL: urlByHash[hash],
                    scope: nil,
                    accessTokenExpiry: nil
                )
                if let tokens = entry.files.first(where: { $0.kind == .tokens }) {
                    applyTokenMetadata(from: tokens, to: &entry)
                }
                entries.append(entry)
            }
        }

        // Resolved servers first, then by name — stable, scannable order.
        return entries.sorted {
            switch ($0.serverURL != nil, $1.serverURL != nil) {
            case (true, false): true
            case (false, true): false
            default: $0.displayName < $1.displayName
            }
        }
    }

    // MARK: - Helpers

    private static func authFile(for url: URL) -> (hash: String, file: MCPAuthFile)? {
        let name = url.lastPathComponent
        guard let underscore = name.firstIndex(of: "_") else { return nil }
        let hash = String(name[..<underscore])
        guard hash.count == 32, hash.allSatisfy(\.isHexDigit) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (hash, MCPAuthFile(url: url, kind: .init(fileName: name), modified: modified))
    }

    /// Extracts only non-secret metadata (scope, expiry estimate) from
    /// tokens.json. Token values are never read into model state.
    private static func applyTokenMetadata(from file: MCPAuthFile, to entry: inout MCPAuthEntry) {
        guard let data = try? Data(contentsOf: file.url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        entry.scope = json["scope"] as? String
        if let expiresIn = json["expires_in"] as? Double, let modified = file.modified {
            entry.accessTokenExpiry = modified.addingTimeInterval(expiresIn)
        }
    }

    private static func collectHTTPStrings(in value: Any, into urls: inout Set<String>) {
        switch value {
        case let string as String where string.hasPrefix("https://") || string.hasPrefix("http://"):
            urls.insert(string)
        case let array as [Any]:
            for element in array { collectHTTPStrings(in: element, into: &urls) }
        case let dictionary as [String: Any]:
            for element in dictionary.values { collectHTTPStrings(in: element, into: &urls) }
        default:
            break
        }
    }
}
