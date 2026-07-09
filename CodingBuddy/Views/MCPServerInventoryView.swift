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

    /// Existing source file for the selected server definition.
    private var selectedSourceURL: URL? {
        guard let sourcePath = selectedItem?.sourcePath, sourcePath.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: sourcePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Inspector visibility follows table selection and clears it when dismissed.
    private var inspectorBinding: Binding<Bool> {
        Binding {
            selectedItem != nil
        } set: { isPresented in
            if !isPresented { selection = nil }
        }
    }

    /// Table-based inventory layout with search, refresh, and routing affordances.
    var body: some View {
        Table(filteredItems, selection: $selection) {
            TableColumn("Server") { item in
                Text(verbatim: item.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .width(min: 150, ideal: 210)

            TableColumn("Tool") { item in
                Label {
                    Text(verbatim: item.tool.displayName)
                } icon: {
                    Image(systemName: item.tool.systemImage)
                }
                .lineLimit(1)
            }
            .width(min: 120, ideal: 145, max: 180)

            TableColumn("Repository") { item in
                Text(verbatim: item.repositoryName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 120, ideal: 160, max: 220)

            TableColumn("Configuration") { item in
                InventoryConfigurationCell(item: item)
            }
            .width(min: 150, ideal: 190, max: 230)
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

                Button("Open Source", systemImage: "doc.text") {
                    openSelectedSource()
                }
                .help("Open the selected source file")
                .disabled(selectedSourceURL == nil)

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
                        description: Text("Try a different server, tool, repository, scope, or environment variable name.")
                    )
                }
            }
        }
        .inspector(isPresented: inspectorBinding) {
            if let selectedItem {
                MCPServerInspector(
                    item: selectedItem,
                    canOpenTool: selectedOpenableTool != nil,
                    canOpenSource: selectedSourceURL != nil,
                    openTool: {
                        if let selectedOpenableTool { onOpenTool(selectedOpenableTool) }
                    },
                    openSource: openSelectedSource
                )
                .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
            }
        }
    }

    /// Opens the selected source file with the configured external editor.
    private func openSelectedSource() {
        guard let selectedSourceURL else { return }
        Task {
            _ = await ExternalFileOpener().open(selectedSourceURL)
        }
    }
}

/// Compact table status that keeps configuration health visible without extra columns.
private struct InventoryConfigurationCell: View {
    /// Server represented by the status label.
    var item: MCPServerInventoryItem

    var body: some View {
        if item.hasMissingEnvVars {
            Label("Missing variables", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Label("Configured", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}

/// Full metadata and follow-up actions for one MCP server definition.
private struct MCPServerInspector: View {
    /// Selected inventory row.
    var item: MCPServerInventoryItem
    /// Whether CodingBuddy has an editor for the owning tool.
    var canOpenTool: Bool
    /// Whether the source file exists locally.
    var canOpenSource: Bool
    /// Opens the owning tool editor.
    var openTool: () -> Void
    /// Opens the source file.
    var openSource: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Label {
                        Text(verbatim: item.tool.displayName)
                    } icon: {
                        Image(systemName: item.tool.systemImage)
                    }
                    .foregroundStyle(.secondary)
                    Text(verbatim: item.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    InventoryConfigurationCell(item: item)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Repository", value: item.repositoryName)
                    LabeledContent("Transport", value: item.transport.displayName)
                    LabeledContent("Scope") {
                        Text(verbatim: item.scope)
                            .monospaced()
                            .textSelection(.enabled)
                    }
                    LabeledContent("Source") {
                        Text(verbatim: item.sourcePath)
                            .monospaced()
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Command / URL")
                        .font(.headline)
                    Text(verbatim: item.summary)
                        .font(.caption)
                        .monospaced()
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Environment")
                        .font(.headline)
                    EnvVarsCell(item: item)
                }

                HStack {
                    Button("Open Tool", systemImage: "arrow.right.circle", action: openTool)
                        .disabled(!canOpenTool)
                    Button("Open Source", systemImage: "doc.text", action: openSource)
                        .disabled(!canOpenSource)
                }
            }
            .padding(16)
        }
        .navigationTitle("Details")
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
