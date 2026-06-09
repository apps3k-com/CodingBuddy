//
//  VariableListView.swift
//  EnvVarBuddy
//

import AppKit
import SwiftUI

struct VariableListView: View {
    var store: EnvStore
    var scope: SidebarScope

    @State private var searchText = ""
    @State private var selection: EnvVariable.ID?
    @State private var editorMode: VariableEditorView.Mode?
    @State private var pendingDeletion: EnvVariable?

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
                            .help("Komplexe Zeile — EnvVarBuddy zeigt sie nur an und verändert sie nicht.")
                    }
                    if store.isOverridden(variable) {
                        OverriddenBadge()
                    }
                }
            }
            .width(min: 140, ideal: 220)

            TableColumn("Wert") { variable in
                Text(variable.rawValue)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(variable.rawValue)
            }

            TableColumn("Quelle") { variable in
                Text(variable.file.displayName)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: EnvVariable.ID.self) { ids in
            if let variable = variable(for: ids.first) {
                Button("Bearbeiten…") { editorMode = .edit(variable) }
                    .disabled(!variable.isEditable)
                Divider()
                Button("Name kopieren") { copy(variable.name) }
                Button("Wert kopieren") { copy(variable.rawValue) }
                Button("Zeile kopieren") { copy(variable.sourceLine) }
                Divider()
                Button("Löschen…", role: .destructive) { pendingDeletion = variable }
                    .disabled(!variable.isEditable)
            }
        } primaryAction: { ids in
            if let variable = variable(for: ids.first), variable.isEditable {
                editorMode = .edit(variable)
            }
        }
        .searchable(text: $searchText, prompt: "Variablen durchsuchen")
        .navigationTitle(scope.title)
        .navigationSubtitle("\(filtered.count) Variablen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Neue Variable", systemImage: "plus") {
                    editorMode = .new(scope.file ?? .zshrc)
                }
                .help("Neue Variable anlegen")
            }
        }
        .sheet(item: $editorMode) { mode in
            VariableEditorView(store: store, mode: mode)
        }
        .confirmationDialog(
            "„\(pendingDeletion?.name ?? "")“ aus \(pendingDeletion?.file.displayName ?? "") löschen?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                if let variable = pendingDeletion { store.delete(variable) }
                pendingDeletion = nil
            }
        } message: {
            Text("Vor dem Schreiben wird automatisch ein Backup der Datei angelegt.")
        }
        .overlay {
            if filtered.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "Keine Variablen",
                        systemImage: "shippingbox",
                        description: Text("Mit ＋ legst du die erste Variable an.")
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

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private struct OverriddenBadge: View {
    var body: some View {
        Text("überschrieben")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
            .help("Eine spätere Zuweisung überschreibt diesen Wert in neuen Terminal-Sessions.")
    }
}
