//
//  PRAttentionQueueView.swift
//  CodingBuddy
//

import AppKit
import SwiftUI

/// Cross-repository focus queue derived from the existing Agent PR Monitor snapshot.
struct PRAttentionQueueView: View {
    /// Source store; the queue intentionally owns no repository persistence or network client.
    var store: AgentPRMonitorStore
    /// Opens the GitHub authorization Settings pane.
    var openSettings: () -> Void
    /// Navigates to the full Agent PR Monitor for setup and broader inspection.
    var showPRMonitor: () -> Void

    /// Currently selected queue item.
    @State private var selection: PRAttentionItem.ID?

    /// Deterministic snapshot rebuilt from observable source state.
    private var snapshot: PRAttentionQueueSnapshot {
        PRAttentionQueueBuilder.snapshot(
            rows: store.rows,
            repositories: store.watchedRepositories,
            freshnessByRepository: freshnessByRepository,
            defaultFreshness: AgentPRMonitorView.guidanceFreshness(for: store.state),
            actionAvailability: actionAvailability
        )
    }

    /// Selected item if it remains in the latest queue snapshot.
    private var selectedItem: PRAttentionItem? {
        selection.flatMap { id in snapshot.items.first { $0.id == id } }
    }

    /// Inspector visibility follows selection and clears it when the user dismisses the inspector.
    private var inspectorBinding: Binding<Bool> {
        Binding {
            selectedItem != nil
        } set: { isPresented in
            if !isPresented { selection = nil }
        }
    }

    /// Repository-scoped freshness prevents one failed refresh from hiding other results.
    private var freshnessByRepository: [GitHubRepositoryRef: AgentPRGuidanceFreshness] {
        Dictionary(uniqueKeysWithValues: store.watchedRepositories.map { repository in
            let state = store.repositoryRefreshStates[repository] ?? store.state
            return (repository, AgentPRMonitorView.guidanceFreshness(for: state))
        })
    }

    /// Existing source routes currently safe to present from the queue.
    private var actionAvailability: AgentPRGuidanceActionAvailability {
        AgentPRGuidanceActionAvailability(
            canOpenPullRequest: true,
            canRefresh: !store.isRefreshing,
            canOpenSettings: true
        )
    }

    /// Native dense table with the platform inspector pattern used elsewhere in CodingBuddy.
    var body: some View {
        queueTable
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .inspector(isPresented: inspectorBinding) {
            PRAttentionInspector(
                item: selectedItem,
                isRecommended: selectedItem?.id == snapshot.recommendedItem?.id,
                performAction: performGuidanceAction
            )
            .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
        }
        .navigationTitle("Attention Queue")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open PR Monitor", systemImage: "arrow.triangle.pull") {
                    showPRMonitor()
                }
                .help("Open the full pull request monitor")

                Button("Refresh", systemImage: "arrow.clockwise") {
                    store.refresh()
                }
                .help("Refresh watched repositories")
                .disabled(store.isRefreshing || store.watchedRepositories.isEmpty)
            }
        }
        .onAppear {
            if store.state == .idle, !store.watchedRepositories.isEmpty {
                store.refresh()
            }
        }
        .onChange(of: snapshot.items.map(\.id), initial: true) {
            keepSelectionVisible()
        }
    }

    /// Table ordered by deterministic usefulness rather than provider order.
    private var queueTable: some View {
        VStack(spacing: 0) {
            if hasPartialSnapshotIssue {
                HStack(spacing: 10) {
                    Label(
                        "Some repository snapshots are not current. Available repository status remains visible.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 12)

                    Button("Open PR Monitor", action: showPRMonitor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()
            }

            Table(snapshot.items, selection: $selection) {
                TableColumn("Priority") { item in
                    AttentionPriorityLabel(priority: item.priority)
                }
                .width(min: 88, ideal: 100, max: 120)

                TableColumn("Item") { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.titleDisplayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(verbatim: item.repository.displayName)
                                .lineLimit(1)
                            if let number = item.pullRequest?.number {
                                Text(verbatim: "#\(number)")
                                    .monospaced()
                            } else {
                                Text("Repository status")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .width(min: 250, ideal: 360)
            }
            .overlay { queueOverlay }
        }
    }

    /// Reports incomplete repository coverage without replacing successful repository rows.
    private var hasPartialSnapshotIssue: Bool {
        guard !snapshot.items.isEmpty else { return false }
        return store.watchedRepositories.contains { repository in
            switch store.repositoryRefreshStates[repository] ?? store.state {
            case .needsToken, .rateLimited, .refreshFailed:
                true
            case .idle, .needsRepository, .loading, .loaded, .empty:
                false
            }
        }
    }

    /// Setup, loading, failure, and empty states retain the source store's truth.
    @ViewBuilder private var queueOverlay: some View {
        if snapshot.items.isEmpty {
            if case .needsToken = store.state {
                ContentUnavailableView {
                    Label("GitHub token required", systemImage: "key")
                } description: {
                    Text("Add a fine-grained read-only token before CodingBuddy can rank pull request work.")
                } actions: {
                    Button("Open Settings", action: openSettings)
                }
            } else if store.watchedRepositories.isEmpty {
                ContentUnavailableView {
                    Label("No watched repositories", systemImage: "book.closed")
                } description: {
                    Text("Choose repositories in Agent PR Monitor to build your attention queue.")
                } actions: {
                    Button("Open PR Monitor", action: showPRMonitor)
                }
            } else if store.isRefreshing {
                ProgressView(String(localized: "Loading attention queue..."))
            } else if case .rateLimited(let resetAt) = store.state {
                ContentUnavailableView(
                    "GitHub rate limit reached",
                    systemImage: "clock.badge.exclamationmark",
                    description: Text(rateLimitMessage(resetAt: resetAt))
                )
            } else if case .refreshFailed(let error) = store.state {
                ContentUnavailableView {
                    Label("Attention queue unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    if error.isGitHubAuthorizationRecoverable {
                        Button("Open Settings", action: openSettings)
                    } else {
                        Button("Refresh") { store.refresh() }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No pull requests need sorting", systemImage: "checkmark.circle")
                } description: {
                    Text("CodingBuddy did not find open pull requests in the current repository snapshots.")
                } actions: {
                    Button("Open PR Monitor", action: showPRMonitor)
                }
            }
        }
    }

    /// Explains why waiting is the useful action when GitHub has not returned a snapshot yet.
    private func rateLimitMessage(resetAt: Date?) -> String {
        if let resetAt {
            return String(
                format: String(localized: "GitHub says more requests are available after %@."),
                resetAt.formatted(date: .omitted, time: .shortened)
            )
        }
        return String(localized: "GitHub did not provide a reset time. Try again later.")
    }

    /// Keeps keyboard focus stable as repositories refresh or disappear.
    private func keepSelectionVisible() {
        if let selection, snapshot.items.contains(where: { $0.id == selection }) {
            return
        }
        selection = snapshot.recommendedItem?.id
    }

    /// Routes the selected guidance through the same typed source action boundary as the PR Monitor.
    private func performGuidanceAction(_ actionID: String) {
        guard let item = selectedItem else { return }
        if let row = item.pullRequest {
            AgentPRViewActions.perform(
                actionID: actionID,
                guidance: item.guidance,
                row: row,
                openURL: { _ = NSWorkspace.shared.open($0) },
                refresh: store.isRefreshing ? nil : { store.refresh() },
                openSettings: openSettings
            )
            return
        }

        guard let route = AgentPRGuidanceCatalog.route(for: actionID, in: item.guidance) else { return }
        switch route {
        case .refresh:
            guard !store.isRefreshing else { return }
            store.refresh()
        case .openSettings:
            openSettings()
        case .openPullRequest:
            return
        }
    }
}

/// Compact native priority label shared by every queue row.
private struct AttentionPriorityLabel: View {
    /// Priority whose label, symbol, and accessibility explanation are rendered.
    var priority: AttentionPriority

    var body: some View {
        Label(priority.displayName, systemImage: systemImage)
            .foregroundStyle(foregroundStyle)
            .lineLimit(1)
            .accessibilityLabel(Text(priority.displayName))
            .accessibilityHint(Text(priority.explanation))
    }

    private var systemImage: String {
        switch priority {
        case .actNow: "exclamationmark.circle"
        case .next: "arrow.right.circle"
        case .waiting: "clock"
        case .ready: "checkmark.circle"
        }
    }

    private var foregroundStyle: Color {
        switch priority {
        case .actNow: .orange
        case .next: .blue
        case .waiting: .secondary
        case .ready: .green
        }
    }
}

/// Plain-language inspector for the selected queue item.
private struct PRAttentionInspector: View {
    /// Currently selected queue item, or `nil` when no row is selected.
    var item: PRAttentionItem?
    /// Whether the selected item is the queue's current recommendation.
    var isRecommended: Bool
    /// Typed guidance action delegated to the queue owner.
    var performAction: (String) -> Void

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(for: item)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Why now")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Text(item.priority.explanation)
                            .fixedSize(horizontal: false, vertical: true)
                        LabeledContent("Signal", value: item.reasonDisplayName)
                        if let updatedAt = item.updatedAt {
                            LabeledContent("Updated") {
                                Text(updatedAt, format: .relative(presentation: .named))
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    GuidanceInspectorSection(
                        guidance: item.guidance,
                        onPerformAction: performAction
                    )
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView(
                "Select an item",
                systemImage: "scope",
                description: Text("Choose an item to understand its priority and recommended next action.")
            )
        }
    }

    /// Selected PR identity and calm priority summary.
    private func header(for item: PRAttentionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if isRecommended {
                Label("Recommended", systemImage: "scope")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: item.repository.displayName)
                .foregroundStyle(.secondary)
            Text(item.titleDisplayName)
                .font(.title3)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let number = item.pullRequest?.number {
                    Text(verbatim: "#\(number)")
                        .monospaced()
                }
                AttentionPriorityLabel(priority: item.priority)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(headerAccessibilityLabel(for: item)))
        .accessibilityAddTraits(.isHeader)
    }

    /// VoiceOver label identifies the source type and user-facing urgency band.
    private func headerAccessibilityLabel(for item: PRAttentionItem) -> String {
        guard let row = item.pullRequest else {
            if isRecommended {
                return String(
                    format: String(
                        localized: "Attention inspector recommended repository header accessibility label",
                        defaultValue: "Recommended. %1$@ repository status: %2$@. Priority: %3$@."
                    ),
                    item.repository.displayName,
                    item.reasonDisplayName,
                    item.priority.displayName
                )
            }
            return String(
                format: String(
                    localized: "Attention inspector repository header accessibility label",
                    defaultValue: "%1$@ repository status: %2$@. Priority: %3$@."
                ),
                item.repository.displayName,
                item.reasonDisplayName,
                item.priority.displayName
            )
        }
        if isRecommended {
            return String(
                format: String(
                    localized: "Attention inspector recommended header accessibility label",
                    defaultValue: "Recommended. %1$@ pull request %2$lld: %3$@. Priority: %4$@."
                ),
                row.repository.displayName,
                Int64(row.number),
                row.title,
                item.priority.displayName
            )
        }
        return String(
            format: String(
                localized: "Attention inspector header accessibility label",
                defaultValue: "%1$@ pull request %2$lld: %3$@. Priority: %4$@."
            ),
            row.repository.displayName,
            Int64(row.number),
            row.title,
            item.priority.displayName
        )
    }
}
