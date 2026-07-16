//
//  CursorView.swift
//  CodingBuddy
//

import SwiftUI

/// Cursor section: editable per-server `env` values from `~/.cursor/mcp.json`
/// on top, the read-only server list below.
struct CursorView: View {
    /// Store providing value-precise Cursor MCP configuration mutations.
    var store: CursorStore
    /// Authentication state controlling sensitive-value disclosure.
    var secrets: SecretsGuard

    private struct EditorState: Identifiable {
        /// Stable sheet identity for an existing pair or the add flow.
        var id: String { entry?.id ?? "new" }
        /// Original nested value when editing, or `nil` when adding.
        var entry: CursorStore.EnvEntry?
        /// Draft environment variable name.
        var key: String
        /// Draft environment variable value.
        var value: String
        /// MCP server receiving a newly added pair.
        var server: String
        /// Complete semantic server snapshots visible when this editor opened.
        var serverSnapshots: [CursorStore.ServerSnapshot]
    }

    /// Exact row and server definition bound to one destructive confirmation.
    private struct DeletionState: Equatable {
        /// Environment pair selected by the user.
        var entry: CursorStore.EnvEntry
        /// Owning server definition visible when deletion was requested.
        var serverSnapshot: CursorStore.ServerSnapshot
    }

    @State private var editor: EditorState?
    @State private var pendingDeletion: DeletionState?
    @AccessibilityFocusState private var refusalFocused: Bool

    var body: some View {
        Group {
            switch store.loadState {
            case .loaded:
                content
            case .missing:
                missingView
            case let .refused(reason):
                refusedView(reason: reason)
            }
        }
        .navigationTitle(Text(verbatim: "Cursor"))
        .navigationSubtitle(navigationSubtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Variable", systemImage: "plus") {
                    editor = EditorState(
                        entry: nil, key: "", value: "",
                        server: store.serverSnapshots.first?.configuration.name ?? "",
                        serverSnapshots: store.serverSnapshots
                    )
                }
                .help("Add a new variable to a server's env object")
                .disabled(store.loadState != .loaded || store.servers.isEmpty)
            }
        }
        .onChange(of: store.loadState, initial: true) { _, state in
            if case .refused = state {
                refusalFocused = true
            } else {
                refusalFocused = false
            }
            if state != .loaded {
                editor = nil
                pendingDeletion = nil
            }
        }
        .onChange(of: store.envEntries) { _, entries in
            if let entry = editor?.entry, !entries.contains(entry) {
                editor = nil
            }
            if let pendingDeletion, !entries.contains(pendingDeletion.entry) {
                self.pendingDeletion = nil
            }
        }
        .onChange(of: store.serverSnapshots) { _, serverSnapshots in
            if let editor, editor.serverSnapshots != serverSnapshots {
                self.editor = nil
            }
            if let pendingDeletion,
               !serverSnapshots.contains(pendingDeletion.serverSnapshot) {
                self.pendingDeletion = nil
            }
        }
        .sheet(item: $editor) { state in
            CursorEnvEditor(
                isNew: state.entry == nil,
                serverNames: state.serverSnapshots.map(\.configuration.name),
                key: state.key,
                value: state.value,
                server: state.server,
                secrets: secrets,
                protectsRevealedSecret: state.entry.map {
                    FeatureFlag.secretsProtection.isEnabled && SecretDetector.isSensitive(name: $0.key)
                } ?? false,
                onSave: { key, value, server in
                    guard let expectedServer = state.serverSnapshots.first(where: {
                        $0.configuration.name == server
                    }) else {
                        store.lastError = String(localized: "The file was changed externally. Please try again.")
                        return false
                    }
                    let saved = if let entry = state.entry {
                        store.update(
                            entry,
                            expectedServer: expectedServer,
                            newValue: value
                        )
                    } else {
                        store.add(key: key, value: value, toServer: expectedServer)
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
        .confirmationDialog(
            "Delete “\(pendingDeletion?.entry.key ?? "")” from \(pendingDeletion?.entry.server ?? "")?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDeletion {
                    store.delete(
                        pendingDeletion.entry,
                        expectedServer: pendingDeletion.serverSnapshot
                    )
                }
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

    @ViewBuilder
    private var missingView: some View {
        if store.directoryExists {
            ContentUnavailableView("No Cursor configuration", systemImage: "cursorarrow")
        } else {
            ContentUnavailableView(
                "No Cursor configuration",
                systemImage: "cursorarrow",
                description: Text("~/.cursor does not exist — Cursor has not been set up on this Mac.")
            )
        }
    }

    /// Safety refusal shown instead of empty tables or stale values.
    private func refusedView(reason: CursorStore.RefusalReason) -> some View {
        ContentUnavailableView {
            Label("Access blocked", systemImage: "lock.trianglebadge.exclamationmark")
                .accessibilityFocused($refusalFocused)
        } description: {
            VStack(spacing: 6) {
                Text("CodingBuddy did not load this file because it could not be read safely.")
                Text(reason.localizedDescription)
            }
        } actions: {
            Button("Retry", systemImage: "arrow.clockwise") {
                store.reload()
            }
            Button("Show in Finder", systemImage: "folder") {
                revealRefusedConfiguration(reason: reason)
            }
        }
    }

    /// Keeps the subtitle truthful when no count was established.
    private var navigationSubtitle: Text {
        switch store.loadState {
        case .loaded:
            Text(LocalizedCountText.variables(store.envEntries.count))
        case .missing:
            Text("No Cursor configuration")
        case .refused:
            Text("Access blocked")
        }
    }

    /// Avoids handing an unsafe configured path to Finder.
    private func revealRefusedConfiguration(reason: CursorStore.RefusalReason) {
        let url = reason == .unsafePath
            ? store.cursorDirectory.deletingLastPathComponent()
            : store.mcpJSONURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
                        editor = EditorState(
                            entry: entry,
                            key: entry.key,
                            value: entry.value,
                            server: entry.server,
                            serverSnapshots: store.serverSnapshots
                        )
                    }
                },
                onDelete: { row in
                    guard let entry = store.envEntries.first(where: { $0.id == row.id }),
                          let server = store.serverSnapshots.first(where: {
                              $0.configuration.name == entry.server
                          })
                    else { return }
                    pendingDeletion = DeletionState(entry: entry, serverSnapshot: server)
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
    /// Whether the sheet creates a new pair rather than editing an existing one.
    let isNew: Bool
    /// Available MCP server names for a new environment pair.
    let serverNames: [String]
    /// Save action delegated to the owning Cursor view.
    let onSave: (String, String, String) -> Bool
    /// Dismissal action that performs no mutation.
    let onCancel: () -> Void
    /// Reports a dirty draft discarded by automatic expiry.
    let onAutomaticDiscard: () -> Void

    /// Draft environment variable name.
    @State var key: String
    /// Draft environment variable value.
    @State var value: String
    /// Selected destination server.
    @State var server: String
    /// Shared authentication state that bounds this draft's cleartext lifetime.
    var secrets: SecretsGuard
    /// Whether this editor received an existing sensitive value after authentication.
    let protectsRevealedSecret: Bool
    /// Initial key used to detect a dirty draft.
    private let originalKey: String
    /// Initial value used to detect a dirty draft.
    private let originalValue: String
    /// Initial server used to detect a dirty draft.
    private let originalServer: String

    /// Creates a draft editor with an immutable comparison snapshot.
    init(
        isNew: Bool,
        serverNames: [String],
        key: String,
        value: String,
        server: String,
        secrets: SecretsGuard,
        protectsRevealedSecret: Bool,
        onSave: @escaping (String, String, String) -> Bool,
        onCancel: @escaping () -> Void,
        onAutomaticDiscard: @escaping () -> Void
    ) {
        self.isNew = isNew
        self.serverNames = serverNames
        _key = State(initialValue: key)
        _value = State(initialValue: value)
        _server = State(initialValue: server)
        self.secrets = secrets
        self.protectsRevealedSecret = protectsRevealedSecret
        self.onSave = onSave
        self.onCancel = onCancel
        self.onAutomaticDiscard = onAutomaticDiscard
        originalKey = key
        originalValue = value
        originalServer = server
    }

    /// Whether closing the editor would lose a changed field.
    private var hasUnsavedChanges: Bool {
        key != originalKey || value != originalValue || server != originalServer
    }

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
                Button("Save") { _ = onSave(key, value, server) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(key.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
        .protectsSecretDraft(
            secrets: secrets,
            protectsRevealedSecret: protectsRevealedSecret,
            hasUnsavedChanges: hasUnsavedChanges,
            canSave: !key.isEmpty,
            saveAndDismiss: { onSave(key, value, server) },
            clearAndDismiss: clearAndDismiss,
            reportAutomaticDiscard: onAutomaticDiscard
        )
    }

    /// Removes the raw value before handing dismissal back to the parent.
    private func clearAndDismiss() {
        value = ""
        key = ""
        onCancel()
    }
}
