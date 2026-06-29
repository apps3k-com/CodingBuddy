//
//  BackupBrowserView.swift
//  CodingBuddy
//

import SwiftUI

/// Table and preview UI for CodingBuddy-managed backup files.
struct BackupBrowserView: View {
    /// Observable backup browser state.
    var store: BackupBrowserStore

    /// Currently selected backup row.
    @State private var selection: BackupBrowserItem.ID?
    /// Search text applied across source, backup filename, target, and status.
    @State private var searchText = ""
    /// Row pending destructive restore confirmation.
    @State private var restoreCandidate: BackupBrowserItem?
    /// Last restore failure shown as an alert.
    @State private var restoreError: String?

    /// Backup rows after applying the current search filter.
    private var filteredItems: [BackupBrowserItem] {
        store.items.filter { $0.matches(searchText: searchText) }
    }

    /// Selected row object, if it is still visible.
    private var selectedItem: BackupBrowserItem? {
        selection.flatMap { id in filteredItems.first { $0.id == id } }
    }

    /// Native split layout: backup table on the left, preview on the right.
    var body: some View {
        HSplitView {
            backupTable
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            BackupPreviewPane(store: store, item: selectedItem)
                .frame(minWidth: 360, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Backups")
        .searchable(text: $searchText, prompt: "Search backups")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Restore…", systemImage: "arrow.counterclockwise") {
                    restoreCandidate = selectedItem
                }
                .help("Restore the selected backup")
                .disabled(selectedItem?.canRestore != true)

                Button("Refresh", systemImage: "arrow.clockwise") {
                    store.reload()
                }
                .help("Refresh backups")
            }
        }
        .onAppear {
            store.reload()
        }
        .confirmationDialog(
            "Restore backup?",
            isPresented: Binding(
                get: { restoreCandidate != nil },
                set: { if !$0 { restoreCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: restoreCandidate
        ) { item in
            Button("Restore Backup", role: .destructive) {
                restore(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("CodingBuddy will back up the current target before replacing it with the selected backup.")
            Text(verbatim: item.targetURL?.path ?? item.backupURL.lastPathComponent)
        }
        .alert(
            "Restore Failed",
            isPresented: Binding(
                get: { restoreError != nil },
                set: { if !$0 { restoreError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreError ?? "")
        }
    }

    /// Native table for discovered backups.
    private var backupTable: some View {
        Table(filteredItems, selection: $selection) {
            TableColumn("Source") { item in
                Text(verbatim: item.sourceDisplayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .width(min: 150, ideal: 190)

            TableColumn("Backup") { item in
                Text(verbatim: item.backupURL.lastPathComponent)
                    .font(.caption)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 220, ideal: 290)

            TableColumn("Size") { item in
                Text(verbatim: formattedBytes(item.byteCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 85, max: 110)

            TableColumn("Status") { item in
                if item.canRestore {
                    Text(item.statusDisplayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(item.statusDisplayName)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .width(min: 95, ideal: 120, max: 145)

            TableColumn("Target") { item in
                Text(verbatim: item.targetURL?.path ?? "—")
                    .font(.caption)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .width(min: 220, ideal: 330)
        }
        .overlay {
            if filteredItems.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "No backups",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("CodingBuddy did not find any backups in the managed backup folder.")
                    )
                } else {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different source, backup file, target path, or status.")
                    )
                }
            }
        }
    }

    /// Performs a confirmed restore and reloads the table.
    private func restore(_ item: BackupBrowserItem) {
        do {
            try store.restore(item)
            store.reload()
            restoreError = nil
            restoreCandidate = nil
            selection = item.id
        } catch {
            restoreError = error.localizedDescription
        }
    }

    /// Formats optional byte counts for compact table display.
    private func formattedBytes(_ bytes: Int?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Read-only preview pane for selected backup contents.
private struct BackupPreviewPane: View {
    /// Store used to load redacted previews.
    var store: BackupBrowserStore
    /// Selected backup row.
    var item: BackupBrowserItem?

    /// Detail pane body.
    var body: some View {
        if let item {
            let preview = store.preview(for: item)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.sourceDisplayName)
                        .font(.headline)
                    Text(verbatim: item.targetURL?.path ?? item.backupURL.lastPathComponent)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                LabeledContent("Saved") {
                    Text(item.timestamp, format: .dateTime.year().month().day().hour().minute().second())
                        .foregroundStyle(.secondary)
                }

                VSplitView {
                    PreviewTextSection(title: String(localized: "Backup"), text: preview.backupText)
                    PreviewTextSection(title: String(localized: "Current"), text: preview.currentText)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "Select a backup",
                systemImage: "clock.arrow.circlepath",
                description: Text("Choose a backup to preview its current target and saved contents.")
            )
        }
    }
}

/// Monospaced read-only text preview section.
private struct PreviewTextSection: View {
    /// Section title.
    var title: String
    /// Redacted text to display.
    var text: String

    /// Section body.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: text.isEmpty ? " " : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
