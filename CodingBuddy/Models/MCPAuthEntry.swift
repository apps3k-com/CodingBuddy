//
//  MCPAuthEntry.swift
//  CodingBuddy
//

import Foundation

/// One file inside an `~/.mcp-auth` server entry.
nonisolated struct MCPAuthFile: Identifiable, Hashable, Sendable {
    /// Credential artifact role inferred from the file-name suffix.
    enum Kind: String, Sendable {
        /// OAuth access and refresh token payload.
        case tokens = "tokens.json"
        /// OAuth dynamic client-registration metadata.
        case clientInfo = "client_info.json"
        /// PKCE verifier retained for an authorization exchange.
        case codeVerifier = "code_verifier.txt"
        /// Coordination state used by the credential helper.
        case lock = "lock.json"
        /// Unrecognized artifact preserved for visibility and reset operations.
        case other

        /// Classifies an `mcp-remote` credential artifact by suffix.
        init(fileName: String) {
            let suffix = fileName.drop(while: { $0 != "_" }).dropFirst()
            self = Kind(rawValue: String(suffix)) ?? .other
        }
    }

    /// On-disk location of the credential artifact.
    let url: URL
    /// Semantic role inferred from the file name.
    let kind: Kind
    /// Last modification time, or nil when metadata could not be read.
    let modified: Date?
    /// Whether the scanner accepted this exact artifact for bounded no-follow reads.
    let isSafelyReadable: Bool

    /// Creates a credential artifact; tests and trusted regular-file callers
    /// default to readable while scanner-detected symlinks opt out explicitly.
    init(
        url: URL,
        kind: Kind,
        modified: Date?,
        isSafelyReadable: Bool = true
    ) {
        self.url = url
        self.kind = kind
        self.modified = modified
        self.isSafelyReadable = isSafelyReadable
    }

    /// Path-based identity across credential directories.
    var id: String { url.path }
    /// Last path component shown without exposing file contents.
    var fileName: String { url.lastPathComponent }
    /// Whether the artifact can be presented in the JSON editor.
    var isJSON: Bool { fileName.hasSuffix(".json") }
}

/// All credential files that `mcp-remote` stores for one MCP server. The
/// directory layout is `~/.mcp-auth/mcp-remote-<version>/<md5(serverURL)>_<kind>`.
nonisolated struct MCPAuthEntry: Identifiable, Hashable, Sendable {
    /// MD5-derived server identifier used by `mcp-remote` on disk.
    let hash: String
    /// Versioned `mcp-remote` directory containing the artifacts.
    let versionDirectory: String
    /// Credential artifacts discovered for this server identity.
    var files: [MCPAuthFile]
    /// Resolved by hashing the MCP server URLs found in the local Claude
    /// configuration files; nil when the URL is configured elsewhere.
    var serverURL: String?
    /// Parsed OAuth scope string when token metadata exposes one.
    var scope: String?
    /// Best-effort estimate: mtime of tokens.json + expires_in. An expired
    /// access token may still refresh automatically via the refresh token.
    var accessTokenExpiry: Date?

    /// Identity that distinguishes equal hashes across helper versions.
    var id: String { "\(versionDirectory)/\(hash)" }

    /// Resolved server URL or a shortened opaque hash when unresolved.
    var displayName: String {
        serverURL ?? "\(hash.prefix(12))…"
    }

    /// Whether a token payload exists, without inspecting secret values.
    var hasTokens: Bool {
        files.contains { $0.kind == .tokens }
    }

    /// Whether at least one token payload passed the scanner's no-follow safety checks.
    var hasSafelyReadableTokens: Bool {
        files.contains { $0.kind == .tokens && $0.isSafelyReadable }
    }

    /// Best-effort credential status derived from artifact presence and expiry.
    var status: TokenStatus {
        if hasTokens && !hasSafelyReadableTokens { return .resetOnly }
        guard hasSafelyReadableTokens else { return .incomplete }
        if let accessTokenExpiry, accessTokenExpiry < Date() { return .expired(accessTokenExpiry) }
        return .active(expiry: accessTokenExpiry)
    }
}
