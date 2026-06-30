//
//  AgentPRMonitorView.swift
//  CodingBuddy
//

import AppKit
import SwiftUI

/// Read-only table for monitoring agent-related GitHub pull requests.
struct AgentPRMonitorView: View {
    /// Observable monitor state.
    var store: AgentPRMonitorStore
    /// Opens the app Settings sheet for GitHub authorization changes.
    var openSettings: () -> Void = {}

    /// Currently selected pull request row.
    @State private var selection: AgentPullRequest.ID?
    /// Search text applied across title, branch, author, issue, and status text.
    @State private var searchText = ""
    /// Whether the repository setup sheet is visible.
    @State private var showsRepositorySheet = false

    /// Rows after applying the current search filter.
    private var filteredRows: [AgentPullRequest] {
        store.rows.filter { $0.matches(searchText: searchText) }
    }

    /// Currently selected row object.
    private var selectedRow: AgentPullRequest? {
        selection.flatMap { id in filteredRows.first { $0.id == id } }
    }

    /// Native table view with setup, filtering, refresh, and browser follow-up actions.
    var body: some View {
        Table(filteredRows, selection: $selection) {
            TableColumn("Pull Request") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(verbatim: "#\(row.number) · \(row.headRefName) → \(row.baseRefName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 260, ideal: 360)

            TableColumn("Source") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.authorLogin ?? String(localized: "Unknown"))
                        .lineLimit(1)
                    Text(row.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 115, ideal: 145)

            TableColumn("Linked Issue") { row in
                if let issue = row.linkedIssues.first {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "#\(issue.number)")
                            .fontWeight(.medium)
                        Text(issue.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("No linked issue")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 140, ideal: 210)

            TableColumn("CI") { row in
                CheckStateCell(summary: row.checks)
            }
            .width(min: 110, ideal: 130)

            TableColumn("Review") { row in
                ReviewStateCell(summary: row.review)
            }
            .width(min: 135, ideal: 155)

            TableColumn("Findings") { row in
                FindingsStateCell(state: row.review.findingsState)
            }
            .width(min: 135, ideal: 155)

            TableColumn("Readiness") { row in
                ReadinessStateCell(state: row.readiness.state)
            }
            .width(min: 130, ideal: 150)

            TableColumn("Updated") { row in
                Text(row.updatedAt, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
            }
            .width(min: 95, ideal: 115)
        }
        .navigationTitle("Agent PR Monitor")
        .navigationSubtitle(Text(verbatim: store.selectedRepository?.displayName ?? String(localized: "No repository selected")))
        .searchable(text: $searchText, prompt: "Search pull requests")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open PR", systemImage: "arrow.up.right.square") {
                    openSelectedPullRequest()
                }
                .help("Open the selected pull request in your browser")
                .disabled(selectedRow == nil)

                Button("Refresh", systemImage: "arrow.clockwise") {
                    store.refresh()
                }
                .help("Refresh pull requests")
                .disabled(store.selectedRepository == nil || store.isRefreshing)

                Button("Repository...", systemImage: "book.closed") {
                    showsRepositorySheet = true
                }
                .help("Choose the GitHub repository to monitor")
            }
        }
        .overlay {
            overlayView
        }
        .sheet(isPresented: $showsRepositorySheet) {
            RepositorySetupSheet(store: store)
        }
        .onAppear {
            if store.selectedRepository != nil, store.rows.isEmpty, store.state == .idle {
                store.refresh()
            }
        }
    }

    /// Setup, empty, and error overlays for non-table states.
    @ViewBuilder private var overlayView: some View {
        if case .needsToken = store.state {
            ContentUnavailableView {
                Label("GitHub token required", systemImage: "key")
            } description: {
                Text("Add a fine-grained read-only token to load pull request status.")
            } actions: {
                Button("Open Settings") { openSettings() }
            }
        } else if case .refreshFailed(let error) = store.state, store.rows.isEmpty {
            ContentUnavailableView {
                Label("Refresh failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                if error.isGitHubAuthorizationRecoverable {
                    Button("Open Settings") { openSettings() }
                }
            }
        } else if store.selectedRepository == nil {
            ContentUnavailableView {
                Label("No repository selected", systemImage: "book.closed")
            } description: {
                Text("Choose a GitHub repository in owner/name format to monitor open pull requests.")
            } actions: {
                Button("Choose Repository...") { showsRepositorySheet = true }
            }
        } else if case .rateLimited(let resetAt) = store.state {
            ContentUnavailableView(
                "GitHub rate limit reached",
                systemImage: "clock.badge.exclamationmark",
                description: Text(rateLimitMessage(resetAt: resetAt))
            )
        } else if store.isRefreshing && store.rows.isEmpty {
            ProgressView(String(localized: "Loading pull requests..."))
        } else if filteredRows.isEmpty {
            if searchText.isEmpty {
                ContentUnavailableView(
                    "No pull requests",
                    systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                    description: Text("CodingBuddy did not find open pull requests for the selected repository.")
                )
            } else {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different title, branch, issue, status, or author.")
                )
            }
        }
    }

    /// Opens the selected PR in the user's browser.
    private func openSelectedPullRequest() {
        guard let selectedRow else { return }
        NSWorkspace.shared.open(selectedRow.url)
    }

    /// Localized rate-limit help text.
    private func rateLimitMessage(resetAt: Date?) -> String {
        if let resetAt {
            return String(
                format: String(localized: "GitHub says more requests are available after %@."),
                resetAt.formatted(date: .omitted, time: .shortened)
            )
        }
        return String(localized: "GitHub did not provide a reset time. Try again later.")
    }
}

/// Token-related error classification for monitor recovery actions.
private extension GitHubClientError {
    /// Whether the failure can be resolved by changing the GitHub token in Settings.
    var isGitHubAuthorizationRecoverable: Bool {
        switch self {
        case .noToken, .authenticationFailed, .missingScope(_), .repositoryDenied(_), .tokenStorageFailed:
            true
        case .rateLimited(_), .networkUnavailable, .server(_), .invalidResponse, .decodingFailed, .githubError:
            false
        }
    }
}

/// Sheet for choosing the single GitHub repository monitored by v1.
private struct RepositorySetupSheet: View {
    /// Store that owns repository persistence.
    var store: AgentPRMonitorStore

    /// Repository owner or organization login.
    @State private var owner = ""
    /// Repository name without owner prefix.
    @State private var name = ""
    /// Dismisses the setup sheet after save or cancel.
    @Environment(\.dismiss) private var dismiss

    /// Compact owner/name setup form.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Repository")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Enter the GitHub repository to monitor. CodingBuddy reads open pull requests only.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Owner")
                    TextField("apps3k-com", text: $owner)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Repository")
                    TextField("CodingBuddy", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save Repository") {
                    let repository = GitHubRepositoryRef(
                        owner: owner.trimmingCharacters(in: .whitespacesAndNewlines),
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    store.selectRepository(repository)
                    dismiss()
                    store.refresh()
                }
                .buttonStyle(.borderedProminent)
                .disabled(owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear {
            owner = store.selectedRepository?.owner ?? ""
            name = store.selectedRepository?.name ?? ""
        }
    }
}

/// Compact CI state label.
private struct CheckStateCell: View {
    /// Check summary represented by the cell.
    var summary: AgentPRCheckSummary

    /// Label with semantic color and optional failing context help.
    var body: some View {
        Label {
            Text(summary.state.displayName)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .help(summary.failingContextNames.joined(separator: ", "))
    }

    /// SF Symbol for the CI state.
    private var systemImage: String {
        switch summary.state {
        case .green:
            "checkmark.circle.fill"
        case .waiting:
            "clock.fill"
        case .failed:
            "xmark.octagon.fill"
        case .unknown:
            "questionmark.circle"
        }
    }

    /// Semantic color for the CI state.
    private var tint: Color {
        switch summary.state {
        case .green:
            .green
        case .waiting:
            .orange
        case .failed:
            .red
        case .unknown:
            .secondary
        }
    }
}

/// Compact review state label.
private struct ReviewStateCell: View {
    /// Review summary represented by the cell.
    var summary: AgentPRReviewSummary

    /// Label with semantic review state color.
    var body: some View {
        Label {
            Text(summary.state.displayName)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }

    /// SF Symbol for the review state.
    private var systemImage: String {
        switch summary.state {
        case .approved:
            "checkmark.seal.fill"
        case .reviewRequired, .pending:
            "person.crop.circle.badge.clock"
        case .changesRequested:
            "exclamationmark.bubble.fill"
        case .unknown:
            "questionmark.circle"
        }
    }

    /// Semantic color for the review state.
    private var tint: Color {
        switch summary.state {
        case .approved:
            .green
        case .reviewRequired, .pending:
            .orange
        case .changesRequested:
            .red
        case .unknown:
            .secondary
        }
    }
}

/// Compact review findings state label.
private struct FindingsStateCell: View {
    /// Findings state represented by the cell.
    var state: AgentPRFindingsState

    /// Label with provider-agnostic finding status.
    var body: some View {
        Label {
            Text(state.displayName)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }

    /// SF Symbol for the findings state.
    private var systemImage: String {
        switch state {
        case .none:
            "checkmark.circle"
        case .unresolvedFindings:
            "bubble.left.and.exclamationmark.bubble.right.fill"
        case .changesRequested:
            "exclamationmark.triangle.fill"
        case .reviewPending:
            "clock.fill"
        }
    }

    /// Semantic color for the findings state.
    private var tint: Color {
        switch state {
        case .none:
            .green
        case .unresolvedFindings, .reviewPending:
            .orange
        case .changesRequested:
            .red
        }
    }
}

/// Compact advisory readiness label.
private struct ReadinessStateCell: View {
    /// Readiness state represented by the cell.
    var state: AgentPRMergeReadinessState

    /// Label with advisory readiness status.
    var body: some View {
        Label {
            Text(state.displayName)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }

    /// SF Symbol for readiness.
    private var systemImage: String {
        switch state {
        case .ready:
            "checkmark.circle.fill"
        case .waiting:
            "clock.fill"
        case .attentionNeeded:
            "exclamationmark.triangle.fill"
        case .blocked:
            "minus.circle.fill"
        }
    }

    /// Semantic color for readiness.
    private var tint: Color {
        switch state {
        case .ready:
            .green
        case .waiting:
            .orange
        case .attentionNeeded, .blocked:
            .red
        }
    }
}
