import AppKit
import SwiftUI

/// Read-only checklist for repository readiness before agentic coding work.
struct RepoReadinessView: View {
    /// Observable state that owns repository selection and checklist output.
    var store: RepoReadinessStore

    /// Currently selected table row.
    @State private var selection: RepoReadinessItem.ID?

    /// Search text applied across checks, status, source, and remediation.
    @State private var searchText = ""

    /// Checklist rows after applying the current search filter.
    private var filteredItems: [RepoReadinessItem] {
        store.items.filter { $0.matches(searchText: searchText) }
    }

    /// Table-based checklist layout with native folder selection.
    var body: some View {
        Table(filteredItems, selection: $selection) {
            TableColumn("Check") { item in
                CheckSummaryCell(item: item)
            }
            .width(min: 260, ideal: 360)

            TableColumn("Status") { item in
                ReadinessStatusCell(status: item.status)
            }
            .width(min: 105, ideal: 125, max: 150)

            TableColumn("Source") { item in
                Text(verbatim: item.source)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 180, ideal: 250)

            TableColumn("Remediation") { item in
                Text(item.remediationHint)
                    .foregroundStyle(item.status == .pass ? .secondary : .primary)
                    .lineLimit(2)
            }
            .width(min: 280, ideal: 420)
        }
        .navigationTitle("Repo Readiness")
        .navigationSubtitle(Text(verbatim: store.selectedRepositoryURL?.path ?? String(localized: "No repository selected")))
        .searchable(text: $searchText, prompt: "Search readiness checks")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Reveal in Finder", systemImage: "folder") {
                    revealRepository()
                }
                .help("Reveal the selected repository in Finder")
                .disabled(store.selectedRepositoryURL == nil)

                Button("Refresh", systemImage: "arrow.clockwise") {
                    store.reload()
                }
                .help("Refresh readiness checks")
                .disabled(store.selectedRepositoryURL == nil)

                Button("Choose Folder...", systemImage: "folder.badge.plus") {
                    chooseRepositoryFolder()
                }
                .help("Choose repository folder")
            }
        }
        .overlay {
            if store.selectedRepositoryURL == nil {
                ContentUnavailableView(
                    "No repository selected",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Choose a repository folder to run readiness checks.")
                )
            } else if filteredItems.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different check, status, source, or remediation.")
                )
            }
        }
    }

    /// Presents a native macOS folder picker and persists the selected repository.
    private func chooseRepositoryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.selectedRepositoryURL
        panel.message = String(localized: "Choose a repository folder")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        selection = nil
        store.selectRepository(url)
    }

    /// Reveals the selected repository folder in Finder.
    private func revealRepository() {
        guard let selectedRepositoryURL = store.selectedRepositoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selectedRepositoryURL])
    }
}

/// Dense two-line checklist summary for one readiness row.
private struct CheckSummaryCell: View {
    /// Checklist item represented by this row.
    var item: RepoReadinessItem

    /// Localized title with observed detail below it.
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// Compact readiness status indicator for the checklist table.
private struct ReadinessStatusCell: View {
    /// Status represented by this cell.
    var status: RepoReadinessStatus

    /// Label with SF Symbol and localized status text.
    var body: some View {
        Label {
            Text(status.displayName)
        } icon: {
            Image(systemName: status.systemImageName)
                .foregroundStyle(status.tint)
        }
        .lineLimit(1)
    }
}

private extension RepoReadinessStatus {
    /// SF Symbol for this readiness status.
    var systemImageName: String {
        switch self {
        case .pass:
            "checkmark.circle.fill"
        case .warn:
            "exclamationmark.triangle.fill"
        case .fail:
            "xmark.octagon.fill"
        }
    }

    /// Semantic tint for this readiness status.
    var tint: Color {
        switch self {
        case .pass:
            .green
        case .warn:
            .orange
        case .fail:
            .red
        }
    }
}
