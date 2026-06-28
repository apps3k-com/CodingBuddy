//
//  CodexView.swift
//  CodingBuddy
//

import SwiftUI

/// Codex section: editable `~/.codex/mcp.env` on top, the read-only MCP
/// server overview from `config.toml` below.
struct CodexView: View {
    var store: CodexStore
    var secrets: SecretsGuard

    private struct EditorState: Identifiable {
        var id: String { variable?.id.description ?? "new" }
        var variable: EnvFileVariable?
        var name: String
        var value: String
    }

    @State private var editor: EditorState?
    @State private var pendingDeletion: EnvFileVariable?

    var body: some View {
        Group {
            if store.directoryExists {
                content
            } else {
                ContentUnavailableView(
                    "No Codex configuration",
                    systemImage: "terminal",
                    description: Text("~/.codex does not exist — Codex has not been set up on this Mac.")
                )
            }
        }
        .navigationTitle(Text(verbatim: "Codex"))
        .navigationSubtitle(Text(LocalizedCountText.variables(store.variables.count)))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Variable", systemImage: "plus") {
                    editor = EditorState(variable: nil, name: "", value: "")
                }
                .help("Add a new variable to mcp.env")
            }
        }
        .sheet(item: $editor) { state in
            editorSheet(state)
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")” from mcp.env?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let variable = pendingDeletion { store.delete(variable) }
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
            if !store.missingEnvVarNames.isEmpty {
                missingVariablesBanner
                Divider()
            }

            EnvKeyValueTable(
                rows: store.variables.map {
                    EnvKeyValueTable.Row(
                        id: String($0.id), name: $0.name,
                        value: $0.rawValue, isEditable: $0.isEditable
                    )
                },
                secrets: secrets,
                onEdit: { row in
                    if let variable = store.variables.first(where: { String($0.id) == row.id }) {
                        editor = EditorState(variable: variable, name: variable.name, value: variable.rawValue)
                    }
                },
                onDelete: { row in
                    pendingDeletion = store.variables.first { String($0.id) == row.id }
                }
            )

            Divider()
            serverList
                .frame(height: 220)
        }
    }

    /// The concrete "where does Codex read this from?" answer: a server
    /// references a variable that mcp.env does not define.
    private var missingVariablesBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Referenced by MCP servers but not defined in mcp.env:")
                    .font(.callout)
                ForEach(store.missingEnvVarNames, id: \.self) { name in
                    HStack(spacing: 8) {
                        Text(verbatim: name)
                            .monospaced()
                            .font(.callout)
                        Button("Define…") {
                            editor = EditorState(variable: nil, name: name, value: "")
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.08))
    }

    private var serverList: some View {
        List {
            Section {
                ForEach(store.servers) { server in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: server.name)
                                .fontWeight(.medium)
                            if let envVar = server.bearerTokenEnvVar {
                                Text(verbatim: envVar)
                                    .font(.caption2)
                                    .monospaced()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(
                                        store.missingEnvVarNames.contains(envVar)
                                            ? AnyShapeStyle(.orange.opacity(0.18))
                                            : AnyShapeStyle(.quaternary),
                                        in: Capsule()
                                    )
                                    .help("Bearer token environment variable")
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
                Text("MCP servers from config.toml (read-only)")
            }
        }
    }

    private func editorSheet(_ state: EditorState) -> some View {
        EnvEntryEditor(
            title: state.variable == nil ? String(localized: "New Variable") : String(localized: "Edit Variable"),
            name: state.name,
            value: state.value,
            onSave: { name, value in
                if let variable = state.variable {
                    store.update(variable, name: name, rawValue: value)
                } else {
                    store.add(name: name, rawValue: value)
                }
                editor = nil
            },
            onCancel: { editor = nil }
        )
    }
}

/// Minimal name/value editor sheet for plain env entries.
private struct EnvEntryEditor: View {
    let title: String
    @State var name: String
    @State var value: String
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Form {
                TextField("Name", text: $name)
                    .monospaced()
                TextField("Value", text: $value)
                    .monospaced()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(name, value) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
