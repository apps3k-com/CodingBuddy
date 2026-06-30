import AppKit
import SwiftUI

/// Read-only inspector for agent context files in a selected repository folder.
struct AgentContextInspectorView: View {
    /// Observable state that owns repository selection and scanner output.
    var store: AgentContextInspectorStore
    /// External file opener honoring the default editor preference.
    var fileOpener = ExternalFileOpener()

    /// Currently selected table row.
    @State private var selection: AgentContextItem.ID?

    /// Search text applied across paths, kinds, types, and signals.
    @State private var searchText = ""
    /// Non-blocking file-open warning shown after graceful fallback.
    @State private var openWarning: String?
    /// Identifier that restarts the warning auto-dismiss timer.
    @State private var openWarningID = UUID()

    /// Inspector rows after applying the current search filter.
    private var filteredItems: [AgentContextItem] {
        store.items.filter { $0.matches(searchText: searchText) }
    }

    /// Selected row object, if the table selection still exists.
    private var selectedItem: AgentContextItem? {
        selection.flatMap { id in filteredItems.first { $0.id == id } }
    }

    /// Table-based inspector layout with native folder selection and Finder actions.
    var body: some View {
        Table(filteredItems, selection: $selection) {
            TableColumn("Context") { item in
                ContextFileCell(item: item)
            }
            .width(min: 220, ideal: 310)

            TableColumn("State") { item in
                EntryTypeCell(entryType: item.entryType)
            }
            .width(min: 105, ideal: 125, max: 150)

            TableColumn("Size") { item in
                Text(sizeText(for: item))
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 95, max: 120)

            TableColumn("Modified") { item in
                Text(modifiedText(for: item))
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 160, max: 200)

            TableColumn("Signals") { item in
                AgentContextSignalsCell(warnings: item.warnings)
            }
            .width(min: 230, ideal: 320)
        }
        .navigationTitle("Agent Context")
        .navigationSubtitle(Text(verbatim: store.selectedRepositoryURL?.path ?? String(localized: "No repository selected")))
        .searchable(text: $searchText, prompt: "Search context files")
        .contextMenu(forSelectionType: AgentContextItem.ID.self) { ids in
            if let item = item(for: ids.first), item.exists {
                Button("Open") { open(item) }
                Button("Reveal in Finder") { reveal(item) }
            }
        } primaryAction: { ids in
            if let item = item(for: ids.first), item.exists {
                open(item)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open", systemImage: "doc") {
                    if let selectedItem {
                        open(selectedItem)
                    }
                }
                .help("Open the selected context entry")
                .disabled(selectedItem?.exists != true)

                Button("Reveal in Finder", systemImage: "folder") {
                    if let selectedItem {
                        reveal(selectedItem)
                    }
                }
                .help("Reveal the selected context entry in Finder")
                .disabled(selectedItem?.exists != true)

                Button("Refresh", systemImage: "arrow.clockwise") {
                    store.reload()
                }
                .help("Refresh context files")
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
                    description: Text("Choose a repository folder to inspect agent context files.")
                )
            } else if filteredItems.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different file, warning, or path.")
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let openWarning {
                Text(openWarning)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 12)
            }
        }
        .task(id: openWarningID) {
            guard openWarning != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            openWarning = nil
        }
    }

    /// Finds the currently visible row for a selected table identifier.
    private func item(for id: AgentContextItem.ID?) -> AgentContextItem? {
        id.flatMap { selectedID in filteredItems.first { $0.id == selectedID } }
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

    /// Opens a present context entry through the configured file opener.
    private func open(_ item: AgentContextItem) {
        let preference = FeatureFlag.defaultEditorPreference.isEnabled
            ? DefaultTextEditorPreference.load()
            : .systemDefault
        Task { @MainActor in
            let result = await fileOpener.open(item.url, preference: preference)
            if result == .fellBackToSystemDefault {
                openWarning = String(
                    localized: "The configured default editor is unavailable. CodingBuddy opened the file with the system default instead."
                )
                openWarningID = UUID()
            }
        }
    }

    /// Reveals a present context entry in Finder.
    private func reveal(_ item: AgentContextItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Formats an optional byte count for dense table display.
    private func sizeText(for item: AgentContextItem) -> String {
        guard let byteCount = item.byteCount else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    /// Formats an optional modification date for dense table display.
    private func modifiedText(for item: AgentContextItem) -> String {
        item.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "-"
    }
}

/// Two-line context file summary for path and category.
private struct ContextFileCell: View {
    /// Context entry represented by this table cell.
    var item: AgentContextItem

    /// Monospaced path with secondary context kind.
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: item.relativePath)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.kind.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Compact entry-type indicator for the inspector table.
private struct EntryTypeCell: View {
    /// Entry type represented by this cell.
    var entryType: AgentContextEntryType

    /// Label with SF Symbol and localized type text.
    var body: some View {
        Label {
            Text(entryType.displayName)
        } icon: {
            Image(systemName: entryType.systemImageName)
                .foregroundStyle(entryType.tint)
        }
        .lineLimit(1)
    }
}

/// Compact signal list for deterministic scanner warnings.
private struct AgentContextSignalsCell: View {
    /// Warnings shown for one context entry.
    var warnings: [AgentContextWarningCode]

    /// Dense tag row with an overflow counter.
    var body: some View {
        if warnings.isEmpty {
            Text("No signals")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                ForEach(warnings.prefix(2), id: \.self) { warning in
                    SignalTag(warning: warning)
                }
                if warnings.count > 2 {
                    Text(verbatim: "+\(warnings.count - 2)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Small warning/info tag used in the signals column.
private struct SignalTag: View {
    /// Scanner signal represented by this tag.
    var warning: AgentContextWarningCode

    /// Labeled symbol with severity tint.
    var body: some View {
        Label {
            Text(warning.displayName)
                .lineLimit(1)
        } icon: {
            Image(systemName: warning.severity.systemImageName)
                .foregroundStyle(warning.severity.tint)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .help(warning.displayName)
    }
}

private extension AgentContextEntryType {
    /// SF Symbol for this entry type.
    var systemImageName: String {
        switch self {
        case .file:
            "doc.text"
        case .directory:
            "folder"
        case .symlink:
            "arrow.triangle.branch"
        case .missing:
            "questionmark.folder"
        case .unexpected:
            "exclamationmark.triangle"
        }
    }

    /// Semantic tint for the entry-type symbol.
    var tint: Color {
        switch self {
        case .file, .directory:
            .accentColor
        case .symlink:
            .blue
        case .missing:
            .orange
        case .unexpected:
            .red
        }
    }
}

private extension AgentDiagnosticSeverity {
    /// SF Symbol that visually distinguishes severity levels.
    var systemImageName: String {
        switch self {
        case .error:
            "xmark.octagon.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .info:
            "info.circle.fill"
        }
    }

    /// Semantic tint for the severity symbol.
    var tint: Color {
        switch self {
        case .error:
            .red
        case .warning:
            .orange
        case .info:
            .blue
        }
    }
}
