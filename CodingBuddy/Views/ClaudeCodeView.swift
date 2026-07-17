//
//  ClaudeCodeView.swift
//  CodingBuddy
//

import AppKit
import SwiftUI

/// Claude Code section: the editable `env` blocks of settings.json and
/// settings.local.json on top, the read-only MCP server overview below.
struct ClaudeCodeView: View {
    /// Store providing guarded Claude Code configuration mutations.
    var store: ClaudeCodeStore
    /// Authentication state controlling whether sensitive values may be revealed.
    var secrets: SecretsGuard

    private struct EditorState: Identifiable {
        /// Stable sheet identity for either an existing entry or the add flow.
        var id: String { entry?.id ?? "new" }
        /// nil when adding a new variable.
        var entry: ClaudeCodeStore.EnvEntry?
        /// Environment variable name being created or displayed.
        var key: String
        /// Environment value being edited after any required authentication.
        var value: String
        /// Claude settings file that receives a newly added value.
        var source: ClaudeCodeStore.EnvEntry.Source
    }

    @State private var editor: EditorState?
    @State private var pendingDeletion: ClaudeCodeStore.EnvEntry?
    @AccessibilityFocusState private var unavailableFocus: UnavailableFocus?

    /// Stable focus destinations for asynchronous loading and refusal feedback.
    private enum UnavailableFocus: Hashable {
        /// Filesystem inspection is still running.
        case loading
        /// Filesystem inspection refused one or more unsafe sources.
        case refused
    }

    var body: some View {
        Group {
            switch store.loadState {
            case .notLoaded, .loading:
                loadingView
            case .refused(let reason):
                refusedView(reason: reason)
            case .loaded where store.directoryExists:
                content
            case .loaded:
                ContentUnavailableView(
                    "No Claude Code configuration",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("~/.claude does not exist — Claude Code has not been set up on this Mac.")
                )
            }
        }
        .navigationTitle(Text(verbatim: "Claude Code"))
        .navigationSubtitle(navigationSubtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Variable", systemImage: "plus") {
                    guard let source = store.firstMutableSource else { return }
                    editor = EditorState(entry: nil, key: "", value: "", source: source)
                }
                .help("Add a new variable to the env section")
                .disabled(store.firstMutableSource == nil)
            }
        }
        .sheet(item: $editor) { state in
            ClaudeEnvEditor(
                isNew: state.entry == nil,
                key: state.key,
                value: state.value,
                source: state.source,
                secrets: secrets,
                canSelectSource: store.canMutate,
                protectsRevealedSecret: state.entry.map {
                    FeatureFlag.secretsProtection.isEnabled && SecretDetector.isSensitive(name: $0.key)
                } ?? false,
                onSave: { key, value, source in
                    let saved = if let entry = state.entry {
                        store.update(entry, newValue: value)
                    } else {
                        store.add(key: key, value: value, to: source)
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
        .task {
            store.loadIfNeeded()
        }
        .onDisappear {
            store.cancelLoading()
        }
        .onChange(of: store.sourceStatuses) {
            if let editor, !store.canMutate(editor.source) {
                self.editor = nil
            }
            if let pendingDeletion, !store.canMutate(pendingDeletion.source) {
                self.pendingDeletion = nil
            }
        }
        .onChange(of: store.loadState, initial: true) {
            switch store.loadState {
            case .notLoaded, .loading:
                unavailableFocus = .loading
            case .refused:
                unavailableFocus = .refused
            case .loaded:
                unavailableFocus = nil
            }
        }
    }

    /// Subtitle that never reports an invented zero before discovery completes.
    private var navigationSubtitle: Text {
        switch store.loadState {
        case .notLoaded, .loading:
            Text("Loading")
        case .refused:
            Text("Access blocked")
        case .loaded:
            Text(LocalizedCountText.variables(store.envEntries.count))
        }
    }

    /// Accessible progress state shown before any source claims are made.
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading Claude Code configuration...")
                .font(.headline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading Claude Code configuration...")
        .accessibilityFocused($unavailableFocus, equals: .loading)
    }

    /// Root-level refusal that replaces the misleading missing-directory state.
    private func refusedView(reason: ClaudeCodeStore.SourceRefusalReason) -> some View {
        ContentUnavailableView {
            Label("Claude Code configuration access blocked", systemImage: "lock.trianglebadge.exclamationmark")
                .accessibilityFocused($unavailableFocus, equals: .refused)
        } description: {
            VStack(spacing: 6) {
                Text("CodingBuddy refused to read one or more Claude Code sources safely. No configuration contents were exposed.")
                Text(reason.localizedDescription)
            }
        } actions: {
            Button("Retry", systemImage: "arrow.clockwise") {
                store.reload()
            }
            Button("Show in Finder", systemImage: "folder") {
                revealRefusedSources()
            }
            .disabled(store.refusedSourceRevealURLs.isEmpty)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if !store.refusedSources.isEmpty {
                partialRefusalBanner
                Divider()
            }

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

    /// Compact partial-state warning that keeps accepted data visible but identifies refused inputs.
    private var partialRefusalBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Some Claude Code sources are unavailable. Changes are disabled for affected files.")
                    .font(.headline)
                ForEach(Array(store.refusedSources.prefix(4))) { status in
                    if case .refused(let reason) = status.availability {
                        Text(verbatim: "\(status.displayName): \(reason.localizedDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if store.refusedSources.count > 4 {
                    Text("\(store.refusedSources.count - 4) additional sources were refused.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Retry", systemImage: "arrow.clockwise") {
                store.reload()
            }
            Button("Show in Finder", systemImage: "folder") {
                revealRefusedSources()
            }
            .disabled(store.refusedSourceRevealURLs.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    /// Reveals only loader-approved recovery locations without rendering absolute paths.
    private func revealRefusedSources() {
        let urls = store.refusedSourceRevealURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
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
    /// Whether the sheet creates a new key rather than editing an existing one.
    let isNew: Bool
    /// Validated save action owned by the parent Claude Code view.
    let onSave: (String, String, ClaudeCodeStore.EnvEntry.Source) -> Bool
    /// Dismissal action that performs no mutation.
    let onCancel: () -> Void
    /// Reports a dirty draft discarded by automatic expiry.
    let onAutomaticDiscard: () -> Void
    /// Current source-level authorization for the destination picker and save button.
    let canSelectSource: (ClaudeCodeStore.EnvEntry.Source) -> Bool

    /// Draft environment variable name.
    @State var key: String
    /// Draft environment variable value.
    @State var value: String
    /// Destination settings file for new entries.
    @State var source: ClaudeCodeStore.EnvEntry.Source
    /// Shared authentication state that bounds this draft's cleartext lifetime.
    var secrets: SecretsGuard
    /// Whether this editor received an existing sensitive value after authentication.
    let protectsRevealedSecret: Bool
    /// Initial fields used to detect a dirty draft.
    private let originalKey: String
    private let originalValue: String
    private let originalSource: ClaudeCodeStore.EnvEntry.Source

    /// Creates a draft editor with an immutable comparison snapshot.
    init(
        isNew: Bool,
        key: String,
        value: String,
        source: ClaudeCodeStore.EnvEntry.Source,
        secrets: SecretsGuard,
        canSelectSource: @escaping (ClaudeCodeStore.EnvEntry.Source) -> Bool,
        protectsRevealedSecret: Bool,
        onSave: @escaping (String, String, ClaudeCodeStore.EnvEntry.Source) -> Bool,
        onCancel: @escaping () -> Void,
        onAutomaticDiscard: @escaping () -> Void
    ) {
        self.isNew = isNew
        _key = State(initialValue: key)
        _value = State(initialValue: value)
        _source = State(initialValue: source)
        self.secrets = secrets
        self.canSelectSource = canSelectSource
        self.protectsRevealedSecret = protectsRevealedSecret
        self.onSave = onSave
        self.onCancel = onCancel
        self.onAutomaticDiscard = onAutomaticDiscard
        originalKey = key
        originalValue = value
        originalSource = source
    }

    /// Whether closing the editor would lose a changed field.
    private var hasUnsavedChanges: Bool {
        key != originalKey || value != originalValue || source != originalSource
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
                    Picker("File", selection: $source) {
                        ForEach(ClaudeCodeStore.EnvEntry.Source.allCases, id: \.self) { source in
                            Text(verbatim: source.fileName)
                                .tag(source)
                                .disabled(!canSelectSource(source))
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { _ = onSave(key, value, source) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(key.isEmpty || !canSelectSource(source))
            }
        }
        .padding(16)
        .frame(width: 420)
        .protectsSecretDraft(
            secrets: secrets,
            protectsRevealedSecret: protectsRevealedSecret,
            currentName: key,
            hasUnsavedChanges: hasUnsavedChanges,
            canSave: !key.isEmpty && canSelectSource(source),
            saveAndDismiss: { onSave(key, value, source) },
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
