//
//  PullRequestReviewDeskView.swift
//  CodingBuddy
//

import AppKit
import SwiftUI

/// Focused native workbench for reading and acting on one GitHub pull request.
struct PullRequestReviewDeskView: View {
    /// Inspector sections available through the segmented control.
    private enum InspectorSection: String, CaseIterable, Identifiable {
        /// Pull request state and action gate.
        case summary
        /// Top-level comments and inline review threads.
        case conversation
        /// Current-head checks and status contexts.
        case checks

        /// Stable picker identity.
        var id: String { rawValue }

        /// Localized picker label.
        var title: String {
            switch self {
            case .summary: String(localized: "Summary")
            case .conversation: String(localized: "Conversation")
            case .checks: String(localized: "Checks")
            }
        }
    }

    /// User-selectable queue ordering for fast multi-PR triage.
    private enum QueueOrder: String, CaseIterable, Identifiable {
        /// Prioritize actionable reviews and failing checks.
        case attention
        /// Show most recently updated pull requests first.
        case recent
        /// Group repositories alphabetically, then by pull request number.
        case repository

        /// Stable picker identity.
        var id: String { rawValue }

        /// Localized menu label.
        var title: String {
            switch self {
            case .attention: String(localized: "Needs Attention First")
            case .recent: String(localized: "Recently Updated")
            case .repository: String(localized: "Repository")
            }
        }
    }

    /// Existing monitor state supplying the cross-repository PR queue.
    var monitorStore: AgentPRMonitorStore
    /// Dedicated complete-snapshot and action state machine.
    var store: PullRequestReviewDeskStore
    /// Opens Settings on the GitHub authorization pane.
    var openSettings: () -> Void

    /// Selected monitor row identity.
    @State private var selection: AgentPullRequest.ID?
    /// Search text applied to the monitor rows.
    @State private var searchText = ""
    /// Visible inspector section.
    @State private var inspectorSection = InspectorSection.summary
    /// Thread selected for a reply.
    @State private var selectedThreadID: String?
    /// Draft reply body retained only in this view.
    @State private var replyBody = ""
    /// Queue ordering optimized for larger daily review sets.
    @State private var queueOrder = QueueOrder.attention
    /// Whether the inspector is visible at the current window width.
    @State private var showsInspector = true
    /// Whether the user is confirming that they manually checked an uncertain write.
    @State private var showsAmbiguousAcknowledgement = false
    /// Keyboard focus for the inline reply editor.
    @FocusState private var replyEditorFocused: Bool
    /// VoiceOver focus for important action-state transitions.
    @AccessibilityFocusState private var actionStatusFocused: Bool

    /// Monitor rows matching the current search.
    private var filteredRows: [AgentPullRequest] {
        let matching = monitorStore.rows.filter {
            $0.matches(searchText: searchText) || $0.id == selection
        }
        return matching.sorted(by: queueSort)
    }

    /// Stable workbench layout and action toolbar.
    var body: some View {
        HSplitView {
            pullRequestTable
                .frame(minWidth: 320, idealWidth: 520)
            if showsInspector {
                inspector
                    .frame(minWidth: 300, idealWidth: 440)
            }
        }
        .navigationTitle("Review Desk")
        .searchable(text: $searchText, prompt: "Search pull requests")
        .toolbar { reviewDeskToolbar }
        .onChange(of: selection) { handleSelectionChange() }
        .onAppear { handleAppearance() }
        .onChange(of: monitorStore.rows) { reconcileSelection() }
        .onChange(of: store.actionState) { handleActionStateChange() }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { store.pendingConfirmation != nil },
                set: { if !$0 { store.cancelConfirmation() } }
            )
        ) {
            Button(confirmationButtonTitle, role: confirmationRole) {
                store.confirmPendingAction()
            }
            Button("Cancel", role: .cancel) {
                store.cancelConfirmation()
            }
        } message: {
            Text(confirmationMessage)
        }
        .confirmationDialog(
            "Continue after checking GitHub?",
            isPresented: $showsAmbiguousAcknowledgement
        ) {
            Button("I Checked on GitHub") {
                store.acknowledgeAmbiguousAction()
                reconcileSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("CodingBuddy could not prove whether the last action was applied. Continuing can duplicate that action unless you checked the pull request on GitHub.")
        }
    }

    /// Applies table selection only when no mutation owns the previous target.
    private func handleSelectionChange() {
        guard let selection else {
            if !store.clearSelection() {
                self.selection = selectedRowID
            }
            return
        }
        guard let pullRequest = monitorStore.rows.first(where: { $0.id == selection }) else {
            reconcileSelection()
            return
        }
        if store.select(pullRequest) {
            selectedThreadID = nil
            replyBody = ""
        } else {
            self.selection = selectedRowID
        }
    }

    /// Starts an available monitor read and selects a deterministic first row.
    private func handleAppearance() {
        if monitorStore.lastRefreshCompletedAt == nil,
           !monitorStore.isRefreshing,
           !monitorStore.watchedRepositories.isEmpty {
            monitorStore.refresh()
        }
        reconcileSelection()
    }

    /// Keeps selection aligned with current rows without switching a mutation-owned target.
    private func reconcileSelection() {
        if let selection, monitorStore.rows.contains(where: { $0.id == selection }) {
            return
        }
        selection = nil
        guard store.actionState.allowsNewAction,
              store.pendingConfirmation == nil,
              let first = filteredRows.first else {
            return
        }
        _ = store.clearSelection()
        selection = first.id
    }

    /// Announces action-state changes and clears only a server-verified reply draft.
    private func handleActionStateChange() {
        actionStatusFocused = store.actionState != .idle
        if case .succeeded = store.actionState,
           case .reply(let threadID, _) = store.lastVerifiedAction,
           threadID == selectedThreadID {
            replyBody = ""
            selectedThreadID = nil
            replyEditorFocused = false
        }
        if store.actionState.allowsNewAction {
            reconcileSelection()
        }
    }

    /// Compact native commands kept outside the main view expression for compiler stability.
    @ToolbarContentBuilder private var reviewDeskToolbar: some ToolbarContent {
        ToolbarItemGroup {
            refreshButton
            inspectorPicker
            queueOrderMenu
            inspectorVisibilityButton
        }
    }

    /// Refresh command disabled while another state transition owns the snapshot.
    private var refreshButton: some View {
        Button {
            monitorStore.refresh()
            if store.selectedTarget != nil {
                store.refresh()
            }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help("Refresh queue and selected pull request")
        .keyboardShortcut("r", modifiers: .command)
        .disabled(
            monitorStore.watchedRepositories.isEmpty
                || monitorStore.isRefreshing
                || store.state == .loading
                || !store.actionState.allowsNewAction
        )
    }

    /// Segmented inspector section picker.
    private var inspectorPicker: some View {
        Picker("Inspector", selection: $inspectorSection) {
            ForEach(InspectorSection.allCases) { section in
                Text(verbatim: section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    /// Queue ordering menu for larger review sets.
    private var queueOrderMenu: some View {
        Menu {
            Picker("Sort", selection: $queueOrder) {
                ForEach(QueueOrder.allCases) { order in
                    Text(verbatim: order.title).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("Sort pull requests")
    }

    /// Inspector visibility command with a macOS-standard keyboard shortcut.
    private var inspectorVisibilityButton: some View {
        Button {
            showsInspector.toggle()
        } label: {
            Image(systemName: "sidebar.right")
        }
        .help(showsInspector ? "Hide inspector" : "Show inspector")
        .keyboardShortcut("i", modifiers: [.command, .option])
    }

    /// Dense native table for monitored pull requests.
    private var pullRequestTable: some View {
        VStack(spacing: 0) {
            queueCoverageStatus
            Table(filteredRows, selection: $selection) {
                TableColumn("Pull Request") { pullRequest in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pullRequest.title)
                            .lineLimit(1)
                        Text("\(pullRequest.repository.displayName) #\(pullRequest.number)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let freshness = repositoryFreshness(for: pullRequest.repository) {
                            HStack(spacing: 4) {
                                Label(freshness.label, systemImage: "clock.badge.exclamationmark")
                                if let date = monitorStore.repositoryLastSuccessfulRefreshAt[pullRequest.repository] {
                                    Text(date, style: .relative)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .width(min: 210, ideal: 300)

                TableColumn("Review") { pullRequest in
                    Label(
                        pullRequest.review.findingsState.displayName,
                        systemImage: pullRequest.review.unresolvedFindingCount > 0
                            ? "text.bubble.fill"
                            : "checkmark.bubble"
                    )
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                }
                .width(min: 120, ideal: 150)

                TableColumn("CI") { pullRequest in
                    Text(pullRequest.checks.state.displayName)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 100)
            }
            .overlay {
                if monitorStore.rows.isEmpty {
                    if monitorStore.isRefreshing || monitorStore.state == .loading {
                        ProgressView("Loading pull requests...")
                            .controlSize(.small)
                    } else {
                        ContentUnavailableView {
                            Label("No pull requests", systemImage: "arrow.triangle.pull")
                        } description: {
                            Text("Choose repositories in Agent PR Monitor, then refresh the Review Desk.")
                        }
                    }
                } else if filteredRows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    /// Visible provenance for complete, refreshing, partial, and unavailable queue snapshots.
    @ViewBuilder private var queueCoverageStatus: some View {
        switch monitorStore.queueCoverage {
        case .notConfigured:
            EmptyView()
        case .refreshing(let completedAt):
            queueStatusBand(String(localized: "Refreshing queue..."), systemImage: "arrow.clockwise", date: completedAt)
        case .complete(let completedAt):
            queueStatusBand(String(localized: "Queue current"), systemImage: "checkmark.circle", date: completedAt)
        case .partial(let completedAt, let repositories):
            queueStatusBand(
                queueCoverageDescription(
                    prefix: String(localized: "Partial queue"),
                    repositories: repositories
                ),
                systemImage: "exclamationmark.triangle",
                date: completedAt
            )
        case .unavailable(let repositories):
            queueStatusBand(
                queueCoverageDescription(
                    prefix: String(localized: "Queue unavailable"),
                    repositories: repositories
                ),
                systemImage: "xmark.octagon",
                date: nil
            )
        }
    }

    /// Compact status band that does not compete with table rows or the inspector.
    private func queueStatusBand(_ title: String, systemImage: String, date: Date?) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption)
            Spacer()
            if let date {
                Text(date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    /// Inspector switches among summary, conversation, and checks without nesting cards.
    @ViewBuilder private var inspector: some View {
        if let snapshot = store.snapshot {
            VStack(spacing: 0) {
                inspectorHeader(snapshot)
                retainedSnapshotStatus(snapshot)
                Divider()
                Group {
                    switch inspectorSection {
                    case .summary:
                        summaryInspector(snapshot)
                    case .conversation:
                        conversationInspector(snapshot)
                    case .checks:
                        checksInspector(snapshot)
                    }
                }
                actionStatus
            }
        } else {
            emptyInspector
        }
    }

    /// Compact identity header that keeps the product object visible.
    private func inspectorHeader(_ snapshot: PullRequestReviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Button {
                    NSWorkspace.shared.open(snapshot.url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open pull request on GitHub")
            }
            Text("\(snapshot.target.repository.displayName) #\(snapshot.target.number)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    /// Pull request gate details and high-risk actions.
    private func summaryInspector(_ snapshot: PullRequestReviewSnapshot) -> some View {
        Form {
            Section("Branches") {
                LabeledContent("Head", value: snapshot.headRefName)
                LabeledContent("Base", value: snapshot.baseRefName)
                LabeledContent("Commit", value: String(snapshot.headOID.prefix(12)))
            }
            Section("Review state") {
                LabeledContent("Decision", value: reviewDecisionLabel(snapshot.reviewDecision))
                LabeledContent("Open threads", value: "\(snapshot.unresolvedThreads.count)")
                LabeledContent("Approvals", value: "\(snapshot.approvals.count)")
                LabeledContent("Merge state", value: mergeStateLabel(snapshot.mergeState))
                LabeledContent(
                    "Server enforcement",
                    value: snapshot.mergePolicy.enforcesReviewDeskGates
                        ? String(localized: "Enforced by GitHub")
                        : String(localized: "Not proven")
                )
            }
            Section("Actions") {
                if snapshot.isDraft {
                    Button("Mark Ready for Review...") {
                        store.requestMarkReadyConfirmation()
                    }
                    .disabled(!store.actionsAreEnabled)
                }
                if !snapshot.mergeMethods.available.isEmpty {
                    Menu("Merge Pull Request...") {
                        ForEach(snapshot.mergeMethods.available, id: \.self) { method in
                            Button(mergeMethodButtonLabel(method)) {
                                store.requestMergeConfirmation(method: method)
                            }
                        }
                    }
                    .disabled(!store.actionsAreEnabled || !snapshot.isMergeEligible)
                } else {
                    Text("No repository merge method is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !snapshot.isMergeEligible {
                    Text("Merge remains unavailable until GitHub-enforced branch protection has no bypasses, required checks are green, approval is satisfied, all threads are resolved, and GitHub reports a clean merge state.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Full conversation with unresolved threads first and one focused reply editor.
    private func conversationInspector(_ snapshot: PullRequestReviewSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let unresolved = snapshot.reviewThreads.filter { !$0.isResolved && !$0.isOutdated }
                let historical = snapshot.reviewThreads.filter { $0.isResolved || $0.isOutdated }

                if !unresolved.isEmpty {
                    inspectorSectionHeader("Unresolved threads", count: unresolved.count)
                    ForEach(unresolved, id: \.id) { thread in
                        reviewThread(thread, actionsEnabled: store.actionsAreEnabled)
                        Divider()
                    }
                }

                if !snapshot.conversationComments.isEmpty {
                    inspectorSectionHeader("Conversation", count: snapshot.conversationComments.count)
                    ForEach(snapshot.conversationComments, id: \.id) { comment in
                        conversationComment(comment)
                        Divider()
                    }
                }

                if !historical.isEmpty {
                    DisclosureGroup("Resolved and outdated (\(historical.count))") {
                        ForEach(historical, id: \.id) { thread in
                            reviewThread(thread, actionsEnabled: false)
                            Divider()
                        }
                    }
                    .padding(12)
                }

                if snapshot.reviewThreads.isEmpty && snapshot.conversationComments.isEmpty {
                    ContentUnavailableView(
                        "No conversation",
                        systemImage: "text.bubble",
                        description: Text("GitHub returned no comments or review threads for this pull request.")
                    )
                    .padding(.top, 40)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let threadID = selectedThreadID {
                replyEditor(threadID: threadID)
                    .background(.bar)
            }
        }
    }

    /// One inline review thread and its complete reply history.
    private func reviewThread(
        _ thread: PullRequestReviewThread,
        actionsEnabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    thread.path ?? String(localized: "Review thread"),
                    systemImage: thread.isResolved ? "checkmark.circle" : "text.bubble.fill"
                )
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                Spacer()
                if thread.isOutdated {
                    Text("Outdated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(thread.comments, id: \.id) { comment in
                VStack(alignment: .leading, spacing: 3) {
                    Text(comment.authorLogin ?? String(localized: "Unknown author"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(comment.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if actionsEnabled && !thread.isResolved {
                HStack {
                    Button("Reply") {
                        if selectedThreadID != thread.id {
                            replyBody = ""
                            selectedThreadID = thread.id
                        }
                        replyEditorFocused = true
                    }
                    Button("Resolve") {
                        store.resolve(threadID: thread.id)
                    }
                    .disabled(!store.actionsAreEnabled)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
    }

    /// Focused reply editor for the selected inline thread.
    private func replyEditor(threadID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reply to review thread")
                .font(.caption.weight(.semibold))
            TextEditor(text: $replyBody)
                .frame(height: 72)
                .font(.body)
                .accessibilityLabel("Reply body")
                .focused($replyEditorFocused)
            HStack {
                Button("Cancel", role: .cancel) {
                    selectedThreadID = nil
                    replyBody = ""
                }
                Spacer()
                Button("Send Reply") {
                    store.reply(threadID: threadID, body: replyBody)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(
                    replyBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !store.actionsAreEnabled
                )
            }
        }
        .padding(12)
    }

    /// One top-level pull request comment.
    private func conversationComment(_ comment: PullRequestConversationComment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(comment.authorLogin ?? String(localized: "Unknown author"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(comment.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(comment.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    /// Current-head checks with explicit required state.
    private func checksInspector(_ snapshot: PullRequestReviewSnapshot) -> some View {
        List(snapshot.checks, id: \.id) { check in
            HStack(spacing: 10) {
                Image(systemName: checkSymbol(check.state))
                    .foregroundStyle(checkColor(check.state))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.name)
                        .lineLimit(1)
                    if check.isRequired {
                        Text("Required")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(checkStateLabel(check.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detailsURL = check.detailsURL {
                    Button {
                        NSWorkspace.shared.open(detailsURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .help("Open check details")
                }
            }
            .accessibilityElement(children: .contain)
        }
        .overlay {
            if snapshot.checks.isEmpty {
                ContentUnavailableView(
                    "No checks",
                    systemImage: "checkmark.circle",
                    description: Text("GitHub returned no checks for the current head commit.")
                )
            }
        }
    }

    /// Empty, loading, and recovery states before a snapshot is available.
    @ViewBuilder private var emptyInspector: some View {
        switch store.state {
        case .idle:
            ContentUnavailableView(
                "Select a pull request",
                systemImage: "sidebar.right",
                description: Text("Choose one pull request to inspect its full conversation and checks.")
            )
        case .loading:
            ProgressView("Loading complete pull request state...")
                .controlSize(.small)
        case .failed(let message):
            ContentUnavailableView {
                Label("Pull request unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { store.refresh() }
                Button("GitHub Settings") { openSettings() }
            }
        case .loaded:
            ContentUnavailableView("No snapshot", systemImage: "questionmark.folder")
        }
    }

    /// Persistent action progress or terminal notice below the inspector.
    @ViewBuilder private var actionStatus: some View {
        Group {
            switch store.actionState {
            case .idle:
                EmptyView()
            case .preflighting:
                statusBar(String(localized: "Checking current GitHub state..."), systemImage: "arrow.triangle.2.circlepath")
            case .executing:
                statusBar(String(localized: "Applying action on GitHub..."), systemImage: "arrow.up.circle")
            case .verifying:
                statusBar(String(localized: "Verifying GitHub state..."), systemImage: "checkmark.circle")
            case .succeeded(let message):
                statusBar(message, systemImage: "checkmark.circle.fill")
            case .drifted:
                statusBar(
                    String(localized: "The pull request changed. Review the refreshed state."),
                    systemImage: "arrow.triangle.2.circlepath"
                )
            case .ambiguous:
                ambiguousStatusBar
            case .failed(let message):
                statusBar(message, systemImage: "exclamationmark.triangle.fill")
            }
        }
        .accessibilityFocused($actionStatusFocused)
    }

    /// Recovery controls that keep an uncertain write blocked until proof or acknowledgement.
    private var ambiguousStatusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "The action result is uncertain. Verify again or check GitHub before continuing.",
                systemImage: "questionmark.circle"
            )
            .font(.caption)
            ViewThatFits(in: .horizontal) {
                ambiguousRecoveryControls(horizontal: true)
                ambiguousRecoveryControls(horizontal: false)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.bar)
    }

    /// Recovery actions that wrap vertically when translated labels need more room.
    @ViewBuilder private func ambiguousRecoveryControls(horizontal: Bool) -> some View {
        if horizontal {
            HStack {
                Button("Verify Again") { store.verifyAmbiguousAction() }
                if let url = store.snapshot?.url {
                    Button("Open GitHub") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button("I Checked...") { showsAmbiguousAcknowledgement = true }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button("Verify Again") { store.verifyAmbiguousAction() }
                if let url = store.snapshot?.url {
                    Button("Open GitHub") { NSWorkspace.shared.open(url) }
                }
                Button("I Checked...") { showsAmbiguousAcknowledgement = true }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One compact status strip.
    private func statusBar(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: systemImage)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            if store.actionState.allowsNewAction {
                Button {
                    store.clearActionNotice()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Dismiss status")
            }
        }
        .padding(8)
        .background(.bar)
    }

    /// Section heading with a stable count.
    private func inspectorSectionHeader(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    /// Confirmation title determined by the bound high-risk action.
    private var confirmationTitle: String {
        switch store.pendingConfirmation {
        case .markReady: String(localized: "Mark pull request ready for review?")
        case .merge: String(localized: "Merge pull request?")
        case nil: String(localized: "Confirm GitHub action")
        }
    }

    /// Destructive styling applies only to the irreversible merge action.
    private var confirmationRole: ButtonRole? {
        if case .merge = store.pendingConfirmation { return .destructive }
        return nil
    }

    /// Confirmation command label.
    private var confirmationButtonTitle: String {
        switch store.pendingConfirmation {
        case .markReady: String(localized: "Mark Ready")
        case .merge: String(localized: "Merge")
        case nil: String(localized: "Confirm")
        }
    }

    /// State-bound confirmation detail with the expected head prefix.
    private var confirmationMessage: String {
        guard let confirmation = store.pendingConfirmation else { return "" }
        let head = String(confirmation.expectedHeadOID.prefix(12))
        let target = store.snapshot.map {
            "\($0.target.repository.displayName) #\($0.target.number) — \($0.title)"
        } ?? String(localized: "Selected pull request")
        switch confirmation {
        case .markReady:
            return String(
                format: String(localized: "CodingBuddy will re-check draft state and head %@ before changing %@."),
                head,
                target
            )
        case .merge(let method, _):
            return String(
                format: String(localized: "CodingBuddy will re-check approvals, threads, checks, merge state, and head %@ before %@ with %@."),
                head,
                mergeMethodLabel(method),
                target
            )
        }
    }

    /// Selected table row corresponding to the store-owned target.
    private var selectedRowID: AgentPullRequest.ID? {
        guard let target = store.selectedTarget else { return nil }
        return monitorStore.rows.first {
            $0.repository == target.repository && $0.number == target.number
        }?.id
    }

    /// Stable queue ordering with identity tie-breakers.
    private func queueSort(_ lhs: AgentPullRequest, _ rhs: AgentPullRequest) -> Bool {
        switch queueOrder {
        case .attention:
            let left = attentionRank(lhs)
            let right = attentionRank(rhs)
            return left == right ? (lhs.updatedAt, lhs.id) > (rhs.updatedAt, rhs.id) : left < right
        case .recent:
            return (lhs.updatedAt, lhs.id) > (rhs.updatedAt, rhs.id)
        case .repository:
            return (lhs.repository.canonicalID, lhs.number) < (rhs.repository.canonicalID, rhs.number)
        }
    }

    /// Conservative attention rank for daily triage.
    private func attentionRank(_ pullRequest: AgentPullRequest) -> Int {
        if repositoryFreshness(for: pullRequest.repository) != nil { return 0 }
        if pullRequest.review.unresolvedFindingCount > 0
            || pullRequest.review.findingsState == .changesRequested { return 0 }
        if pullRequest.checks.state == .failed { return 1 }
        if pullRequest.readiness.state == .waiting { return 2 }
        return 3
    }

    /// Visible freshness or failure status retained above an older snapshot.
    @ViewBuilder private func retainedSnapshotStatus(_ snapshot: PullRequestReviewSnapshot) -> some View {
        switch store.state {
        case .loading:
            statusBar(String(localized: "Refreshing GitHub state..."), systemImage: "arrow.clockwise")
        case .failed(let message):
            statusBar(message, systemImage: "exclamationmark.triangle.fill")
        case .loaded:
            HStack {
                Label("Complete snapshot", systemImage: "checkmark.shield")
                Spacer()
                Text(snapshot.capturedAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
        case .idle:
            EmptyView()
        }
    }

    /// Localized merge method used in strict confirmation copy.
    private func mergeMethodLabel(_ method: PullRequestMergeMethod) -> String {
        switch method {
        case .merge: String(localized: "merge commit")
        case .squash: String(localized: "squash merge")
        case .rebase: String(localized: "rebase merge")
        }
    }

    /// Command label for one repository-enabled merge method.
    private func mergeMethodButtonLabel(_ method: PullRequestMergeMethod) -> String {
        switch method {
        case .merge: String(localized: "Create Merge Commit")
        case .squash: String(localized: "Squash and Merge")
        case .rebase: String(localized: "Rebase and Merge")
        }
    }

    /// Visible stale state for one cached repository row.
    private func repositoryFreshness(
        for repository: GitHubRepositoryRef
    ) -> (label: String, error: String?)? {
        switch monitorStore.repositoryRefreshStates[repository] {
        case .loaded?, .empty?:
            nil
        case .loading?:
            (String(localized: "Refreshing"), nil)
        case .needsToken?:
            (String(localized: "GitHub access unavailable"), nil)
        case .needsRepository?:
            (String(localized: "Repository unavailable"), nil)
        case .rateLimited(let resetAt)?:
            (
                String(localized: "Rate limited"),
                resetAt.map { String(localized: "Retry after \($0.formatted(date: .omitted, time: .shortened))") }
            )
        case .refreshFailed(let error)?:
            (String(localized: "Refresh failed"), error.localizedDescription)
        case .idle?, nil:
            (String(localized: "Not refreshed"), nil)
        }
    }

    /// Names every incomplete repository and includes its safe failure reason when available.
    private func queueCoverageDescription(
        prefix: String,
        repositories: [GitHubRepositoryRef]
    ) -> String {
        let details = repositories.map { repository in
            guard let freshness = repositoryFreshness(for: repository) else {
                return repository.displayName
            }
            let reason = freshness.error ?? freshness.label
            return "\(repository.displayName): \(reason)"
        }
        return "\(prefix): \(details.joined(separator: ", "))"
    }

    /// Human-readable review decision.
    private func reviewDecisionLabel(_ decision: PullRequestReviewDecision) -> String {
        switch decision {
        case .approved: String(localized: "Approved")
        case .changesRequested: String(localized: "Changes requested")
        case .reviewRequired: String(localized: "Review required")
        case .none: String(localized: "No review requirement")
        case .unknown: String(localized: "Unknown")
        }
    }

    /// Human-readable merge state.
    private func mergeStateLabel(_ state: PullRequestMergeState) -> String {
        switch state {
        case .behind: String(localized: "Behind base branch")
        case .blocked: String(localized: "Blocked")
        case .clean: String(localized: "Clean")
        case .dirty: String(localized: "Conflicts")
        case .hasHooks: String(localized: "Hooks pending")
        case .unstable: String(localized: "Checks pending")
        case .unknown: String(localized: "Unknown")
        }
    }

    /// Symbol for a normalized check state.
    private func checkSymbol(_ state: PullRequestCheckState) -> String {
        switch state {
        case .success: "checkmark.circle.fill"
        case .pending: "clock.fill"
        case .neutral, .skipped: "minus.circle.fill"
        case .failure, .cancelled, .timedOut, .actionRequired: "xmark.circle.fill"
        case .stale, .unknown: "questionmark.circle.fill"
        }
    }

    /// Semantic color for a normalized check state.
    private func checkColor(_ state: PullRequestCheckState) -> Color {
        switch state {
        case .success: .green
        case .pending: .orange
        case .neutral, .skipped: .secondary
        case .failure, .cancelled, .timedOut, .actionRequired: .red
        case .stale, .unknown: .secondary
        }
    }

    /// Human-readable check state.
    private func checkStateLabel(_ state: PullRequestCheckState) -> String {
        switch state {
        case .pending: String(localized: "Pending")
        case .success: String(localized: "Passed")
        case .failure: String(localized: "Failed")
        case .neutral: String(localized: "Neutral")
        case .skipped: String(localized: "Skipped")
        case .cancelled: String(localized: "Cancelled")
        case .timedOut: String(localized: "Timed out")
        case .actionRequired: String(localized: "Action required")
        case .stale: String(localized: "Stale")
        case .unknown: String(localized: "Unknown")
        }
    }
}
