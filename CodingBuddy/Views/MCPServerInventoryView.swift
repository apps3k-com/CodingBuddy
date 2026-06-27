//
//  MCPServerInventoryView.swift
//  CodingBuddy
//

import SwiftUI

/// Read-only table that lists MCP server definitions across supported tools.
struct MCPServerInventoryView: View {
    /// Observable inventory state.
    var store: MCPServerInventoryStore
    /// Optional router used to open the existing editor for a selected tool.
    var onOpenTool: (AITool) -> Void = { _ in }

    /// Currently selected table row.
    @State private var selection: MCPServerInventoryItem.ID?
    /// Search text applied across server name, tool, scope, and env names.
    @State private var searchText = ""

    /// Inventory rows after applying the current search filter.
    private var filteredItems: [MCPServerInventoryItem] {
        store.items.filter { $0.matches(searchText: searchText) }
    }

    /// Selected row object, if the table selection still exists.
    private var selectedItem: MCPServerInventoryItem? {
        selection.flatMap { id in filteredItems.first { $0.id == id } }
    }

    /// Selected tool when CodingBuddy has an existing editor for that inventory row.
    private var selectedOpenableTool: AITool? {
        guard let tool = selectedItem?.tool, tool.hasMCPInventoryEditor else { return nil }
        return tool
    }

    /// Table-based inventory layout with search, refresh, and routing affordances.
    var body: some View {
        Table(filteredItems, selection: $selection) {
            TableColumn("Tool") { item in
                Label {
                    Text(verbatim: item.tool.displayName)
                } icon: {
                    Image(systemName: item.tool.systemImage)
                }
                .lineLimit(1)
            }
            .width(min: 120, ideal: 145, max: 180)

            TableColumn("Server") { item in
                Text(verbatim: item.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .width(min: 150, ideal: 210)

            TableColumn("Scope") { item in
                Text(verbatim: item.scope)
                    .font(.caption)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 150, ideal: 230)

            TableColumn("Transport") { item in
                Text(item.transport.displayName)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 95, max: 120)

            TableColumn("Command / URL") { item in
                Text(verbatim: item.summary)
                    .font(.caption)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .width(min: 220, ideal: 330)

            TableColumn("Env Vars") { item in
                EnvVarsCell(item: item)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Source") { item in
                Text(verbatim: item.sourcePath)
                    .font(.caption)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .width(min: 180, ideal: 260)
        }
        .navigationTitle("MCP Inventory")
        .searchable(text: $searchText, prompt: "Search MCP servers")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open Tool", systemImage: "arrow.right.circle") {
                    if let selectedOpenableTool {
                        onOpenTool(selectedOpenableTool)
                    }
                }
                .help("Open the selected tool editor")
                .disabled(selectedOpenableTool == nil)

                Button("Refresh", systemImage: "arrow.clockwise") {
                    store.reload()
                }
                .help("Refresh inventory")
            }
        }
        .overlay {
            if filteredItems.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "No MCP servers",
                        systemImage: "server.rack",
                        description: Text("CodingBuddy did not find any MCP server definitions for Codex, Claude Code, or Cursor.")
                    )
                } else {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different server, tool, scope, or environment variable name.")
                    )
                }
            }
        }
    }
}

private extension AITool {
    /// True when an inventory row can route to an existing sidebar editor.
    var hasMCPInventoryEditor: Bool {
        switch self {
        case .codex, .claudeCode, .cursor:
            true
        case .craftAgents:
            false
        }
    }
}

/// Compact tag list for MCP server environment references.
private struct EnvVarsCell: View {
    /// Inventory row whose env references should be rendered.
    var item: MCPServerInventoryItem

    /// Tag list that highlights env vars proven to be missing.
    var body: some View {
        if item.envVarNames.isEmpty && item.headerKeys.isEmpty {
            Text("No env vars")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                FlowTagRow(values: item.envVarNames) { name in
                    EnvVarTag(name: name, isMissing: item.missingEnvVarNames.contains(name))
                }
                if !item.headerKeys.isEmpty {
                    HStack(spacing: 0) {
                        Text("Headers:")
                        Text(verbatim: " \(item.headerKeys.joined(separator: ", "))")
                    }
                    .font(.caption2)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// Monospaced environment-variable tag with optional missing-state highlight.
private struct EnvVarTag: View {
    /// Environment variable name to display.
    var name: String
    /// Whether CodingBuddy can prove this variable is missing.
    var isMissing: Bool

    /// Capsule tag view used inside the inventory table.
    var body: some View {
        Text(verbatim: name)
            .font(.caption)
            .monospaced()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                isMissing ? AnyShapeStyle(.orange.opacity(0.2)) : AnyShapeStyle(.quaternary),
                in: Capsule()
            )
            .help(isMissing ? String(localized: "Missing in mcp.env") : String(localized: "Defined by server config"))
    }
}

/// Simple wrapping tag row that avoids introducing a custom layout dependency.
private struct FlowTagRow<Content: View>: View {
    /// Values rendered as tags.
    var values: [String]
    /// Builder for each tag view.
    var content: (String) -> Content

    /// Horizontal tag stack for the first few values with overflow count.
    var body: some View {
        HStack(spacing: 4) {
            ForEach(values.prefix(3), id: \.self) { value in
                content(value)
            }
            if values.count > 3 {
                Text(verbatim: "+\(values.count - 3)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
