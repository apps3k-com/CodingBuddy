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

    /// Subtitle summarizing the currently watched repositories.
    private var repositorySubtitle: String {
        switch store.watchedRepositories.count {
        case 0:
            String(localized: "No repository selected")
        case 1:
            store.watchedRepositories[0].displayName
        default:
            String(
                format: String(localized: "%lld repositories"),
                Int64(store.watchedRepositories.count)
            )
        }
    }

    /// Recoverable authorization failure shown while stale rows remain visible.
    private var staleAuthorizationFailure: GitHubClientError? {
        guard case .refreshFailed(let error) = store.state,
              !store.rows.isEmpty,
              error.isGitHubAuthorizationRecoverable else {
            return nil
        }
        return error
    }

    /// Per-repository refresh states that need user attention while other repositories may still show rows.
    private var repositoryRefreshIssues: [(repository: GitHubRepositoryRef, state: AgentPRMonitorState)] {
        store.watchedRepositories.compactMap { repository in
            guard let state = store.repositoryRefreshStates[repository] else { return nil }
            switch state {
            case .needsToken, .rateLimited, .refreshFailed:
                return (repository, state)
            case .idle, .needsRepository, .loading, .loaded, .empty:
                return nil
            }
        }
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

            TableColumn("Repository") { row in
                Text(verbatim: row.repository.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 150, ideal: 190)

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
        .navigationSubtitle(Text(verbatim: repositorySubtitle))
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
                .disabled(store.watchedRepositories.isEmpty || store.isRefreshing)

                Button("Repositories...", systemImage: "book.closed") {
                    showsRepositorySheet = true
                }
                .help("Choose the GitHub repositories to monitor")
            }
        }
        .overlay {
            overlayView
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let staleAuthorizationFailure {
                    authorizationRecoveryBanner(staleAuthorizationFailure)
                }
                if !repositoryRefreshIssues.isEmpty {
                    repositoryIssueBanner(repositoryRefreshIssues)
                }
            }
        }
        .sheet(isPresented: $showsRepositorySheet) {
            RepositorySetupSheet(store: store, openSettings: openSettings)
        }
        .onAppear {
            if !store.watchedRepositories.isEmpty, store.rows.isEmpty, store.state == .idle {
                store.refresh()
            }
        }
    }

    /// Compact recovery prompt shown above stale pull request rows.
    private func authorizationRecoveryBanner(_ error: GitHubClientError) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("GitHub authorization needs attention")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Open Settings") { openSettings() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// Compact summary for partial repository refresh failures.
    private func repositoryIssueBanner(_ issues: [(repository: GitHubRepositoryRef, state: AgentPRMonitorState)]) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Repository refresh issues")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(repositoryIssueMessage(issues))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if issues.contains(where: { $0.state.isGitHubAuthorizationRecoverable }) {
                Button("Open Settings") { openSettings() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// Human-readable summary for repository-scoped refresh failures.
    private func repositoryIssueMessage(
        _ issues: [(repository: GitHubRepositoryRef, state: AgentPRMonitorState)]
    ) -> String {
        if issues.count > 1 {
            return String(
                format: String(localized: "%lld repositories need attention."),
                Int64(issues.count)
            )
        }
        guard let issue = issues.first else { return "" }
        return issue.state.repositoryMessage(repository: issue.repository) ?? issue.repository.displayName
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
        } else if store.watchedRepositories.isEmpty {
            ContentUnavailableView {
                Label("No repository selected", systemImage: "book.closed")
            } description: {
                Text("Add at least one GitHub repository to monitor open pull requests.")
            } actions: {
                Button("Choose Repositories...") { showsRepositorySheet = true }
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
                    description: Text("CodingBuddy did not find open pull requests for the watched repositories.")
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

private extension AgentPRMonitorState {
    /// Whether this state can be recovered by changing GitHub authorization.
    var isGitHubAuthorizationRecoverable: Bool {
        switch self {
        case .needsToken:
            true
        case .refreshFailed(let error):
            error.isGitHubAuthorizationRecoverable
        case .idle, .needsRepository, .loading, .loaded, .empty, .rateLimited:
            false
        }
    }

    /// Repository-scoped status text for banners and watchlist rows.
    func repositoryMessage(repository: GitHubRepositoryRef) -> String? {
        switch self {
        case .idle, .needsRepository:
            return nil
        case .loading:
            return String(localized: "Loading")
        case .loaded:
            return String(localized: "Loaded")
        case .empty:
            return String(localized: "No open pull requests")
        case .needsToken:
            return String(format: String(localized: "%@ needs a GitHub token."), repository.displayName)
        case .rateLimited(let resetAt):
            if let resetAt {
                return String(
                    format: String(localized: "GitHub rate limit for %1$@ until %2$@."),
                    repository.displayName,
                    resetAt.formatted(date: .omitted, time: .shortened)
                )
            }
            return String(format: String(localized: "GitHub rate limit for %@."), repository.displayName)
        case .refreshFailed(let error):
            return String(
                format: String(localized: "Reload failed for %1$@: %2$@"),
                repository.displayName,
                error.localizedDescription
            )
        }
    }
}

/// Sheet for managing the GitHub repositories monitored by the Agent PR Monitor.
private struct RepositorySetupSheet: View {
    /// Store that owns repository persistence.
    var store: AgentPRMonitorStore
    /// Opens Settings for token recovery.
    var openSettings: () -> Void

    /// Search text applied to owner, repository name, full name, and description.
    @State private var searchText = ""
    /// Optional manual `owner/name` fallback.
    @State private var manualRepository = ""
    /// Selected repository row in the native list.
    @State private var selectedRepositoryID: GitHubRepositorySummary.ID?
    /// Dismisses the setup sheet after edits are finished.
    @Environment(\.dismiss) private var dismiss

    /// Repositories visible after applying the search text.
    private var filteredRepositories: [GitHubRepositorySummary] {
        store.repositoryChoices.filter { $0.matches(searchText: searchText) }
    }

    /// Currently selected repository summary.
    private var selectedRepository: GitHubRepositorySummary? {
        filteredRepositories.first { $0.id == selectedRepositoryID }
    }

    /// Parsed manual repository reference, if valid.
    private var manualRepositoryRef: GitHubRepositoryRef? {
        GitHubRepositoryRef(displayName: manualRepository.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Latest repository-load error when cached choices can still be selected.
    private var cachedRepositoryLoadError: GitHubClientError? {
        guard case .failed(let error) = store.repositoryPickerState,
              !store.repositoryChoices.isEmpty else {
            return nil
        }
        return error
    }

    /// Searchable repository picker with manual owner/name fallback.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Watched repositories")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Add repositories visible to the saved GitHub token.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !store.watchedRepositories.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Currently watched")
                        .font(.headline)
                    List(store.watchedRepositories) { repository in
                        WatchedRepositoryRow(
                            repository: repository,
                            state: store.repositoryRefreshStates[repository],
                            remove: {
                                store.removeWatchedRepository(repository)
                                if !store.watchedRepositories.isEmpty {
                                    store.refresh()
                                }
                            }
                        )
                    }
                    .frame(minHeight: 96, idealHeight: 120, maxHeight: 150)
                }
            }

            TextField("Search repositories", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    addSelectedRepository()
                }

            HStack {
                Text("Accessible repositories")
                    .font(.headline)
                Spacer()
                Button("Reload", systemImage: "arrow.clockwise") {
                    store.loadRepositoryChoices(force: true)
                }
                .disabled(store.repositoryPickerState == .loading)
            }

            ZStack {
                List(filteredRepositories, selection: $selectedRepositoryID) { repository in
                    RepositoryChoiceRow(
                        repository: repository,
                        isWatched: store.watchedRepositories.contains(repository.ref)
                    )
                    .tag(repository.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        add(repository.ref)
                    }
                }
                .frame(minHeight: 260)

                repositoryListOverlay
            }

            if let cachedRepositoryLoadError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("Repositories unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(cachedRepositoryLoadError.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if cachedRepositoryLoadError.isGitHubAuthorizationRecoverable {
                        Button("Open Settings") { openSettingsAfterDismiss() }
                            .controlSize(.small)
                    }
                    Button("Retry") {
                        store.loadRepositoryChoices(force: true)
                    }
                    .controlSize(.small)
                }
            }

            if store.repositoryChoicesAreTruncated {
                Label("Some repositories are hidden because the picker reached its page limit.", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Manual entry")
                    TextField("owner/name", text: $manualRepository)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addManualRepository()
                        }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Manual Entry") {
                    addManualRepository()
                }
                .disabled(manualRepositoryRef == nil || isWatched(manualRepositoryRef))
                Button("Add Repository") {
                    addSelectedRepository()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRepository == nil || isWatched(selectedRepository?.ref))
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            manualRepository = ""
            selectedRepositoryID = store.watchedRepositories.first?.id
            store.loadRepositoryChoices()
            keepSelectionVisible()
        }
        .onChange(of: searchText) {
            keepSelectionVisible()
        }
        .onChange(of: store.repositoryChoices) {
            keepSelectionVisible()
        }
        .onMoveCommand { direction in
            switch direction {
            case .up:
                moveSelection(by: -1)
            case .down:
                moveSelection(by: 1)
            default:
                break
            }
        }
    }

    /// Empty, loading, and error overlay for repository choices.
    @ViewBuilder private var repositoryListOverlay: some View {
        switch store.repositoryPickerState {
        case .idle:
            EmptyView()
        case .loading:
            if store.repositoryChoices.isEmpty {
                ProgressView(String(localized: "Loading repositories..."))
            }
        case .loaded:
            if filteredRepositories.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different owner, name, or description.")
                )
            }
        case .empty:
            ContentUnavailableView(
                "No repositories",
                systemImage: "tray",
                description: Text("The saved token did not return any accessible repositories.")
            )
        case .failed(let error):
            if store.repositoryChoices.isEmpty {
                ContentUnavailableView {
                    Label("Repositories unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    HStack {
                        if error.isGitHubAuthorizationRecoverable {
                            Button("Open Settings") { openSettingsAfterDismiss() }
                        }
                        Button("Retry") {
                            store.loadRepositoryChoices(force: true)
                        }
                    }
                }
            }
        }
    }

    /// Dismisses this sheet before opening Settings to avoid stacked sheet presentation issues.
    private func openSettingsAfterDismiss() {
        dismiss()
        DispatchQueue.main.async {
            openSettings()
        }
    }

    /// Keeps the selected row within the filtered list for keyboard confirmation.
    private func keepSelectionVisible() {
        guard !filteredRepositories.isEmpty else {
            selectedRepositoryID = nil
            return
        }
        if let selectedRepositoryID,
           filteredRepositories.contains(where: { $0.id == selectedRepositoryID }) {
            return
        }
        selectedRepositoryID = filteredRepositories.first?.id
    }

    /// Moves the highlighted repository for keyboard navigation.
    private func moveSelection(by offset: Int) {
        guard !filteredRepositories.isEmpty else {
            selectedRepositoryID = nil
            return
        }
        let currentIndex = selectedRepositoryID.flatMap { selectedID in
            filteredRepositories.firstIndex { $0.id == selectedID }
        } ?? (offset > 0 ? -1 : filteredRepositories.count)
        let nextIndex = min(max(currentIndex + offset, 0), filteredRepositories.count - 1)
        selectedRepositoryID = filteredRepositories[nextIndex].id
    }

    /// Returns true when the repository is already watched.
    private func isWatched(_ repository: GitHubRepositoryRef?) -> Bool {
        guard let repository else { return false }
        return store.watchedRepositories.contains(repository)
    }

    /// Adds the highlighted repository, if any.
    private func addSelectedRepository() {
        guard let selectedRepository else { return }
        add(selectedRepository.ref)
    }

    /// Adds the parsed manual repository fallback, if valid.
    private func addManualRepository() {
        guard let manualRepositoryRef else { return }
        add(manualRepositoryRef)
        manualRepository = ""
    }

    /// Persists a watched repository and refreshes the monitor.
    private func add(_ repository: GitHubRepositoryRef) {
        guard !store.watchedRepositories.contains(repository) else { return }
        store.addWatchedRepository(repository)
        store.refresh()
    }
}

/// Repository row used by the setup picker.
private struct RepositoryChoiceRow: View {
    /// Repository summary displayed by the row.
    var repository: GitHubRepositorySummary
    /// Whether this repository is currently monitored.
    var isWatched: Bool

    /// Native list row with owner/name, metadata, and watchlist marker.
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: repository.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let description = repository.description, !description.isEmpty {
                    Text(verbatim: description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if repository.isArchived {
                Label("Archived", systemImage: "archivebox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: repository.isPrivate ? "lock.fill" : "globe")
                .foregroundStyle(.secondary)
                .help(repository.isPrivate ? "Private repository" : "Public repository")

            if isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .help("Watched repository")
            }
        }
    }
}

/// Watched repository row with scoped refresh state and a remove action.
private struct WatchedRepositoryRow: View {
    /// Repository currently in the watchlist.
    var repository: GitHubRepositoryRef
    /// Latest scoped refresh state for this repository.
    var state: AgentPRMonitorState?
    /// Removes the repository from the watchlist.
    var remove: () -> Void

    /// Compact row for the watched repository list.
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            statusImage
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: repository.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let statusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                remove()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help(String(format: String(localized: "Remove %@"), repository.displayName))
        }
    }

    /// Semantic status icon for the latest repository refresh.
    @ViewBuilder private var statusImage: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .loaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .empty:
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
        case .needsToken, .rateLimited, .refreshFailed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .idle, .needsRepository, nil:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }

    /// Optional one-line scoped status text.
    private var statusText: String? {
        state?.repositoryMessage(repository: repository)
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
