//
//  CursorView.swift
//  CodingBuddy
//

import SwiftUI

/// Cursor section: editable per-server `env` values from `~/.cursor/mcp.json`
/// on top, the read-only server list below.
struct CursorView: View {
    var store: CursorStore
    var secrets: SecretsGuard

    private struct EditorState: Identifiable {
        var id: String { entry?.id ?? "new" }
        var entry: CursorStore.EnvEntry?
        var key: String
        var value: String
        var server: String
    }

    @State private var editor: EditorState?
    @State private var pendingDeletion: CursorStore.EnvEntry?

    var body: some View {
        Group {
            if store.directoryExists {
                content
            } else {
                ContentUnavailableView(
                    "No Cursor configuration",
                    systemImage: "cursorarrow",
                    description: Text("~/.cursor does not exist — Cursor has not been set up on this Mac.")
                )
            }
        }
        .navigationTitle(Text(verbatim: "Cursor"))
        .navigationSubtitle(Text("\(store.envEntries.count) variables"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Variable", systemImage: "plus") {
                    editor = EditorState(
                        entry: nil, key: "", value: "",
                        server: store.servers.first?.name ?? ""
                    )
                }
                .help("Add a new variable to a server's env object")
                .disabled(store.servers.isEmpty)
            }
        }
        .sheet(item: $editor) { state in
            CursorEnvEditor(
                isNew: state.entry == nil,
                serverNames: store.servers.map(\.name),
                onSave: { key, value, server in
                    if let entry = state.entry {
                        store.update(entry, newValue: value)
                    } else {
                        store.add(key: key, value: value, toServer: server)
                    }
                    editor = nil
                },
                onCancel: { editor = nil },
                key: state.key, value: state.value, server: state.server
            )
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.key ?? "")” from \(pendingDeletion?.server ?? "")?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDeletion { store.delete(entry) }
                pendingDeletion = nil
            }
        } message: {
            Text("A backup of the file is written automatically before the change.")
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
    }

    private var content: some View {
        VStack(spacing: 0) {
            EnvKeyValueTable(
                rows: store.envEntries.map {
                    EnvKeyValueTable.Row(
                        id: $0.id, name: $0.key, value: $0.value,
                        sourceLabel: $0.server
                    )
                },
                secrets: secrets,
                onEdit: { row in
                    if let entry = store.envEntries.first(where: { $0.id == row.id }) {
                        editor = EditorState(entry: entry, key: entry.key, value: entry.value, server: entry.server)
                    }
                },
                onDelete: { row in
                    pendingDeletion = store.envEntries.first { $0.id == row.id }
                }
            )

            Divider()
            serverList
                .frame(height: 200)
        }
    }

    private var serverList: some View {
        List {
            Section {
                ForEach(store.servers) { server in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: server.name)
                            .fontWeight(.medium)
                        Text(verbatim: server.url ?? ([server.command].compactMap(\.self) + server.args).joined(separator: " "))
                            .font(.caption)
                            .monospaced()
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            } header: {
                Text("MCP servers (read-only)")
            }
        }
    }
}

/// Name/value editor with a server picker when adding.
private struct CursorEnvEditor: View {
    let isNew: Bool
    let serverNames: [String]
    let onSave: (String, String, String) -> Void
    let onCancel: () -> Void

    @State var key: String
    @State var value: String
    @State var server: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Variable" : "Edit Variable")
                .font(.headline)
            Form {
                TextField("Name", text: $key)
                    .monospaced()
                    .disabled(!isNew)
                TextField("Value", text: $value)
                    .monospaced()
                if isNew {
                    Picker("Server", selection: $server) {
                        ForEach(serverNames, id: \.self) { name in
                            Text(verbatim: name).tag(name)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(key, value, server) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(key.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
