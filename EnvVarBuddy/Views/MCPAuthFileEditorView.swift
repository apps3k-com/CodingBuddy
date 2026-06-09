//
//  MCPAuthFileEditorView.swift
//  EnvVarBuddy
//

import SwiftUI

/// Shows the credential files of one MCP server. Token values are masked;
/// after Touch ID / password authentication the raw content becomes editable
/// (JSON files are validated before saving).
struct MCPAuthFileEditorView: View {
    let store: MCPAuthStore
    var secrets: SecretsGuard
    let entry: MCPAuthEntry

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFileID: MCPAuthFile.ID?
    @State private var text = ""
    /// Once authenticated, the sheet stays editable until it is dismissed.
    @State private var isEditing = false

    private var selectedFile: MCPAuthFile? {
        entry.files.first { $0.id == selectedFileID } ?? entry.files.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(entry.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Picker("File", selection: $selectedFileID) {
                    ForEach(entry.files) { file in
                        Text(verbatim: file.fileName).tag(Optional(file.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(12)

            Divider()

            Group {
                if isEditing {
                    TextEditor(text: $text)
                        .monospaced()
                        .scrollContentBackground(.hidden)
                        .padding(8)
                } else {
                    ScrollView {
                        Text(verbatim: maskedPreview)
                            .monospaced()
                            .textSelection(.disabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                if !isEditing {
                    Button("Unlock to view and edit", systemImage: "lock") { unlock() }
                    Text("Token values are masked until you authenticate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if isEditing {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedFile == nil)
                }
            }
            .padding(12)
        }
        .frame(width: 600, height: 460)
        .onAppear {
            selectedFileID = entry.files.first?.id
        }
        .onChange(of: selectedFileID) {
            if isEditing { loadSelectedFile() }
        }
    }

    private var maskedPreview: String {
        guard let file = selectedFile, let raw = try? store.contents(of: file) else { return "" }
        return MCPAuthRedactor.maskedPreview(text: raw, isJSON: file.isJSON)
    }

    private func unlock() {
        Task {
            if await secrets.requestUnlock() {
                isEditing = true
                loadSelectedFile()
            }
        }
    }

    private func loadSelectedFile() {
        guard let file = selectedFile else { return }
        text = (try? store.contents(of: file)) ?? ""
    }

    private func save() {
        guard let file = selectedFile else { return }
        store.save(text, to: file)
    }
}
