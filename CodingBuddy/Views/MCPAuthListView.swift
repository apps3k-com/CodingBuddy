//
//  MCPAuthListView.swift
//  CodingBuddy
//

import AppKit
import SwiftUI

/// Lists the MCP servers found in ~/.mcp-auth with status, allows surgical
/// resets (to the Trash) and opens the credential file editor.
struct MCPAuthListView: View {
    var store: MCPAuthStore
    var secrets: SecretsGuard

    @State private var selection: MCPAuthEntry.ID?
    @State private var inspectedEntry: MCPAuthEntry?
    @State private var pendingReset: MCPAuthEntry?
    @State private var confirmResetAll = false

    var body: some View {
        Table(store.entries, selection: $selection) {
            TableColumn("Server") { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName)
                        .fontWeight(entry.serverURL != nil ? .medium : .regular)
                        .monospaced(entry.serverURL == nil)
                    if let scope = entry.scope {
                        Text(scope)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 220, ideal: 300)

            TableColumn("Status") { entry in
                TokenStatusBadge(status: entry.status)
            }
            .width(min: 120, ideal: 170)

            TableColumn("Version") { entry in
                Text(entry.versionDirectory)
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 130)

            TableColumn("Files") { entry in
                Text("\(entry.files.count) files")
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: MCPAuthEntry.ID.self) { ids in
            if let entry = entry(for: ids.first) {
                Button("View Files…") { inspectedEntry = entry }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(entry.files.map(\.url))
                }
                Divider()
                Button("Reset Entry…", role: .destructive) { pendingReset = entry }
            }
        } primaryAction: { ids in
            if let entry = entry(for: ids.first) { inspectedEntry = entry }
        }
        .navigationTitle(Text(verbatim: "MCP Auth"))
        .navigationSubtitle(Text("\(store.entries.count) servers"))
        .toolbar {
            ToolbarItem {
                Button("Reset All…", systemImage: "trash", role: .destructive) {
                    confirmResetAll = true
                }
                .disabled(store.entries.isEmpty)
                .help("Move all MCP credentials to the Trash")
            }
        }
        .sheet(item: $inspectedEntry) { entry in
            MCPAuthFileEditorView(store: store, secrets: secrets, entry: entry)
        }
        .confirmationDialog(
            "Move the credentials for “\(pendingReset?.displayName ?? "")” to the Trash?",
            isPresented: Binding(
                get: { pendingReset != nil },
                set: { if !$0 { pendingReset = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let entry = pendingReset { store.reset(entry) }
                pendingReset = nil
            }
        } message: {
            Text("The next connection will trigger a fresh OAuth login.")
        }
        .confirmationDialog(
            "Move all MCP credentials to the Trash? Every connected server will ask you to log in again.",
            isPresented: $confirmResetAll,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                store.resetAll()
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
        .overlay {
            if !store.rootExists {
                ContentUnavailableView(
                    "No MCP credentials",
                    systemImage: "key.slash",
                    description: Text("~/.mcp-auth does not exist — nothing to manage.")
                )
            } else if store.entries.isEmpty {
                ContentUnavailableView("No MCP credentials", systemImage: "key.slash")
            }
        }
    }

    private func entry(for id: MCPAuthEntry.ID?) -> MCPAuthEntry? {
        store.entries.first { $0.id == id }
    }
}
