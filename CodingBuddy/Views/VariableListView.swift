//
//  VariableListView.swift
//  CodingBuddy
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Searchable zsh assignment table with guarded secret disclosure and safe mutations.
struct VariableListView: View {
    /// Store owning parsed assignments and all shell-file mutations.
    var store: EnvStore
    /// Authentication state controlling reveal and copy actions for secrets.
    var secrets: SecretsGuard
    /// Sidebar scope limiting the displayed and exported assignments.
    var scope: SidebarScope

    @AppStorage("hideOverriddenVariables") private var hideOverridden = false
    @State private var searchText = ""
    @State private var selection: EnvVariable.ID?
    @State private var editorMode: VariableEditorView.Mode?
    @State private var pendingDeletion: EnvVariable?
    @State private var isExporting = false
    @State private var exportDocument: EnvFileDocument?
    @State private var isImporting = false
    @State private var importPayload: ImportPayload?
    @State private var secretActionGeneration = 0
    @AccessibilityFocusState private var accessRefusalFocused: Bool

    private struct ImportPayload: Identifiable {
        /// Session-local identity used to present the import preview sheet.
        let id = UUID()
        /// Parsed dotenv entries awaiting user selection and target choice.
        var entries: [EnvFileEntry]
    }

    private var isHiding: Bool {
        FeatureFlag.hideOverriddenVariables.isEnabled && hideOverridden
    }

    /// Completeness and action policy for the selected sidebar scope.
    private var accessState: EnvScopeAccessState {
        store.accessState(in: scope.file)
    }

    /// Whether the current scope may start mutations or data transfer.
    private var actionsAvailable: Bool {
        accessState.allowsActions
    }

    /// Parsed assignments before search filtering.
    private var scopedVariables: [EnvVariable] {
        store.variables(in: scope.file, hidingOverridden: isHiding)
    }

    /// What the table shows — and exactly what the .env export writes.
    private var filtered: [EnvVariable] {
        guard !searchText.isEmpty else { return scopedVariables }
        return scopedVariables.filter {
            // Masked values are excluded from value search: matching them
            // would confirm a secret's presence without authentication.
            $0.name.localizedCaseInsensitiveContains(searchText)
                || (!isMasked($0) && $0.rawValue.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        Table(of: EnvVariable.self, selection: $selection) {
            TableColumn("Name") { variable in
                HStack(spacing: 6) {
                    Text(variable.name)
                        .fontWeight(.medium)
                    if !variable.isEditable {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.tertiary)
                            .help("Complex line — CodingBuddy only displays it and never modifies it.")
                    }
                    if store.isOverridden(variable) {
                        OverriddenBadge()
                    }
                }
            }
            .width(min: 140, ideal: 220)

            TableColumn("Value") { variable in
                if isMasked(variable) {
                    Text(verbatim: "••••••••")
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .help("Authenticate to reveal this value.")
                } else {
                    Text(variable.rawValue)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(variable.rawValue)
                }
            }

            TableColumn("Source") { variable in
                Text(variable.file.rawValue)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        } rows: {
            ForEach(filtered) { TableRow($0) }
        }
        .contextMenu(forSelectionType: EnvVariable.ID.self) { ids in
            if let variable = variable(for: ids.first) {
                Button("Edit…") { edit(variable) }
                    .disabled(!actionsAvailable || !variable.isEditable)
                Divider()
                Button("Copy Name") { copy(variable.name) }
                Button("Copy Value") { copyValue(of: variable) }
                Button("Copy Line") { copyLine(of: variable) }
                Divider()
                Button("Delete…", role: .destructive) { pendingDeletion = variable }
                    .disabled(!actionsAvailable || !variable.isEditable)
            }
        } primaryAction: { ids in
            if let variable = variable(for: ids.first) {
                edit(variable)
            }
        }
        .searchable(text: $searchText, prompt: "Search variables")
        .navigationTitle(scope.title)
        .navigationSubtitle(navigationSubtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Variable", systemImage: "plus") {
                    editorMode = .new(scope.file ?? .zshrc)
                }
                .help("Add a new variable")
                .disabled(!actionsAvailable)
            }
            if FeatureFlag.hideOverriddenVariables.isEnabled {
                ToolbarItem {
                    Toggle("Hide overridden", systemImage: "eye.slash", isOn: $hideOverridden)
                        .help("Show only the assignments that take effect — the .env export then also includes only these")
                }
            }
            if FeatureFlag.envImportExport.isEnabled {
                ToolbarItem {
                    Menu {
                        Button("Import from .env…") { beginImport() }
                        Button("Export visible as .env…") { requestExport() }
                            .disabled(filtered.allSatisfy { !$0.isEditable })
                    } label: {
                        Label("Import/Export", systemImage: "square.and.arrow.up.on.square")
                    }
                    .help("Import or export .env files")
                    .disabled(!actionsAvailable)
                }
            }
            if FeatureFlag.secretsProtection.isEnabled,
               store.variables.contains(where: { SecretDetector.isSensitive(name: $0.name) }) {
                ToolbarItem {
                    if secrets.isUnlocked {
                        Button("Hide secrets", systemImage: "lock.open") { secrets.lock() }
                            .help("Hide secrets")
                    } else {
                        Button("Reveal secrets", systemImage: "lock") {
                            Task { _ = await secrets.requestUnlock() }
                        }
                        .help("Reveal secrets")
                    }
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: EnvFileCodec.contentType,
            defaultFilename: "variables.env"
        ) { result in
            exportDocument = nil
            if case .failure(let error) = result {
                store.lastError = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [EnvFileCodec.contentType, .plainText]
        ) { result in
            switch result {
            case .success(let url):
                readImportFile(at: url)
            case .failure(let error):
                store.lastError = error.localizedDescription
            }
        }
        .sheet(item: $importPayload) { payload in
            ImportPreviewView(store: store, entries: payload.entries)
        }
        .sheet(item: $editorMode) { mode in
            VariableEditorView(store: store, secrets: secrets, mode: mode)
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")” from \(pendingDeletion?.file.rawValue ?? "")?",
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
        .onChange(of: store.variables) { oldVariables, newVariables in
            invalidatePendingSecretAction()
            // Reloads rebuild the list with fresh line indices; re-resolve the
            // selected id so the selection survives shifting lines.
            let resolved = SelectionResolver.resolve(selection, from: oldVariables, in: newVariables)
            if resolved != selection { selection = resolved }
        }
        .onChange(of: accessState, initial: true) { _, newState in
            invalidatePendingSecretAction()
            if !newState.allowsActions {
                cancelUnavailableActions()
                accessRefusalFocused = true
            } else {
                accessRefusalFocused = false
            }
        }
        .onChange(of: scope) {
            invalidatePendingSecretAction()
        }
        .onChange(of: searchText) {
            invalidatePendingSecretAction()
        }
        .onChange(of: hideOverridden) {
            invalidatePendingSecretAction()
        }
        .onChange(of: secrets.isUnlocked) { _, isUnlocked in
            if !isUnlocked {
                invalidatePendingSecretAction()
                isExporting = false
                exportDocument = nil
            }
        }
        .onChange(of: isExporting) { _, isPresented in
            if !isPresented { exportDocument = nil }
        }
        .onDisappear { invalidatePendingSecretAction() }
        .focusedSceneValue(\.envTransferCommandActions, transferCommandActions)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !accessState.isComplete, !filtered.isEmpty {
                accessStatusBanner
            }
        }
        .overlay {
            if filtered.isEmpty {
                if !accessState.isComplete {
                    refusedUnavailableView
                } else if searchText.isEmpty {
                    ContentUnavailableView(
                        "No Variables",
                        systemImage: "shippingbox",
                        description: Text("Use ＋ to add your first variable.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    /// Localized subtitle that never presents an incomplete row count as complete.
    private var navigationSubtitle: Text {
        if accessState.isComplete {
            Text(LocalizedCountText.variables(filtered.count))
        } else {
            Text("Incomplete data")
        }
    }

    /// Heading for a single refused file or a partially loaded multi-file scope.
    private var accessTitle: LocalizedStringKey {
        accessState.refusals.count == 1
            ? "Shell file unavailable"
            : "Some shell files are unavailable"
    }

    /// Inline status used when valid rows from other files remain available.
    private var accessStatusBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(accessTitle, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
                .accessibilityLabel(Text("Shell file access blocked"))
                .accessibilityFocused($accessRefusalFocused)
            refusalDetails
            Text("This view is incomplete. Changes, import, and export are disabled.")
                .foregroundStyle(.secondary)
            accessRecoveryActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Full unavailable state used when the incomplete scope has no visible rows.
    private var refusedUnavailableView: some View {
        ContentUnavailableView {
            Label(accessTitle, systemImage: "exclamationmark.triangle")
                .accessibilityLabel(Text("Shell file access blocked"))
                .accessibilityFocused($accessRefusalFocused)
        } description: {
            VStack(spacing: 6) {
                refusalDetails
                Text("This view is incomplete. Changes, import, and export are disabled.")
            }
        } actions: {
            accessRecoveryActions
        }
    }

    /// Safe file names and categorized reasons for every refused source.
    private var refusalDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(accessState.refusals) { refusal in
                Text(verbatim: "\(refusal.file.rawValue): \(refusal.reason.localizedDescription)")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Focusable recovery commands shared by the inline and empty states.
    private var accessRecoveryActions: some View {
        HStack {
            Button("Retry", systemImage: "arrow.clockwise") {
                store.reload()
            }
            Button("Show in Finder", systemImage: "folder") {
                revealRefusedFiles()
            }
        }
    }

    private func variable(for id: EnvVariable.ID?) -> EnvVariable? {
        filtered.first { $0.id == id }
    }

    // MARK: - Secrets gating

    private func isProtected(_ variable: EnvVariable) -> Bool {
        FeatureFlag.secretsProtection.isEnabled && SecretDetector.isSensitive(name: variable.name)
    }

    private func isMasked(_ variable: EnvVariable) -> Bool {
        isProtected(variable) && !secrets.isUnlocked
    }

    /// Runs `action` only while the authenticated row and visible snapshot remain unchanged.
    private func withUnlockIfNeeded(
        for variable: EnvVariable,
        _ action: @escaping @MainActor (EnvVariable) -> Void
    ) {
        let snapshot = SecretActionSnapshot(generation: secretActionGeneration, value: variable)
        let runIfCurrent: @MainActor () -> Void = {
            guard actionsAvailable,
                  let current = snapshot.resolve(
                      currentGeneration: secretActionGeneration,
                      in: filtered
                  ) else { return }
            action(current)
        }
        guard isMasked(variable) else {
            runIfCurrent()
            return
        }
        Task {
            guard await secrets.requestUnlock() else { return }
            runIfCurrent()
        }
    }

    private func edit(_ variable: EnvVariable) {
        guard actionsAvailable, variable.isEditable else { return }
        withUnlockIfNeeded(for: variable) { current in editorMode = .edit(current) }
    }

    private func copyValue(of variable: EnvVariable) {
        withUnlockIfNeeded(for: variable) { current in copy(current.rawValue) }
    }

    private func copyLine(of variable: EnvVariable) {
        withUnlockIfNeeded(for: variable) { current in copy(current.sourceLine) }
    }

    /// Exporting reveals values in the written file — authenticate first when
    /// any visible variable is masked.
    private func requestExport() {
        guard actionsAvailable else { return }
        let expectedVariables = filtered
        if let masked = expectedVariables.first(where: { isMasked($0) }) {
            withUnlockIfNeeded(for: masked) { _ in
                guard actionsAvailable, filtered == expectedVariables else { return }
                presentExport(of: expectedVariables)
            }
        } else {
            presentExport(of: expectedVariables)
        }
    }

    /// Freezes the authorized visible rows before presenting the asynchronous save panel.
    private func presentExport(of variables: [EnvVariable]) {
        exportDocument = EnvFileDocument(text: EnvFileCodec.encode(variables))
        isExporting = true
    }

    /// Presents the importer only while the current snapshot is complete.
    private func beginImport() {
        guard actionsAvailable else { return }
        isImporting = true
    }

    /// Menu actions exist only for the active feature and a complete source snapshot.
    private var transferCommandActions: EnvTransferCommandActions? {
        guard FeatureFlag.envImportExport.isEnabled, actionsAvailable else { return nil }
        let importAction: () -> Void = { beginImport() }
        let exportAction: (() -> Void)?
        if filtered.contains(where: \.isEditable) {
            exportAction = { requestExport() }
        } else {
            exportAction = nil
        }
        return EnvTransferCommandActions(
            importEnvironment: importAction,
            exportEnvironment: exportAction
        )
    }

    /// Invalidates asynchronous disclosure work after any relevant presentation change.
    private func invalidatePendingSecretAction() {
        secretActionGeneration &+= 1
    }

    private func readImportFile(at url: URL) {
        guard actionsAvailable else { return }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            store.lastError = String(localized: "The file could not be read.")
            return
        }
        let entries = EnvFileCodec.decode(content)
        if entries.isEmpty {
            store.lastError = String(localized: "No variables were found in the file.")
        } else {
            importPayload = ImportPayload(entries: entries)
        }
    }

    /// Dismisses action UI if a watcher reload discovers a refused source.
    private func cancelUnavailableActions() {
        editorMode = nil
        pendingDeletion = nil
        isExporting = false
        exportDocument = nil
        isImporting = false
        importPayload = nil
    }

    /// Reveals refused files without displaying their absolute paths in the app.
    private func revealRefusedFiles() {
        let urls = accessState.refusals.map { $0.file.url(in: store.homeDirectory) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private struct OverriddenBadge: View {
    var body: some View {
        Text("overridden")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
            .help("A later assignment overrides this value in new terminal sessions.")
    }
}
