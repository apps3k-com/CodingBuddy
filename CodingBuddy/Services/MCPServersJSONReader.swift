//
//  MCPServersJSONReader.swift
//  CodingBuddy
//

import Foundation

/// Reads the common `{"mcpServers": {...}}` JSON shape (Claude Code, Cursor).
nonisolated enum MCPServersJSONReader {

    static func servers(inDocument text: String, scope: String) -> [MCPServerConfig] {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let root = parsed as? [String: Any],
              let mcpServers = root["mcpServers"] as? [String: Any]
        else { return [] }
        return servers(fromDictionary: mcpServers, scope: scope)
    }

    static func servers(fromDictionary dictionary: [String: Any], scope: String) -> [MCPServerConfig] {
        dictionary.compactMap { name, value -> MCPServerConfig? in
            guard let server = value as? [String: Any] else { return nil }
            return MCPServerConfig(
                name: name,
                url: server["url"] as? String,
                command: server["command"] as? String,
                args: (server["args"] as? [String]) ?? [],
                envKeys: ((server["env"] as? [String: Any])?.keys.sorted()) ?? [],
                headerKeys: ((server["headers"] as? [String: Any])?.keys.sorted()) ?? [],
                scope: scope
            )
        }
        .sorted { $0.name < $1.name }
    }
}
