//
//  EnvKeyValueTable.swift
//  CodingBuddy
//

import AppKit
import SwiftUI

/// Masked key/value table shared by the AI tool sections (Codex env files,
/// Claude/Cursor env blocks). Rows are plain data — each section maps its own
/// model and handles edits through the callbacks.
struct EnvKeyValueTable: View {
    struct Row: Identifiable, Hashable {
        let id: String
        var name: String
        var value: String
        var isEditable = true
        /// Optional origin shown under the name (e.g. "settings.json").
        var sourceLabel: String?
    }

    var rows: [Row]
    var secrets: SecretsGuard
    var onEdit: ((Row) -> Void)?
    var onDelete: ((Row) -> Void)?

    @State private var selection: Row.ID?

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { row in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: row.name)
                            .fontWeight(.medium)
                        if !row.isEditable {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.tertiary)
                                .help("Complex line — CodingBuddy only displays it and never modifies it.")
                        }
                    }
                    if let sourceLabel = row.sourceLabel {
                        Text(verbatim: sourceLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 160, ideal: 260)

            TableColumn("Value") { row in
                if isMasked(row) {
                    Text(verbatim: "••••••••")
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .help("Authenticate to reveal this value.")
                } else {
                    Text(verbatim: row.value)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(row.value)
                }
            }
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if let row = rows.first(where: { $0.id == ids.first }) {
                if let onEdit {
                    Button("Edit…") { withUnlockIfNeeded(for: row) { onEdit(row) } }
                        .disabled(!row.isEditable)
                }
                Divider()
                Button("Copy Name") { copy(row.name) }
                Button("Copy Value") { withUnlockIfNeeded(for: row) { copy(row.value) } }
                if let onDelete {
                    Divider()
                    Button("Delete…", role: .destructive) { onDelete(row) }
                        .disabled(!row.isEditable)
                }
            }
        } primaryAction: { ids in
            if let onEdit, let row = rows.first(where: { $0.id == ids.first }), row.isEditable {
                withUnlockIfNeeded(for: row) { onEdit(row) }
            }
        }
    }

    private func isMasked(_ row: Row) -> Bool {
        FeatureFlag.secretsProtection.isEnabled
            && SecretDetector.isSensitive(name: row.name)
            && !secrets.isUnlocked
    }

    private func withUnlockIfNeeded(for row: Row, _ action: @escaping @MainActor () -> Void) {
        guard isMasked(row) else {
            action()
            return
        }
        Task {
            if await secrets.requestUnlock() { action() }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
