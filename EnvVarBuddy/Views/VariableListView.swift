//
//  VariableListView.swift
//  EnvVarBuddy
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VariableListView: View {
    var store: EnvStore
    var secrets: SecretsGuard
    var scope: SidebarScope

    @Environment(MenuActions.self) private var menuActions
    @AppStorage("groupOverriddenVariables") private var groupOverridden = false
    @State private var searchText = ""
    @State private var selection: EnvVariable.ID?
    @State private var editorMode: VariableEditorView.Mode?
    @State private var pendingDeletion: EnvVariable?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var importPayload: ImportPayload?

    private struct ImportPayload: Identifiable {
        let id = UUID()
        var entries: [EnvFileEntry]
    }

    private var filtered: [EnvVariable] {
        let scoped = store.variables(in: scope.file)
        guard !searchText.isEmpty else { return scoped }
        return scoped.filter {
            // Masked values are excluded from value search: matching them
            // would confirm a secret's presence without authentication.
            $0.name.localizedCaseInsensitiveContains(searchText)
                || (!isMasked($0) && $0.rawValue.localizedCaseInsensitiveContains(searchText))
        }
    }

    /// One group per variable name: the assignment that takes effect as the
    /// parent, shadowed assignments (newest first) as children.
    private struct VariableGroup: Identifiable {
        var effective: EnvVariable
        var overridden: [EnvVariable]
        var id: EnvVariable.ID { effective.id }
    }

    private var groups: [VariableGroup] {
        Dictionary(grouping: filtered, by: \.name).values
            .compactMap { assignments in
                let ordered = assignments.sorted {
                    ($0.file.loadOrder, $0.lineIndex) < ($1.file.loadOrder, $1.lineIndex)
                }
                guard let effective = ordered.last else { return nil }
                return VariableGroup(effective: effective, overridden: ordered.dropLast().reversed())
            }
            .sorted { $0.effective.name < $1.effective.name }
    }

    private var isGrouping: Bool {
        FeatureFlag.groupedOverridesView.isEnabled && groupOverridden
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
                            .help("Complex line — EnvVarBuddy only displays it and never modifies it.")
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
            if isGrouping {
                ForEach(groups) { group in
                    if group.overridden.isEmpty {
                        TableRow(group.effective)
                    } else {
                        DisclosureTableRow(group.effective) {
                            ForEach(group.overridden) { TableRow($0) }
                        }
                    }
                }
            } else {
                ForEach(filtered) { TableRow($0) }
            }
        }
        .contextMenu(forSelectionType: EnvVariable.ID.self) { ids in
            if let variable = variable(for: ids.first) {
                Button("Edit…") { edit(variable) }
                    .disabled(!variable.isEditable)
                Divider()
                Button("Copy Name") { copy(variable.name) }
                Button("Copy Value") { copyValue(of: variable) }
                Button("Copy Line") { copyLine(of: variable) }
                Divider()
                Button("Delete…", role: .destructive) { pendingDeletion = variable }
                    .disabled(!variable.isEditable)
            }
        } primaryAction: { ids in
            if let variable = variable(for: ids.first) {
                edit(variable)
            }
        }
        .searchable(text: $searchText, prompt: "Search variables")
        .navigationTitle(scope.title)
        .navigationSubtitle(Text("\(filtered.count) variables"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Variable", systemImage: "plus") {
                    editorMode = .new(scope.file ?? .zshrc)
                }
                .help("Add a new variable")
            }
            if FeatureFlag.groupedOverridesView.isEnabled {
                ToolbarItem {
                    Toggle("Group overridden", systemImage: "list.bullet.indent", isOn: $groupOverridden)
                        .help("Show overridden assignments grouped under the effective one")
                }
            }
            if FeatureFlag.envImportExport.isEnabled {
                ToolbarItem {
                    Menu {
                        Button("Import from .env…") { isImporting = true }
                        Button("Export visible as .env…") { requestExport() }
                            .disabled(filtered.allSatisfy { !$0.isEditable })
                    } label: {
                        Label("Import/Export", systemImage: "square.and.arrow.up.on.square")
                    }
                    .help("Import or export .env files")
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
            document: EnvFileDocument(text: EnvFileCodec.encode(filtered)),
            contentType: EnvFileCodec.contentType,
            defaultFilename: "variables.env"
        ) { result in
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
            VariableEditorView(store: store, mode: mode)
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
            // Reloads rebuild the list with fresh line indices; re-resolve the
            // selected id so the selection survives shifting lines.
            let resolved = SelectionResolver.resolve(selection, from: oldVariables, in: newVariables)
            if resolved != selection { selection = resolved }
        }
        .onChange(of: menuActions.importRequest) {
            if FeatureFlag.envImportExport.isEnabled { isImporting = true }
        }
        .onChange(of: menuActions.exportRequest) {
            if FeatureFlag.envImportExport.isEnabled { requestExport() }
        }
        .overlay {
            if filtered.isEmpty {
                if searchText.isEmpty {
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

    /// Runs `action` immediately, or after successful authentication when the
    /// variable's value is currently masked.
    private func withUnlockIfNeeded(for variable: EnvVariable, _ action: @escaping @MainActor () -> Void) {
        guard isMasked(variable) else {
            action()
            return
        }
        Task {
            if await secrets.requestUnlock() { action() }
        }
    }

    private func edit(_ variable: EnvVariable) {
        guard variable.isEditable else { return }
        withUnlockIfNeeded(for: variable) { editorMode = .edit(variable) }
    }

    private func copyValue(of variable: EnvVariable) {
        withUnlockIfNeeded(for: variable) { copy(variable.rawValue) }
    }

    private func copyLine(of variable: EnvVariable) {
        withUnlockIfNeeded(for: variable) { copy(variable.sourceLine) }
    }

    /// Exporting reveals values in the written file — authenticate first when
    /// any visible variable is masked.
    private func requestExport() {
        if let masked = filtered.first(where: { isMasked($0) }) {
            withUnlockIfNeeded(for: masked) { isExporting = true }
        } else {
            isExporting = true
        }
    }

    private func readImportFile(at url: URL) {
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
