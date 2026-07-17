//
//  BackupBrowserView.swift
//  CodingBuddy
//

import Accessibility
import AppKit
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
    /// Last restore failure shown with any retained recovery artifacts.
    @State private var restoreFailure: BackupRestoreFailurePresentation?
    /// VoiceOver target used when backup discovery becomes safety-blocked.
    @AccessibilityFocusState private var discoveryRefusalFocused: Bool
    /// VoiceOver target used when restore recovery remains unresolved.
    @AccessibilityFocusState private var restoreRecoveryFocused: Bool

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
        VStack(spacing: 0) {
            if let restoreRecoveryAttention = store.restoreRecoveryAttention {
                restoreRecoveryBanner(restoreRecoveryAttention)
                Divider()
            }
            HSplitView {
                backupTable
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                BackupPreviewPane(store: store, item: selectedItem)
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
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
                .disabled(selectedItem?.canRestore != true || store.restoreRecoveryAttention != nil)

                Button("Refresh", systemImage: "arrow.clockwise") {
                    reload()
                }
                .help("Refresh backups")
            }
        }
        .onAppear {
            reload()
        }
        .task(id: store.discoveryError) {
            guard let refusal = store.discoveryError else { return }
            await focusAndAnnounceDiscoveryRefusal(refusal)
        }
        .task(id: store.restoreRecoveryAttention) {
            guard let presentation = store.restoreRecoveryAttention else {
                restoreRecoveryFocused = false
                return
            }
            await focusAndAnnounceRestoreRecovery(presentation)
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
            restoreFailure?.title ?? "",
            isPresented: Binding(
                get: { restoreFailure != nil },
                set: { if !$0 { restoreFailure = nil } }
            )
        ) {
            if let recoveryURLs = restoreFailure?.recoveryURLs, !recoveryURLs.isEmpty {
                Button("Show Recovery Files in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(recoveryURLs)
                    restoreFailure = nil
                }
                Button("Copy Recovery Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        recoveryURLs.map(\.path).joined(separator: "\n"),
                        forType: .string
                    )
                    restoreFailure = nil
                }
            }
            Button("OK", role: .cancel) { restoreFailure = nil }
        } message: {
            Text(restoreFailure?.message ?? "")
        }
    }

    /// Persistent recovery band kept visible after the one-time alert is dismissed.
    private func restoreRecoveryBanner(_ presentation: BackupRestoreFailurePresentation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .fontWeight(.medium)
                    .accessibilityFocused($restoreRecoveryFocused)
                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { restoreRecoveryActions(presentation) }
                VStack(alignment: .trailing, spacing: 8) { restoreRecoveryActions(presentation) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    /// Finder, clipboard, and explicit resolution actions for retained restore attention.
    @ViewBuilder
    private func restoreRecoveryActions(_ presentation: BackupRestoreFailurePresentation) -> some View {
        if !presentation.recoveryURLs.isEmpty {
            Button("Show Recovery Files in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(presentation.recoveryURLs)
            }
            Button("Copy Recovery Path", systemImage: "doc.on.doc") {
                copyRecoveryPaths(presentation.recoveryURLs)
            }
        }
        Button("Mark Reviewed", systemImage: "checkmark") {
            store.markRestoreRecoveryReviewed()
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
                if item.rejectionReason != nil {
                    Label(item.statusDisplayName, systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if item.canRestore {
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
            if let discoveryError = store.discoveryError {
                ContentUnavailableView {
                    Label("Backups Could Not Be Scanned Safely", systemImage: "exclamationmark.shield")
                        .accessibilityFocused($discoveryRefusalFocused)
                } description: {
                    Text(discoveryError.localizedDescription)
                } actions: {
                    Button("Try Again", systemImage: "arrow.clockwise") { reload() }
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.backupDirectory])
                    }
                }
            } else if filteredItems.isEmpty {
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
            reload()
            restoreFailure = nil
            restoreCandidate = nil
            selection = item.id
        } catch {
            let presentation = BackupRestoreFailurePresentation(error: error)
            restoreFailure = presentation
        }
    }

    /// Reloads backup metadata and announces any fail-closed discovery result.
    private func reload() {
        store.reload()
    }

    /// Moves VoiceOver to the refusal and announces only its sanitized explanation.
    private func focusAndAnnounceDiscoveryRefusal(_ refusal: BackupBrowserScanner.ScanError) async {
        await Task.yield()
        guard store.discoveryError == refusal else { return }
        discoveryRefusalFocused = true
        AccessibilityNotification.Announcement(refusal.localizedDescription).post()
    }

    /// Retains VoiceOver context when a restore needs review after its alert closes.
    private func focusAndAnnounceRestoreRecovery(
        _ presentation: BackupRestoreFailurePresentation
    ) async {
        while restoreFailure != nil {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
        }
        await Task.yield()
        guard !Task.isCancelled,
              store.restoreRecoveryAttention == presentation,
              restoreFailure == nil else { return }
        restoreRecoveryFocused = true
        AccessibilityNotification.Announcement(presentation.message).post()
    }

    /// Copies every retained recovery path without clearing persistent attention.
    private func copyRecoveryPaths(_ recoveryURLs: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            recoveryURLs.map(\.path).joined(separator: "\n"),
            forType: .string
        )
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
            if let rejection = item.rejectionReason {
                ContentUnavailableView {
                    Label("Backup Was Rejected for Safety", systemImage: "exclamationmark.shield")
                } description: {
                    Text(rejection.explanation)
                } actions: {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.backupURL])
                    }
                }
            } else {
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
                        PreviewTextSection(title: String(localized: "Backup"), content: preview.backup)
                        PreviewTextSection(title: String(localized: "Current"), content: preview.current)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
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
    /// Display-safe content and its explicit safety state.
    var content: BackupBrowserPreviewContent

    /// Section body.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Group {
                if case .suppressedForSafety = content {
                    ContentUnavailableView {
                        Label("Preview Hidden for Safety", systemImage: "eye.slash")
                    } description: {
                        Text("CodingBuddy could not safely determine where a shell value ends, so the entire preview is hidden.")
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    ScrollView {
                        Text(verbatim: content.text.isEmpty ? " " : content.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
