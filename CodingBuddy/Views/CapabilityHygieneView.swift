import AppKit
import SwiftUI

/// Workspace modes for findings-first review and complete occurrence inspection.
nonisolated enum CapabilityHygieneMode: String, CaseIterable, Sendable {
    /// Relations that may deserve manual review.
    case findings
    /// Every occurrence retained by the latest scan.
    case inventory

    /// Localized segmented-control label.
    var displayName: String {
        switch self {
        case .findings: String(localized: "Findings")
        case .inventory: String(localized: "Inventory")
        }
    }
}

/// Sortable presentation values for one finding without changing analyzer identity.
private nonisolated struct CapabilityFindingPresentationRow: Identifiable {
    /// Underlying typed analyzer result.
    let finding: CapabilityHygieneFinding
    /// Compact identities shown in the table.
    let capabilityLabel: String
    /// Stable consumer summary.
    let consumerLabel: String
    /// Stable effective-scope summary.
    let scopeLabel: String

    /// Finding identity retained by table selection.
    var id: CapabilityHygieneFinding.ID { finding.id }
    /// Locale-independent sort key for the relation kind.
    var kindSortKey: String { finding.kind.rawValue }
    /// Number of involved occurrences.
    var occurrenceCount: Int { finding.itemIDs.count }
}

/// Sortable presentation values for one retained inventory occurrence.
private nonisolated struct CapabilityInventoryPresentationRow: Identifiable {
    /// Underlying typed occurrence.
    let item: CapabilityInventoryItem

    /// Occurrence identity retained by table selection.
    var id: CapabilityInventoryItem.ID { item.id }
    /// Compact identity used by dense table surfaces.
    var capabilityLabel: String { item.displayIdentity }
    /// Locale-independent category sort key.
    var kindSortKey: String { item.kind.rawValue }
    /// Locale-independent consumer sort key.
    var consumerSortKey: String { item.consumer.rawValue }
    /// Effective scope sort key.
    var scopeSortKey: String { item.effectiveScope }
    /// Locale-independent evidence sort key.
    var evidenceSortKey: String { item.sourceStatus.sortKey }
}

/// Localized, value-safe VoiceOver summaries for structured capability evidence.
nonisolated enum CapabilityHygieneAccessibility {
    /// Localized field names kept injectable for deterministic accessibility tests.
    struct Labels: Equatable, Sendable {
        /// Fallback heading for an untyped occurrence.
        let occurrence: String
        /// Runtime identity field name.
        let identity: String
        /// Provider consumer field name.
        let consumer: String
        /// Effective scope field name.
        let scope: String
        /// Value-free source-path field name.
        let sourcePath: String

        /// Labels resolved from the app's active localization.
        static var localized: Labels {
            Labels(
                occurrence: String(localized: "Occurrence"),
                identity: String(localized: "Identity"),
                consumer: String(localized: "Consumer"),
                scope: String(localized: "Scope"),
                sourcePath: String(localized: "Source path")
            )
        }
    }

    /// Describes every visible field of one relation occurrence as one stable AX element.
    static func occurrenceSummary(
        for item: CapabilityInventoryItem,
        role: String? = nil,
        labels: Labels = .localized
    ) -> String {
        let heading = role ?? labels.occurrence
        return "\(heading). \(labels.identity): \(item.runtimeIdentity). \(labels.consumer): \(item.consumer.displayName). \(labels.scope): \(item.effectiveScope). \(labels.sourcePath): \(item.sourcePath)."
    }
}

/// Native read-only workbench for local agent capabilities and hygiene evidence.
struct CapabilityHygieneView: View {
    /// Observable snapshot and filtering coordinator.
    @Bindable var store: CapabilityHygieneStore

    /// Active findings-first or full-inventory workspace.
    @State private var mode = CapabilityHygieneMode.findings
    /// Selected finding in the findings workspace.
    @State private var findingSelection: CapabilityHygieneFinding.ID?
    /// Selected occurrence in the inventory workspace.
    @State private var itemSelection: CapabilityInventoryItem.ID?
    /// Inspector visibility remains independent from selection.
    @State private var isInspectorPresented = false
    /// User-selected sort order in the findings workspace.
    @State private var findingSortOrder = [
        KeyPathComparator(\CapabilityFindingPresentationRow.kindSortKey),
        KeyPathComparator(\CapabilityFindingPresentationRow.capabilityLabel),
    ]
    /// User-selected sort order in the inventory workspace.
    @State private var inventorySortOrder = [
        KeyPathComparator(\CapabilityInventoryPresentationRow.capabilityLabel),
    ]

    /// Selected finding still present in the filtered snapshot.
    private var selectedFinding: CapabilityHygieneFinding? {
        findingSelection.flatMap { id in store.filteredFindings.first { $0.id == id } }
    }

    /// Selected inventory occurrence still present in the filtered snapshot.
    private var selectedItem: CapabilityInventoryItem? {
        itemSelection.flatMap { id in store.filteredItems.first { $0.id == id } }
    }

    /// Coverage is incomplete whenever scanning or analysis excluded evidence.
    private var hasIncompleteCoverage: Bool {
        !store.incompleteSources.isEmpty
            || !(store.snapshot?.notices.isEmpty ?? true)
            || store.isAnalysisTruncated
    }

    /// Whether the active workspace currently has an inspectable selection.
    private var hasActiveSelection: Bool {
        mode == .findings ? selectedFinding != nil : selectedItem != nil
    }

    /// Finding rows sorted by the active table order.
    private var sortedFindingRows: [CapabilityFindingPresentationRow] {
        store.filteredFindings.map { finding in
            let items = involvedItems(for: finding)
            return CapabilityFindingPresentationRow(
                finding: finding,
                capabilityLabel: items.map(\.displayIdentity).joined(separator: ", "),
                consumerLabel: uniqueConsumers(for: finding).joined(separator: ", "),
                scopeLabel: uniqueScopes(for: finding).joined(separator: ", ")
            )
        }
        .sorted(using: findingSortOrder)
    }

    /// Inventory rows sorted by the active table order.
    private var sortedInventoryRows: [CapabilityInventoryPresentationRow] {
        store.filteredItems
            .map(CapabilityInventoryPresentationRow.init(item:))
            .sorted(using: inventorySortOrder)
    }

    /// Main table, bounded coverage strip, toolbar, and independent inspector.
    var body: some View {
        VStack(spacing: 0) {
            if hasIncompleteCoverage {
                CapabilityCoverageStrip(
                    incompleteSources: store.incompleteSources,
                    notices: store.snapshot?.notices ?? [],
                    isAnalysisTruncated: store.isAnalysisTruncated
                )
                Divider()
            }

            switch mode {
            case .findings:
                findingsTable
            case .inventory:
                inventoryTable
            }
        }
        .navigationTitle("Capabilities")
        .searchable(text: $store.searchText, prompt: "Search capabilities")
        .toolbar { toolbarContent }
        .inspector(isPresented: $isInspectorPresented) {
            CapabilityHygieneInspector(
                finding: mode == .findings ? selectedFinding : nil,
                item: mode == .inventory ? selectedItem : nil,
                involvedItems: mode == .findings ? selectedFinding.map(involvedItems(for:)) ?? [] : []
            )
            .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        }
        .onChange(of: findingSelection) {
            guard mode == .findings else { return }
            isInspectorPresented = findingSelection != nil
        }
        .onChange(of: itemSelection) {
            guard mode == .inventory else { return }
            isInspectorPresented = itemSelection != nil
        }
        .onChange(of: mode) {
            if !hasActiveSelection { isInspectorPresented = false }
        }
        .onChange(of: store.searchText) {
            reconcileVisibleSelection()
        }
        .onChange(of: store.snapshot) {
            reconcileVisibleSelection()
        }
        .onAppear {
            if store.phase == .idle { store.reload() }
        }
    }

    /// Clears selections that no longer belong to the visible filtered result set.
    private func reconcileVisibleSelection() {
        if findingSelection != nil, selectedFinding == nil { findingSelection = nil }
        if itemSelection != nil, selectedItem == nil { itemSelection = nil }
        if !hasActiveSelection { isInspectorPresented = false }
    }

    /// Dense relation table with explicit evidence certainty and occurrence count.
    private var findingsTable: some View {
        Table(sortedFindingRows, selection: $findingSelection, sortOrder: $findingSortOrder) {
            TableColumn("Finding", value: \.kindSortKey) { row in
                Label(row.finding.kind.displayName, systemImage: row.finding.kind.systemImage)
                    .foregroundStyle(row.finding.kind == .possibleOverlap ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 145, ideal: 175, max: 210)

            TableColumn("Capability", value: \.capabilityLabel) { row in
                Text(verbatim: row.capabilityLabel)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .width(min: 180, ideal: 260, max: 360)

            TableColumn("Consumer", value: \.consumerLabel) { row in
                Text(verbatim: row.consumerLabel)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 130, max: 170)

            TableColumn("Scope", value: \.scopeLabel) { row in
                Text(verbatim: row.scopeLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 130, ideal: 190, max: 300)

            TableColumn("Occurrences", value: \.occurrenceCount) { row in
                Text(verbatim: "\(row.occurrenceCount)")
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 95, max: 110)
        }
        .overlay { findingsEmptyState }
    }

    /// Flat sortable-ready inventory table that preserves every source occurrence.
    private var inventoryTable: some View {
        Table(sortedInventoryRows, selection: $itemSelection, sortOrder: $inventorySortOrder) {
            TableColumn("Capability", value: \.capabilityLabel) { row in
                Text(verbatim: row.capabilityLabel)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .width(min: 170, ideal: 240, max: 360)

            TableColumn("Kind", value: \.kindSortKey) { row in
                Label(row.item.kind.displayName, systemImage: row.item.kind.systemImage)
                    .lineLimit(1)
            }
            .width(min: 95, ideal: 120, max: 145)

            TableColumn("Consumer", value: \.consumerSortKey) { row in
                Text(verbatim: row.item.consumer.displayName)
                    .lineLimit(1)
            }
            .width(min: 95, ideal: 125, max: 155)

            TableColumn("Scope", value: \.scopeSortKey) { row in
                Text(verbatim: row.item.effectiveScope)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 130, ideal: 200, max: 320)

            TableColumn("Evidence", value: \.evidenceSortKey) { row in
                CapabilitySourceStatusLabel(status: row.item.sourceStatus)
            }
            .width(min: 115, ideal: 145, max: 180)
        }
        .overlay { inventoryEmptyState }
    }

    /// Mode switch, safe path copy, inspector toggle, and scan refresh commands.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $mode) {
                ForEach(CapabilityHygieneMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button("Copy Source Paths", systemImage: "doc.on.clipboard") {
                copySelectedSourcePaths()
            }
            .help("Copy the selected source paths")
            .disabled(selectedSourcePaths.isEmpty)

            Button("Inspector", systemImage: "sidebar.trailing") {
                isInspectorPresented.toggle()
            }
            .help("Show or hide details")
            .disabled(!hasActiveSelection)

            if store.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .help("Scanning capabilities")
            }

            Button("Refresh", systemImage: "arrow.clockwise") {
                store.reload()
            }
            .help("Rescan local capability sources")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isScanning)
        }
    }

    /// First-load, no-finding, and search-filter empty states.
    @ViewBuilder
    private var findingsEmptyState: some View {
        if store.snapshot == nil, store.isScanning {
            ProgressView("Scanning capabilities…")
        } else if store.filteredFindings.isEmpty {
            if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            } else {
                if hasIncompleteCoverage {
                    ContentUnavailableView(
                        "No findings in verified sources",
                        systemImage: "exclamationmark.shield",
                        description: Text("No finding exists in the verified evidence. Open the coverage details before treating this as an all-clear result.")
                    )
                } else {
                    ContentUnavailableView(
                        "No hygiene findings",
                        systemImage: "checkmark.circle",
                        description: Text("No duplicate, proven shadowing, or possible-overlap finding exists in the completed local evidence.")
                    )
                }
            }
        }
    }

    /// First-load, no-source, and search-filter inventory empty states.
    @ViewBuilder
    private var inventoryEmptyState: some View {
        if store.snapshot == nil, store.isScanning {
            ProgressView("Scanning capabilities…")
        } else if store.filteredItems.isEmpty {
            if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            } else {
                if hasIncompleteCoverage {
                    ContentUnavailableView(
                        "No capabilities in verified sources",
                        systemImage: "exclamationmark.shield",
                        description: Text("No capability was found in verified evidence. Coverage details list sources that were not fully scanned.")
                    )
                } else {
                    ContentUnavailableView(
                        "No capabilities found",
                        systemImage: "wrench.and.screwdriver",
                        description: Text("CodingBuddy did not find a supported configured MCP server, standalone skill, or installed plugin.")
                    )
                }
            }
        }
    }

    /// Resolves all occurrences attached to one finding without fabricating missing rows.
    private func involvedItems(for finding: CapabilityHygieneFinding) -> [CapabilityInventoryItem] {
        finding.itemIDs.compactMap(store.item(withID:))
    }

    /// Stable consumer labels represented by one finding.
    private func uniqueConsumers(for finding: CapabilityHygieneFinding) -> [String] {
        Array(Set(involvedItems(for: finding).map { $0.consumer.displayName })).sorted()
    }

    /// Stable effective scopes represented by one finding.
    private func uniqueScopes(for finding: CapabilityHygieneFinding) -> [String] {
        Array(Set(involvedItems(for: finding).map(\.effectiveScope))).sorted()
    }

    /// Source paths represented by the active workspace selection.
    private var selectedSourcePaths: [String] {
        switch mode {
        case .findings:
            selectedFinding.map(involvedItems(for:))?.map(\.sourcePath) ?? []
        case .inventory:
            selectedItem.map { [$0.sourcePath] } ?? []
        }
    }

    /// Copies value-free source paths without opening or mutating the source entries.
    private func copySelectedSourcePaths() {
        let paths = Array(Set(selectedSourcePaths)).sorted()
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }
}

/// Persistent coverage warning shown without hiding verified rows.
private struct CapabilityCoverageStrip: View {
    /// Source records that were partial, refused, or unsupported.
    let incompleteSources: [CapabilitySourceRecord]
    /// Value-free notices emitted by the bounded scanner.
    let notices: [CapabilityScanNotice]
    /// Whether advisory comparison stopped at a safety budget.
    let isAnalysisTruncated: Bool
    /// Native details popover visibility.
    @State private var isShowingDetails = false

    /// Multiline coverage summary that remains readable beside the inspector.
    var body: some View {
        Button {
            isShowingDetails.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Coverage is incomplete")
                        .fontWeight(.medium)
                    coverageCounts
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .help("Show coverage details")
        .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
            CapabilityCoverageDetails(
                incompleteSources: incompleteSources,
                notices: notices,
                isAnalysisTruncated: isAnalysisTruncated
            )
            .frame(width: 480, height: 420)
        }
    }

    /// Grammar-safe labels keep singular counts from producing broken copy.
    @ViewBuilder
    private var coverageCounts: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !incompleteSources.isEmpty {
                HStack(spacing: 5) {
                    Text("Incomplete sources")
                    Text(verbatim: "\(incompleteSources.count)")
                        .monospacedDigit()
                }
            }
            if !notices.isEmpty {
                HStack(spacing: 5) {
                    Text("Scan notices")
                    Text(verbatim: "\(notices.count)")
                        .monospacedDigit()
                }
            }
            if isAnalysisTruncated {
                Text("Advisory overlap analysis reached its safety limit")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Native popover with value-free source paths and typed localized reasons.
private struct CapabilityCoverageDetails: View {
    /// Incomplete source records retained by the scanner.
    let incompleteSources: [CapabilitySourceRecord]
    /// Bounded scan notices retained by the scanner.
    let notices: [CapabilityScanNotice]
    /// Whether advisory comparison was truncated.
    let isAnalysisTruncated: Bool

    /// Incomplete sources grouped by typed status and reason for bounded navigation.
    private var incompleteGroups: [CapabilityCoverageGroup] {
        let grouped = Dictionary(grouping: incompleteSources) { source in
            source.status.sortKey
        }
        return grouped.keys.sorted().compactMap { key in
            guard let records = grouped[key], let first = records.first else { return nil }
            return CapabilityCoverageGroup(
                id: "source|\(key)",
                status: first.status.displayName,
                reason: first.status.reason?.displayName,
                entries: records.map { .init(id: $0.id, path: $0.sourcePath) }.sorted { $0.path < $1.path }
            )
        }
    }

    /// Scan notices grouped by typed reason so large failure sets remain scannable.
    private var noticeGroups: [CapabilityCoverageGroup] {
        let grouped = Dictionary(grouping: notices, by: \.reason)
        return grouped.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { reason in
            guard let records = grouped[reason] else { return nil }
            return CapabilityCoverageGroup(
                id: "notice|\(reason.rawValue)",
                status: String(localized: "Notice"),
                reason: reason.displayName,
                entries: records.map { .init(id: $0.id, path: $0.sourcePath) }.sorted { $0.path < $1.path }
            )
        }
    }

    /// Scrollable details suitable for long local path lists.
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Coverage details")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)

                if isAnalysisTruncated {
                    Label {
                        Text("Possible-overlap analysis stopped at its safety limit. Duplicate and proven-shadowing evidence remains available.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.orange)
                }

                if !incompleteSources.isEmpty {
                    coverageSectionTitle("Incomplete sources")
                    ForEach(incompleteGroups, content: coverageGroup)
                }

                if !notices.isEmpty {
                    coverageSectionTitle("Scan notices")
                    ForEach(noticeGroups, content: coverageGroup)
                }
            }
            .padding(18)
        }
    }

    /// Collapsible typed group with a visible count and lazily rendered path rows.
    private func coverageGroup(_ group: CapabilityCoverageGroup) -> some View {
        DisclosureGroup {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(group.entries) { entry in
                    coverageRow(path: entry.path, status: group.status, reason: group.reason)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: group.status)
                    .fontWeight(.medium)
                if let reason = group.reason {
                    Text(verbatim: reason)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(verbatim: "\(group.entries.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Consistent popover section heading.
    private func coverageSectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.headline)
    }

    /// Value-free path plus localized typed status and reason.
    private func coverageRow(path: String, status: String, reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: path)
                .font(.caption)
                .monospaced()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: status)
                    .fontWeight(.medium)
                if let reason {
                    Text(verbatim: reason)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One value-free path inside a grouped coverage disclosure.
private nonisolated struct CapabilityCoverageEntry: Identifiable {
    /// Stable source or notice identity.
    let id: String
    /// Value-free source path.
    let path: String
}

/// Collapsible coverage group sharing one typed status and reason.
private nonisolated struct CapabilityCoverageGroup: Identifiable {
    /// Stable group identity.
    let id: String
    /// Localized typed status.
    let status: String
    /// Localized typed reason when present.
    let reason: String?
    /// Deterministically sorted paths.
    let entries: [CapabilityCoverageEntry]
}

/// Compact source-completeness label that never equates absence with health.
private struct CapabilitySourceStatusLabel: View {
    /// Typed completeness from the scanner.
    let status: CapabilitySourceStatus

    /// Text plus SF Symbol so color is not the only status cue.
    var body: some View {
        Label(status.displayName, systemImage: status.systemImage)
            .foregroundStyle(status.isIncomplete ? .orange : .secondary)
            .lineLimit(1)
    }
}

/// Inspector for either a relation or one complete inventory occurrence.
private struct CapabilityHygieneInspector: View {
    /// Selected finding when the findings workspace owns selection.
    let finding: CapabilityHygieneFinding?
    /// Selected occurrence when the inventory workspace owns selection.
    let item: CapabilityInventoryItem?
    /// Occurrences attached to the selected finding.
    let involvedItems: [CapabilityInventoryItem]

    /// Selection-independent details surface.
    var body: some View {
        Group {
            if let finding {
                findingInspector(finding)
            } else if let item {
                itemInspector(item)
            } else {
                ContentUnavailableView(
                    "No selection",
                    systemImage: "sidebar.trailing",
                    description: Text("Select a finding or capability to inspect its local evidence.")
                )
            }
        }
        .navigationTitle("Details")
    }

    /// Explainable finding evidence and manual-review boundary.
    private func findingInspector(_ finding: CapabilityHygieneFinding) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(finding.kind.displayName, systemImage: finding.kind.systemImage)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)

                Text(finding.kind.explanation)
                    .fixedSize(horizontal: false, vertical: true)

                relationEvidence(for: finding)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recommendation")
                        .font(.headline)
                    Text(finding.kind.recommendation)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if finding.kind != .shadowing {
                    Divider()
                    Text("Occurrences")
                        .font(.headline)
                    ForEach(involvedItems) { item in
                        occurrenceEvidence(item)
                    }
                }

                Divider()

                Text("Related analysis")
                    .font(.headline)
                Text("Permission names and secret references are evidence for the planned MCP Risk Auditor and Token/Scope Map. This view does not assign a risk score.")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    /// Relation-specific structured evidence; analyzer prose is deliberately not rendered.
    @ViewBuilder
    private func relationEvidence(for finding: CapabilityHygieneFinding) -> some View {
        switch finding.kind {
        case .exactDuplicate:
            LabeledContent("Canonical behavior", value: String(localized: "Matches"))
        case .possibleOverlap:
            if let similarity = finding.similarity {
                LabeledContent("Similarity") {
                    Text(similarity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
        case .shadowing:
            if let resolution = finding.shadowResolution {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Provider precedence")
                        .font(.headline)
                    LabeledContent("Provider", value: resolution.evidence.provider.displayName)
                    LabeledContent("Provider rule") {
                        Text(verbatim: resolution.evidence.ruleIdentifier)
                            .monospaced()
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent("Evaluation scope") {
                        Text(verbatim: resolution.evidence.evaluationScope)
                            .monospaced()
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let winner = involvedItems.first(where: { $0.id == resolution.winnerItemID }) {
                        occurrenceEvidence(winner, role: String(localized: "Winner"))
                    }
                    if let loser = involvedItems.first(where: { $0.id == resolution.loserItemID }) {
                        occurrenceEvidence(loser, role: String(localized: "Shadowed occurrence"))
                    }
                }
            } else {
                Label("Provider evidence is unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Full identity, consumer, scope, and value-free source path for one relation member.
    private func occurrenceEvidence(
        _ item: CapabilityInventoryItem,
        role: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let role {
                Text(verbatim: role)
                    .font(.headline)
            }
            Text(verbatim: item.runtimeIdentity)
                .fontWeight(.medium)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Consumer", value: item.consumer.displayName)
            LabeledContent("Scope") {
                Text(verbatim: item.effectiveScope)
                    .monospaced()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: item.sourcePath)
                .font(.caption)
                .monospaced()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CapabilityHygieneAccessibility.occurrenceSummary(for: item, role: role))
    }

    /// Full safe metadata for one retained occurrence.
    private func itemInspector(_ item: CapabilityInventoryItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(item.kind.displayName, systemImage: item.kind.systemImage)
                    .foregroundStyle(.secondary)
                Text(verbatim: item.runtimeIdentity)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                LabeledContent("Consumer", value: item.consumer.displayName)
                LabeledContent("Scope") {
                    Text(verbatim: item.effectiveScope)
                        .monospaced()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Evidence") {
                    CapabilitySourceStatusLabel(status: item.sourceStatus)
                }
                if let version = item.version {
                    LabeledContent("Version", value: version)
                }
                LabeledContent("Registration", value: item.registrationState.displayName)
                LabeledContent("Enabled", value: item.activationState.displayName)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Source")
                        .font(.headline)
                    Text(verbatim: item.sourcePath)
                        .font(.caption)
                        .monospaced()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let summary = item.summary {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Safe summary")
                            .font(.headline)
                        Text(verbatim: summary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                CapabilityNameList(title: String(localized: "Permissions"), values: item.permissionNames)
                CapabilityNameList(title: String(localized: "Header names"), values: item.headerNames)
                CapabilityNameList(title: String(localized: "Secret references"), values: item.secretReferenceNames)
                CapabilityNameList(title: String(localized: "Repository usage"), values: item.repositoryUsage)

                Divider()
                Text("Static local evidence only. Runtime availability, trust, approval, effective OAuth grants, and actual use may be unknown.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}

/// Simple accessible list for safe permission and secret-reference names.
private struct CapabilityNameList: View {
    /// Localized section title.
    let title: String
    /// Safe names retained by the scanner.
    let values: [String]

    /// Section omitted when no declared names exist.
    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                ForEach(values, id: \.self) { value in
                    Text(verbatim: value)
                        .font(.caption)
                        .monospaced()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private extension CapabilityKind {
    /// Localized kind label.
    var displayName: String {
        switch self {
        case .mcpServer: String(localized: "MCP server")
        case .skill: String(localized: "Skill")
        case .plugin: String(localized: "Plugin")
        }
    }

    /// SF Symbol matching the capability category.
    var systemImage: String {
        switch self {
        case .mcpServer: "server.rack"
        case .skill: "wrench.and.screwdriver"
        case .plugin: "puzzlepiece.extension"
        }
    }
}

private nonisolated extension CapabilityConsumer {
    /// Stable product label shown verbatim.
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .sharedAgents: String(localized: "Shared Agents")
        }
    }
}

private extension CapabilityRegistrationState {
    /// Localized authoritative registration state.
    var displayName: String {
        switch self {
        case .configured: String(localized: "Configured")
        case .installed: String(localized: "Installed")
        }
    }
}

private extension CapabilityActivationState {
    /// Localized tri-state provider activation evidence.
    var displayName: String {
        switch self {
        case .enabled: String(localized: "Yes")
        case .disabled: String(localized: "No")
        case .unknown: String(localized: "Unknown")
        }
    }
}

private extension CapabilityHygieneFindingKind {
    /// Localized finding label with evidence certainty preserved.
    var displayName: String {
        switch self {
        case .exactDuplicate: String(localized: "Exact duplicate")
        case .shadowing: String(localized: "Shadowed")
        case .possibleOverlap: String(localized: "Possible overlap")
        }
    }

    /// SF Symbol matching the relation type.
    var systemImage: String {
        switch self {
        case .exactDuplicate: "doc.on.doc"
        case .shadowing: "eye.slash"
        case .possibleOverlap: "questionmark.circle"
        }
    }

    /// Localized plain-language explanation.
    var explanation: String {
        switch self {
        case .exactDuplicate:
            String(localized: "These occurrences have the same kind, exact runtime identity, and complete canonical behavior.")
        case .shadowing:
            String(localized: "A documented provider precedence rule selects one occurrence and hides another in this evaluated scope.")
        case .possibleOverlap:
            String(localized: "Distinct names share conservative search signals. Their responsibilities may overlap, but CodingBuddy cannot prove a conflict.")
        }
    }

    /// Localized manual-review recommendation with no automatic mutation.
    var recommendation: String {
        switch self {
        case .exactDuplicate:
            String(localized: "Compare the source scopes and keep the occurrences that are intentionally required.")
        case .shadowing:
            String(localized: "Review the winning and shadowed definitions before changing either source manually.")
        case .possibleOverlap:
            String(localized: "Compare the documented purpose, permissions, and scope. Keeping both may be correct.")
        }
    }
}

private extension CapabilitySourceStatus {
    /// Localized completeness label.
    var displayName: String {
        switch self {
        case .missing: String(localized: "Not present")
        case .complete: String(localized: "Complete")
        case .partial: String(localized: "Partial")
        case .refused: String(localized: "Refused")
        case .unsupported: String(localized: "Unsupported")
        }
    }

    /// SF Symbol matching the completeness state.
    var systemImage: String {
        switch self {
        case .missing: "minus.circle"
        case .complete: "checkmark.circle"
        case .partial: "exclamationmark.circle"
        case .refused: "exclamationmark.shield"
        case .unsupported: "questionmark.circle"
        }
    }

    /// Whether the source needs coverage review rather than a healthy presentation.
    var isIncomplete: Bool {
        switch self {
        case .missing, .complete: false
        case .partial, .refused, .unsupported: true
        }
    }

    /// Typed reason carried by partial, refused, and unsupported states.
    var reason: CapabilitySourceReason? {
        switch self {
        case .missing, .complete: nil
        case let .partial(reason), let .refused(reason), let .unsupported(reason): reason
        }
    }

    /// Locale-independent sort value for the native table.
    nonisolated var sortKey: String {
        switch self {
        case .missing: "0-missing"
        case .complete: "1-complete"
        case let .partial(reason): "2-partial-\(reason.rawValue)"
        case let .refused(reason): "3-refused-\(reason.rawValue)"
        case let .unsupported(reason): "4-unsupported-\(reason.rawValue)"
        }
    }
}

private extension CapabilitySourceReason {
    /// Localized safe explanation for a typed scan refusal or limitation.
    var displayName: String {
        switch self {
        case .malformedUTF8: String(localized: "The source is not valid UTF-8")
        case .malformedJSON: String(localized: "The source does not contain unambiguous valid JSON")
        case .malformedTOML: String(localized: "The source does not contain unambiguous valid TOML")
        case .symbolicLink: String(localized: "A symbolic link was refused")
        case .pathEscape: String(localized: "The configured path escapes its provider-owned root")
        case .specialFile: String(localized: "The path is not a supported regular file or directory")
        case .fileByteLimit: String(localized: "The file exceeds the per-file safety limit")
        case .aggregateByteLimit: String(localized: "The scan reached its aggregate byte limit")
        case .entryLimit: String(localized: "The scan reached its entry limit")
        case .depthLimit: String(localized: "The scan reached its directory-depth limit")
        case .rootLimit: String(localized: "The scan reached its project or provider-root limit")
        case .behaviorDefinitionUnavailable: String(localized: "Behavior-bearing fields are unavailable for exact matching")
        case .unsupportedFormat: String(localized: "The provider format is not supported by this scanner")
        case .unavailable: String(localized: "The source was unavailable or changed during inspection")
        }
    }
}
