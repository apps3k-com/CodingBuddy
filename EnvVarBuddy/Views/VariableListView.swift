//
//  VariableListView.swift
//  EnvVarBuddy
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VariableListView: View {
    var store: EnvStore
    var scope: SidebarScope

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
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Table(filtered, selection: $selection) {
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
                Text(variable.rawValue)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(variable.rawValue)
            }

            TableColumn("Source") { variable in
                Text(variable.file.rawValue)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: EnvVariable.ID.self) { ids in
            if let variable = variable(for: ids.first) {
                Button("Edit…") { editorMode = .edit(variable) }
                    .disabled(!variable.isEditable)
                Divider()
                Button("Copy Name") { copy(variable.name) }
                Button("Copy Value") { copy(variable.rawValue) }
                Button("Copy Line") { copy(variable.sourceLine) }
                Divider()
                Button("Delete…", role: .destructive) { pendingDeletion = variable }
                    .disabled(!variable.isEditable)
            }
        } primaryAction: { ids in
            if let variable = variable(for: ids.first), variable.isEditable {
                editorMode = .edit(variable)
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
            if FeatureFlag.envImportExport.isEnabled {
                ToolbarItem {
                    Menu {
                        Button("Import from .env…") { isImporting = true }
                        Button("Export visible as .env…") { isExporting = true }
                            .disabled(filtered.allSatisfy { !$0.isEditable })
                    } label: {
                        Label("Import/Export", systemImage: "square.and.arrow.up.on.square")
                    }
                    .help("Import or export .env files")
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
