//
//  CodexView.swift
//  CodingBuddy
//

import SwiftUI

/// Codex section: editable `~/.codex/mcp.env` on top, the read-only MCP
/// server overview from `config.toml` below.
struct CodexView: View {
    /// Store providing guarded access to Codex MCP environment configuration.
    var store: CodexStore
    /// Authentication state controlling sensitive-value disclosure.
    var secrets: SecretsGuard

    private struct EditorState: Identifiable {
        /// Stable sheet identity for an existing assignment or the add flow.
        var id: String { variable?.id.description ?? "new" }
        /// Original assignment when editing, or `nil` when adding.
        var variable: EnvFileVariable?
        /// Draft variable name.
        var name: String
        /// Draft raw value preserved for shell-safe writing.
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
            secrets: secrets,
            protectsRevealedSecret: state.variable.map {
                FeatureFlag.secretsProtection.isEnabled && SecretDetector.isSensitive(name: $0.name)
            } ?? false,
            onSave: { name, value in
                let saved = if let variable = state.variable {
                    store.update(variable, name: name, rawValue: value)
                } else {
                    store.add(name: name, rawValue: value)
                }
                if saved { editor = nil }
                return saved
            },
            onCancel: { editor = nil },
            onAutomaticDiscard: {
                store.lastError = String(localized: "The unlock period ended. CodingBuddy discarded the unsaved cleartext draft.")
            }
        )
    }
}

/// Minimal name/value editor sheet for plain env entries.
private struct EnvEntryEditor: View {
    /// Localized heading supplied by the owning workflow.
    let title: String
    /// Draft environment variable name.
    @State var name: String
    /// Draft raw environment value.
    @State var value: String
    /// Shared authentication state that bounds this draft's cleartext lifetime.
    var secrets: SecretsGuard
    /// Whether this editor received an existing sensitive value after authentication.
    let protectsRevealedSecret: Bool
    /// Save action that delegates mutation to the owning store.
    let onSave: (String, String) -> Bool
    /// Dismissal action that leaves configuration unchanged.
    let onCancel: () -> Void
    /// Reports a dirty draft discarded by automatic expiry.
    let onAutomaticDiscard: () -> Void
    /// Initial name used to detect unsaved changes.
    private let originalName: String
    /// Initial value used to detect unsaved changes.
    private let originalValue: String

    /// Creates a draft editor with an immutable comparison snapshot.
    init(
        title: String,
        name: String,
        value: String,
        secrets: SecretsGuard,
        protectsRevealedSecret: Bool,
        onSave: @escaping (String, String) -> Bool,
        onCancel: @escaping () -> Void,
        onAutomaticDiscard: @escaping () -> Void
    ) {
        self.title = title
        _name = State(initialValue: name)
        _value = State(initialValue: value)
        self.secrets = secrets
        self.protectsRevealedSecret = protectsRevealedSecret
        self.onSave = onSave
        self.onCancel = onCancel
        self.onAutomaticDiscard = onAutomaticDiscard
        originalName = name
        originalValue = value
    }

    /// Whether closing the editor would lose a changed field.
    private var hasUnsavedChanges: Bool {
        name != originalName || value != originalValue
    }

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
                Button("Save") { _ = onSave(name, value) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
        .protectsSecretDraft(
            secrets: secrets,
            protectsRevealedSecret: protectsRevealedSecret,
            currentName: name,
            hasUnsavedChanges: hasUnsavedChanges,
            canSave: !name.isEmpty,
            saveAndDismiss: { onSave(name, value) },
            clearAndDismiss: clearAndDismiss,
            reportAutomaticDiscard: onAutomaticDiscard
        )
    }

    /// Removes the raw value before handing dismissal back to the parent.
    private func clearAndDismiss() {
        value = ""
        name = ""
        onCancel()
    }
}
