//
//  ImportPreviewView.swift
//  EnvVarBuddy
//

import SwiftUI

/// Shows the entries found in a .env file and lets the user pick which ones
/// to append to the managed block of a target file.
struct ImportPreviewView: View {
    let store: EnvStore
    let entries: [EnvFileEntry]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<EnvFileEntry.ID>
    @State private var targetFile: ShellConfigFile = .zshrc

    init(store: EnvStore, entries: [EnvFileEntry]) {
        self.store = store
        self.entries = entries
        _selectedIDs = State(initialValue: Set(entries.map(\.id)))
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(entries) { entry in
                    HStack {
                        Toggle(isOn: binding(for: entry.id)) {
                            HStack {
                                Text(entry.name)
                                    .fontWeight(.medium)
                                Text(entry.rawValue)
                                    .monospaced()
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if store.variables.contains(where: { $0.name == entry.name }) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .help("„\(entry.name)“ ist bereits definiert.")
                        }
                    }
                }
            }

            Divider()

            HStack {
                Picker("Ziel:", selection: $targetFile) {
                    ForEach(ShellConfigFile.allCases) { file in
                        Text(file.displayName).tag(file)
                    }
                }
                .fixedSize()
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("\(selectedIDs.count) importieren") { importSelected() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIDs.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 360)
    }

    private func binding(for id: EnvFileEntry.ID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isOn in
                if isOn { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
            }
        )
    }

    private func importSelected() {
        let chosen = entries
            .filter { selectedIDs.contains($0.id) }
            .map { (name: $0.name, rawValue: $0.rawValue) }
        store.addAll(chosen, to: targetFile)
        dismiss()
    }
}
