//
//  ClaudeCodeView.swift
//  CodingBuddy
//

import SwiftUI

/// Claude Code section: the editable `env` blocks of settings.json and
/// settings.local.json on top, the read-only MCP server overview below.
struct ClaudeCodeView: View {
    var store: ClaudeCodeStore
    var secrets: SecretsGuard

    private struct EditorState: Identifiable {
        var id: String { entry?.id ?? "new" }
        /// nil when adding a new variable.
        var entry: ClaudeCodeStore.EnvEntry?
        var key: String
        var value: String
        var source: ClaudeCodeStore.EnvEntry.Source
    }

    @State private var editor: EditorState?
    @State private var pendingDeletion: ClaudeCodeStore.EnvEntry?

    var body: some View {
        Group {
            if store.directoryExists {
                content
            } else {
                ContentUnavailableView(
                    "No Claude Code configuration",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("~/.claude does not exist — Claude Code has not been set up on this Mac.")
                )
            }
        }
        .navigationTitle(Text(verbatim: "Claude Code"))
        .navigationSubtitle(Text("\(store.envEntries.count) variables"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Variable", systemImage: "plus") {
                    editor = EditorState(entry: nil, key: "", value: "", source: .settings)
                }
                .help("Add a new variable to the env section")
            }
        }
        .sheet(item: $editor) { state in
            ClaudeEnvEditor(
                isNew: state.entry == nil,
                onSave: { key, value, source in
                    if let entry = state.entry {
                        store.update(entry, newValue: value)
                    } else {
                        store.add(key: key, value: value, to: source)
                    }
                    editor = nil
                },
                onCancel: { editor = nil },
                key: state.key, value: state.value, source: state.source
            )
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.key ?? "")” from \(pendingDeletion?.source.fileName ?? "")?",
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
                        sourceLabel: $0.source.fileName
                    )
                },
                secrets: secrets,
                onEdit: { row in
                    if let entry = store.envEntries.first(where: { $0.id == row.id }) {
                        editor = EditorState(entry: entry, key: entry.key, value: entry.value, source: entry.source)
                    }
                },
                onDelete: { row in
                    pendingDeletion = store.envEntries.first { $0.id == row.id }
                }
            )

            Divider()
            serverList
                .frame(height: 220)
        }
    }

    private var serverList: some View {
        List {
            Section {
                ForEach(store.servers) { server in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: server.name)
                                .fontWeight(.medium)
                            if server.scope != "user" {
                                Text(verbatim: URL(fileURLWithPath: server.scope).lastPathComponent)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                                    .help(Text(verbatim: server.scope))
                            }
                            ForEach(server.envKeys, id: \.self) { key in
                                Text(verbatim: key)
                                    .font(.caption2)
                                    .monospaced()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
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

/// Name/value editor with a target-file picker when adding.
private struct ClaudeEnvEditor: View {
    let isNew: Bool
    let onSave: (String, String, ClaudeCodeStore.EnvEntry.Source) -> Void
    let onCancel: () -> Void

    @State var key: String
    @State var value: String
    @State var source: ClaudeCodeStore.EnvEntry.Source

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
                    Picker("File", selection: $source) {
                        ForEach(ClaudeCodeStore.EnvEntry.Source.allCases, id: \.self) { source in
                            Text(verbatim: source.fileName).tag(source)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(key, value, source) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(key.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
