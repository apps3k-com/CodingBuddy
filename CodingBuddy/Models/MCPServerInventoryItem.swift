//
//  MCPServerInventoryItem.swift
//  CodingBuddy
//

import Foundation

/// Normalized transport category for read-only MCP server inventory rows.
nonisolated enum MCPServerTransport: String, CaseIterable, Sendable {
    /// Server is started through a local stdio command.
    case stdio
    /// Server is reached through an HTTP endpoint.
    case http
    /// Server uses server-sent events.
    case sse
    /// The configuration does not expose enough information to classify transport.
    case unknown

    /// Localized label shown in the inventory table.
    var displayName: String {
        switch self {
        case .stdio:
            String(localized: "stdio")
        case .http:
            String(localized: "HTTP")
        case .sse:
            String(localized: "SSE")
        case .unknown:
            String(localized: "Unknown")
        }
    }

    /// Infers transport from explicit type hints first, then URL/command fields.
    static func infer(type: String?, url: String?, command: String?) -> MCPServerTransport {
        switch type?.lowercased() {
        case "http", "streamable-http":
            .http
        case "sse":
            .sse
        case "stdio":
            .stdio
        default:
            if url != nil { .http }
            else if command != nil { .stdio }
            else { .unknown }
        }
    }
}

/// Display-only row that merges MCP server definitions across supported tools.
nonisolated struct MCPServerInventoryItem: Identifiable, Equatable, Hashable, Sendable {
    /// Tool that owns or consumes this MCP server definition.
    var tool: AITool
    /// Server name as configured in the source tool.
    var name: String
    /// User scope or project path that owns the definition.
    var scope: String
    /// Repository or workspace name derived from the owning scope.
    var repositoryName: String
    /// Source file that contributed this inventory row.
    var sourcePath: String
    /// Transport category inferred from the definition.
    var transport: MCPServerTransport
    /// Redacted URL or command summary safe for display.
    var summary: String
    /// Environment variable names referenced or defined by the server config.
    var envVarNames: [String]
    /// Environment variable names that CodingBuddy can prove are missing.
    var missingEnvVarNames: [String]
    /// Header keys declared by JSON MCP server configs.
    var headerKeys: [String]

    /// Stable table identity that keeps duplicate server names distinct.
    var id: String {
        [tool.rawValue, sourcePath, scope, name].joined(separator: "|")
    }

    /// True when any referenced env var is known to be missing.
    var hasMissingEnvVars: Bool {
        !missingEnvVarNames.isEmpty
    }

    /// Search predicate covering server name, tool, repository, scope, env vars, and source path.
    func matches(searchText: String) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let haystack = ([name, tool.displayName, repositoryName, scope, sourcePath, transport.displayName, summary]
            + envVarNames + missingEnvVarNames + headerKeys)
            .joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(trimmed)
    }
}
