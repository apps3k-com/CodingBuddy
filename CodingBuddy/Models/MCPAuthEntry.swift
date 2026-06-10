//
//  MCPAuthEntry.swift
//  CodingBuddy
//

import Foundation

/// One file inside an `~/.mcp-auth` server entry.
nonisolated struct MCPAuthFile: Identifiable, Hashable {
    enum Kind: String {
        case tokens = "tokens.json"
        case clientInfo = "client_info.json"
        case codeVerifier = "code_verifier.txt"
        case lock = "lock.json"
        case other

        init(fileName: String) {
            let suffix = fileName.drop(while: { $0 != "_" }).dropFirst()
            self = Kind(rawValue: String(suffix)) ?? .other
        }
    }

    let url: URL
    let kind: Kind
    let modified: Date?

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
    var isJSON: Bool { fileName.hasSuffix(".json") }
}

/// All credential files that `mcp-remote` stores for one MCP server. The
/// directory layout is `~/.mcp-auth/mcp-remote-<version>/<md5(serverURL)>_<kind>`.
nonisolated struct MCPAuthEntry: Identifiable, Hashable {
    let hash: String
    let versionDirectory: String
    var files: [MCPAuthFile]
    /// Resolved by hashing the MCP server URLs found in the local Claude
    /// configuration files; nil when the URL is configured elsewhere.
    var serverURL: String?
    var scope: String?
    /// Best-effort estimate: mtime of tokens.json + expires_in. An expired
    /// access token may still refresh automatically via the refresh token.
    var accessTokenExpiry: Date?

    var id: String { "\(versionDirectory)/\(hash)" }

    var displayName: String {
        serverURL ?? "\(hash.prefix(12))…"
    }

    var hasTokens: Bool {
        files.contains { $0.kind == .tokens }
    }

    var status: TokenStatus {
        guard hasTokens else { return .incomplete }
        if let accessTokenExpiry, accessTokenExpiry < Date() { return .expired(accessTokenExpiry) }
        return .active(expiry: accessTokenExpiry)
    }
}
