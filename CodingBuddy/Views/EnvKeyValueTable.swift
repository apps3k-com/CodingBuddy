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
    /// Presentation-safe environment row independent of any tool-specific model.
    struct Row: Identifiable, Hashable {
        /// Stable identity supplied by the owning tool section.
        let id: String
        /// Environment variable name.
        var name: String
        /// Raw value that remains masked until authorization when sensitive.
        var value: String
        /// Whether source syntax can be safely round-tripped by the owning store.
        var isEditable = true
        /// Optional origin shown under the name (e.g. "settings.json").
        var sourceLabel: String?
    }

    /// Rows supplied by the owning configuration section.
    var rows: [Row]
    /// Authentication state used before revealing or copying sensitive values.
    var secrets: SecretsGuard
    /// Optional edit action for safely round-trippable rows.
    var onEdit: ((Row) -> Void)?
    /// Optional destructive action owned by the parent workflow.
    var onDelete: ((Row) -> Void)?

    @State private var selection: Row.ID?
    @State private var secretActionGeneration = 0

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
                    Button("Edit…") { withUnlockIfNeeded(for: row, onEdit) }
                        .disabled(!row.isEditable)
                }
                Divider()
                Button("Copy Name") { copy(row.name) }
                Button("Copy Value") {
                    withUnlockIfNeeded(for: row) { current in copy(current.value) }
                }
                if let onDelete {
                    Divider()
                    Button("Delete…", role: .destructive) { onDelete(row) }
                        .disabled(!row.isEditable)
                }
            }
        } primaryAction: { ids in
            if let onEdit, let row = rows.first(where: { $0.id == ids.first }), row.isEditable {
                withUnlockIfNeeded(for: row, onEdit)
            }
        }
        .onChange(of: rows) {
            secretActionGeneration &+= 1
            if !rows.contains(where: { $0.id == selection }) { selection = nil }
        }
        .onDisappear { secretActionGeneration &+= 1 }
    }

    private func isMasked(_ row: Row) -> Bool {
        FeatureFlag.secretsProtection.isEnabled
            && SecretDetector.isSensitive(name: row.name)
            && !secrets.isUnlocked
    }

    /// Authenticates a disclosure action and rejects it if the owning store replaced the row.
    private func withUnlockIfNeeded(
        for row: Row,
        _ action: @escaping @MainActor (Row) -> Void
    ) {
        let snapshot = SecretActionSnapshot(generation: secretActionGeneration, value: row)
        let runIfCurrent: @MainActor () -> Void = {
            guard let current = snapshot.resolve(
                currentGeneration: secretActionGeneration,
                in: rows
            ) else { return }
            action(current)
        }
        guard isMasked(row) else {
            runIfCurrent()
            return
        }
        Task {
            guard await secrets.requestUnlock() else { return }
            runIfCurrent()
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
