//
//  ContentView.swift
//  CodingBuddy
//

import Foundation
import SwiftUI

/// Lifecycle of a sidebar data source whose first scan is triggered by navigation.
nonisolated enum SidebarLoadPhase: Equatable, Sendable {
    /// Discovery has not started and no result may be inferred.
    case neutral
    /// Discovery is currently running.
    case loading
    /// Discovery finished and the store result can be classified.
    case loaded
}

/// Conservative sidebar semantics for counts backed by local discovery.
nonisolated enum SidebarCountState: Equatable, Sendable {
    /// No reliable presence or count evidence is available.
    case neutral
    /// The source is actively being discovered.
    case loading
    /// Discovery completed without refusal and produced an exact count.
    case available(count: Int)
    /// Discovery refused all or part of the source data.
    case refused

    /// Numeric badge content is exposed only for a complete available snapshot.
    var badgeCount: Int? {
        guard case .available(let count) = self else { return nil }
        return count
    }

    /// Maps one shell file's explicit access result to truthful count semantics.
    static func shell(count: Int, accessState: EnvFileAccessState) -> Self {
        switch accessState {
        case .missing: .neutral
        case .loaded: .available(count: count)
        case .refused: .refused
        }
    }

    /// Treats every credential scan refusal as incomplete, including visible reset-only artifacts.
    static func mcpCredentials(
        count: Int,
        rootExists: Bool,
        hasScanRefusals: Bool
    ) -> Self {
        guard rootExists else { return .neutral }
        return hasScanRefusals ? .refused : .available(count: count)
    }

    /// Keeps backup inventory neutral or loading until its first bounded discovery finishes.
    static func backups(
        count: Int,
        phase: SidebarLoadPhase,
        hasDiscoveryError: Bool
    ) -> Self {
        switch phase {
        case .neutral: .neutral
        case .loading: .loading
        case .loaded: hasDiscoveryError ? .refused : .available(count: count)
        }
    }

    /// Uses Cursor's authoritative load result, including complete empty documents.
    static func cursor(
        count: Int,
        loadState: CursorStore.LoadState
    ) -> Self {
        switch loadState {
        case .missing: .neutral
        case .loaded: .available(count: count)
        case .refused: .refused
        }
    }

    /// Maps Claude Code discovery without collapsing a refused scan into neutral state.
    static func claudeCode(_ state: ClaudeCodeStore.SidebarState) -> Self {
        switch state {
        case .neutral, .missing: .neutral
        case .available(let count): .available(count: count)
        case .refused: .refused
        }
    }
}

/// Root split-view container for CodingBuddy.
struct ContentView: View {
    /// Shared menu command bridge.
    @Environment(MenuActions.self) private var menuActions
    /// Environment variable store.
    @State private var store = EnvStore()
    /// MCP authentication store.
    @State private var mcpAuthStore = MCPAuthStore()
    /// Codex configuration store.
    @State private var codexStore = CodexStore()
    /// Claude Code configuration store, created only when its destination opens.
    @State private var claudeCodeStore: ClaudeCodeStore?
    /// Cursor configuration store.
    @State private var cursorStore = CursorStore()
    /// Craft Agents configuration store.
    @State private var craftStore = CraftAgentStore()
    /// Agent Doctor store when the feature flag is enabled.
    @State private var agentDoctorStore: AgentDoctorStore? = FeatureFlag.agentDoctor.isEnabled ? AgentDoctorStore() : nil
    /// Agent Context store when the feature flag is enabled.
    @State private var agentContextInspectorStore: AgentContextInspectorStore? =
        FeatureFlag.agentContextInspector.isEnabled ? AgentContextInspectorStore() : nil
    /// Repo Readiness store when the feature flag is enabled.
    @State private var repoReadinessStore: RepoReadinessStore? =
        FeatureFlag.repoReadinessChecklist.isEnabled ? RepoReadinessStore() : nil
    /// MCP Inventory store when the feature flag is enabled.
    @State private var mcpServerInventoryStore: MCPServerInventoryStore? =
        FeatureFlag.mcpServerInventory.isEnabled && !FeatureFlag.capabilityHygiene.isEnabled
            ? MCPServerInventoryStore()
            : nil
    /// Capability Hygiene store when the feature flag is enabled.
    @State private var capabilityHygieneStore: CapabilityHygieneStore? =
        FeatureFlag.capabilityHygiene.isEnabled ? CapabilityHygieneStore() : nil
    /// GitHub authorization state shared between Settings and Agent PR Monitor.
    @State private var githubAuthorizationStore: GitHubAuthorizationStore
    /// Agent PR Monitor store when the feature flag is enabled.
    @State private var agentPRMonitorStore: AgentPRMonitorStore?
    /// Focused Review Desk store when the write-capable alpha feature is enabled.
    @State private var pullRequestReviewDeskStore: PullRequestReviewDeskStore?
    /// GitHub Projects workspace when the alpha feature is enabled.
    @State private var githubProjectsStore: GitHubProjectsStore?
    /// Backup Browser store when the feature flag is enabled.
    @State private var backupBrowserStore: BackupBrowserStore? =
        FeatureFlag.backupBrowser.isEnabled ? BackupBrowserStore() : nil
    /// First-load phase for the lazily scanned backup inventory.
    @State private var backupSidebarLoadPhase = SidebarLoadPhase.neutral
    /// Software Updates store when package maintenance is enabled.
    @State private var packageMaintenanceStore: PackageMaintenanceStore? =
        FeatureFlag.packageMaintenance.isEnabled ? PackageMaintenanceStore() : nil
    /// Secret masking state shared across editors.
    @State private var secrets = SecretsGuard()
    /// Current sidebar selection.
    @State private var scope: SidebarScope? = .all
    /// Persisted sidebar destination restored on relaunch.
    @AppStorage(SidebarSelectionState.storageKey) private var storedSidebarScope = SidebarScope.all.storageID
    /// Persisted collapsed top-level sidebar groups.
    @AppStorage("sidebar.collapsedSections") private var collapsedSidebarSections = ""
    /// Whether the settings sheet is visible.
    @State private var showSettings = false
    /// Settings pane requested by the action that opened Settings.
    @State private var requestedSettingsPane = SettingsInitialPane.general
    /// Injectable lazy constructor that keeps app and test-host startup free of Claude HOME reads.
    private let makeClaudeCodeStore: @MainActor () -> ClaudeCodeStore

    /// Creates root-owned stores and shares GitHub token persistence.
    init(
        githubTokenStore: any GitHubTokenStore = KeychainGitHubTokenStore(),
        makeClaudeCodeStore: @escaping @MainActor () -> ClaudeCodeStore = {
            ClaudeCodeStore(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }
    ) {
        self.makeClaudeCodeStore = makeClaudeCodeStore
        let credentialCoordinator = GitHubCredentialCoordinator(tokenStore: githubTokenStore)
        _githubAuthorizationStore = State(initialValue: GitHubAuthorizationStore(
            tokenStore: githubTokenStore,
            credentialCoordinator: credentialCoordinator
        ))
        _agentPRMonitorStore = State(initialValue: FeatureFlag.agentPRMonitor.isEnabled
            ? AgentPRMonitorStore(
                tokenStore: githubTokenStore,
                credentialCoordinator: credentialCoordinator
            )
            : nil)
        _pullRequestReviewDeskStore = State(initialValue: SidebarScope.pullRequestReviewDesk.isEnabled
            ? PullRequestReviewDeskStore(credentialCoordinator: credentialCoordinator)
            : nil)
        _githubProjectsStore = State(initialValue: SidebarScope.githubProjects.isEnabled
            ? GitHubProjectsStore(credentialCoordinator: credentialCoordinator)
            : nil)
    }

    /// Main app navigation and detail content.
    var body: some View {
        NavigationSplitView {
            AnyView(List(selection: $scope) {
                if SidebarScope.attentionQueue.isEnabled, let agentPRMonitorStore {
                    sidebarSection(.focus) {
                        Text("Focus")
                    } content: {
                        Label("Attention Queue", systemImage: "scope")
                            .badge(attentionQueueBadgeCount(for: agentPRMonitorStore))
                            .tag(SidebarScope.attentionQueue)
                    }
                    .onAppear {
                        if agentPRMonitorStore.state == .idle,
                           !agentPRMonitorStore.watchedRepositories.isEmpty {
                            agentPRMonitorStore.refresh()
                        }
                    }
                }
                sidebarSection(.environment) {
                    Text("Environment")
                } content: {
                    Label("All Variables", systemImage: "list.bullet")
                        .tag(SidebarScope.all)
                    ForEach(ShellConfigFile.allCases) { file in
                        sidebarCountLabel(
                            Label(file.rawValue, systemImage: "doc.text")
                                .foregroundStyle(store.existingFiles.contains(file) ? .primary : .secondary),
                            state: .shell(
                                count: store.variables(in: file).count,
                                accessState: store.accessState(for: file)
                            )
                        )
                            .tag(SidebarScope.file(file))
                    }
                }
                if AITool.allCases.contains(where: { $0.featureFlag.isEnabled }) {
                    sidebarSection(.agentTools) {
                        Text("AI Tools")
                    } content: {
                        ForEach(AITool.allCases.filter { $0.featureFlag.isEnabled }) { tool in
                            aiToolSidebarLabel(tool)
                            .tag(SidebarScope.aiTool(tool))
                        }
                    }
                }
                if FeatureFlag.mcpAuthManager.isEnabled || agentDoctorStore != nil
                    || mcpServerInventoryStore != nil || capabilityHygieneStore != nil {
                    sidebarSection(.healthSecurity) {
                        Text("Health & Security")
                    } content: {
                        if FeatureFlag.mcpAuthManager.isEnabled {
                            sidebarCountLabel(
                                Label {
                                    Text(verbatim: "MCP Auth")
                                } icon: {
                                    Image(systemName: "key.radiowaves.forward")
                                }
                                .foregroundStyle(mcpAuthStore.rootExists ? .primary : .secondary),
                                state: .mcpCredentials(
                                    count: mcpAuthStore.entries.count,
                                    rootExists: mcpAuthStore.rootExists,
                                    hasScanRefusals: !mcpAuthStore.scanRefusals.isEmpty
                                )
                            )
                            .tag(SidebarScope.mcpAuth)
                        }
                        if let agentDoctorStore {
                            Label("Agent Doctor", systemImage: "stethoscope")
                                .badge(agentDoctorStore.problemCount)
                                .tag(SidebarScope.agentDoctor)
                        }
                        if let capabilityHygieneStore {
                            Label("Capabilities", systemImage: "wrench.and.screwdriver")
                                .badge(capabilityHygieneStore.findingCount)
                                .tag(SidebarScope.capabilityHygiene)
                        } else if let mcpServerInventoryStore {
                            Label("MCP Inventory", systemImage: "server.rack")
                                .badge(mcpServerInventoryStore.count)
                                .tag(SidebarScope.mcpServerInventory)
                        }
                    }
                    .onAppear {
                        agentDoctorStore?.reload()
                        mcpServerInventoryStore?.reload()
                        if capabilityHygieneStore?.phase == .idle {
                            capabilityHygieneStore?.reload()
                        }
                    }
                }
                if agentContextInspectorStore != nil || repoReadinessStore != nil
                    || agentPRMonitorStore != nil || pullRequestReviewDeskStore != nil
                    || githubProjectsStore != nil {
                    sidebarSection(.repositories) {
                        Text("Repositories")
                    } content: {
                        if let agentContextInspectorStore {
                            Label("Agent Context", systemImage: "text.book.closed")
                                .badge(agentContextInspectorStore.problemCount)
                                .tag(SidebarScope.agentContextInspector)
                        }
                        if let repoReadinessStore {
                            Label("Repo Readiness", systemImage: "checklist")
                                .badge(repoReadinessStore.problemCount)
                                .tag(SidebarScope.repoReadinessChecklist)
                        }
                        if let agentPRMonitorStore {
                            Label("Agent PR Monitor", systemImage: "arrow.triangle.pull")
                                .badge(agentPRMonitorStore.attentionCount)
                                .tag(SidebarScope.agentPRMonitor)
                        }
                        if SidebarScope.pullRequestReviewDesk.isEnabled,
                           pullRequestReviewDeskStore != nil {
                            Label("Review Desk", systemImage: "text.bubble")
                                .tag(SidebarScope.pullRequestReviewDesk)
                        }
                        if githubProjectsStore != nil {
                            githubProjectsSidebarDestination
                        }
                    }
                    .onAppear {
                        agentContextInspectorStore?.reload()
                        repoReadinessStore?.reload()
                        if agentPRMonitorStore?.selectedRepository != nil {
                            agentPRMonitorStore?.refresh()
                        }
                    }
                }
                if backupBrowserStore != nil || packageMaintenanceStore != nil {
                    sidebarSection(.maintenance) {
                        Text("Maintenance")
                    } content: {
                        if let packageMaintenanceStore {
                            Label("Software Updates", systemImage: "arrow.triangle.2.circlepath")
                                .badge(packageMaintenanceStore.updateCount)
                                .tag(SidebarScope.packageMaintenance)
                        }
                        if let backupBrowserStore {
                            sidebarCountLabel(
                                Label("Backups", systemImage: "clock.arrow.circlepath"),
                                state: .backups(
                                    count: backupBrowserStore.count,
                                    phase: backupSidebarLoadPhase,
                                    hasDiscoveryError: backupBrowserStore.discoveryError != nil
                                )
                            )
                                .tag(SidebarScope.backupBrowser)
                        }
                    }
                    .onAppear {
                        reloadBackupBrowser()
                        if packageMaintenanceStore?.state == .idle {
                            packageMaintenanceStore?.reload()
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210))
        } detail: {
            detailView(for: scope)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                githubAuthorizationStore: githubAuthorizationStore,
                initialPane: requestedSettingsPane
            ) { change in
                agentPRMonitorStore?.handleGitHubAuthorizationChange(change)
                pullRequestReviewDeskStore?.refresh()
                githubProjectsStore?.handleGitHubAuthorizationChange(change)
            }
        }
        .onChange(of: menuActions.settingsRequested, initial: true) {
            if menuActions.settingsRequested {
                requestedSettingsPane = .general
                showSettings = true
                menuActions.settingsRequested = false
            }
        }
        .onChange(of: menuActions.lockSecretsRequest) {
            secrets.lock()
        }
        .onAppear {
            scope = SidebarSelectionState.restoredScope(storageValue: storedSidebarScope)
        }
        .onChange(of: scope) {
            if let scope, scope.isEnabled {
                storedSidebarScope = scope.storageID
            }
            if scope == .aiTool(.claudeCode) {
                loadClaudeCodeStoreIfNeeded()
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
        .alert(
            "Authentication Failed",
            isPresented: Binding(
                get: { secrets.lastError != nil },
                set: { if !$0 { secrets.clearError() } }
            )
        ) {
            Button("OK", role: .cancel) { secrets.clearError() }
        } message: {
            Text(secrets.lastError ?? "")
        }
    }

    /// Uses the queue's complete freshness-aware policy so navigation and table urgency stay aligned.
    private func attentionQueueBadgeCount(for store: AgentPRMonitorStore) -> Int {
        let freshnessByRepository = Dictionary(
            uniqueKeysWithValues: store.watchedRepositories.map { repository in
                let state = store.repositoryRefreshStates[repository] ?? store.state
                return (repository, AgentPRMonitorView.guidanceFreshness(for: state))
            }
        )
        return PRAttentionQueueBuilder.snapshot(
            rows: store.rows,
            repositories: store.watchedRepositories,
            freshnessByRepository: freshnessByRepository,
            defaultFreshness: AgentPRMonitorView.guidanceFreshness(for: store.state)
        ).actNowCount
    }

    /// Type-erased sidebar destination keeps the large root list tractable for Swift's type checker.
    private var githubProjectsSidebarDestination: some View {
        Label("Projects", systemImage: "rectangle.3.group")
            .tag(SidebarScope.githubProjects)
    }

    /// Type-erased destination router keeps each large feature view outside the root generic type.
    private func detailView(for scope: SidebarScope?) -> AnyView {
        switch scope {
        case .attentionQueue:
            guard let agentPRMonitorStore else { return fallbackDetail }
            return AnyView(PRAttentionQueueView(
                store: agentPRMonitorStore,
                openSettings: {
                    requestedSettingsPane = .security
                    showSettings = true
                },
                showPRMonitor: { self.scope = .agentPRMonitor }
            ))
        case .mcpAuth:
            return AnyView(MCPAuthListView(store: mcpAuthStore, secrets: secrets))
        case .agentDoctor:
            guard let agentDoctorStore else { return fallbackDetail }
            return AnyView(AgentDoctorView(store: agentDoctorStore) { tool in
                self.scope = SidebarScope.followUpScope(for: tool)
            })
        case .agentContextInspector:
            guard let agentContextInspectorStore else { return fallbackDetail }
            return AnyView(AgentContextInspectorView(store: agentContextInspectorStore))
        case .repoReadinessChecklist:
            guard let repoReadinessStore else { return fallbackDetail }
            return AnyView(RepoReadinessView(store: repoReadinessStore))
        case .mcpServerInventory:
            guard let mcpServerInventoryStore else { return fallbackDetail }
            return AnyView(MCPServerInventoryView(store: mcpServerInventoryStore) { tool in
                self.scope = .aiTool(tool)
            })
        case .capabilityHygiene:
            guard let capabilityHygieneStore else { return fallbackDetail }
            return AnyView(CapabilityHygieneView(store: capabilityHygieneStore))
        case .agentPRMonitor:
            guard let agentPRMonitorStore else { return fallbackDetail }
            return AnyView(AgentPRMonitorView(store: agentPRMonitorStore) {
                requestedSettingsPane = .security
                showSettings = true
            })
        case .pullRequestReviewDesk:
            guard let agentPRMonitorStore, let pullRequestReviewDeskStore else { return fallbackDetail }
            return AnyView(PullRequestReviewDeskView(
                monitorStore: agentPRMonitorStore,
                store: pullRequestReviewDeskStore
            ) {
                requestedSettingsPane = .security
                showSettings = true
            })
        case .githubProjects:
            return AnyView(githubProjectsDetail)
        case .backupBrowser:
            guard let backupBrowserStore else { return fallbackDetail }
            return AnyView(BackupBrowserView(store: backupBrowserStore))
        case .packageMaintenance:
            guard let packageMaintenanceStore else { return fallbackDetail }
            return AnyView(PackageMaintenanceView(store: packageMaintenanceStore) {
                requestedSettingsPane = .maintenance
                showSettings = true
            })
        case .aiTool(.codex):
            return AnyView(CodexView(store: codexStore, secrets: secrets))
        case .aiTool(.claudeCode):
            guard let claudeCodeStore else {
                return AnyView(ProgressView("Loading Claude Code configuration...")
                    .controlSize(.small)
                    .accessibilityLabel("Loading Claude Code configuration...")
                    .onAppear(perform: loadClaudeCodeStoreIfNeeded))
            }
            return AnyView(ClaudeCodeView(store: claudeCodeStore, secrets: secrets))
        case .aiTool(.cursor):
            return AnyView(CursorView(store: cursorStore, secrets: secrets))
        case .aiTool(.craftAgents):
            return AnyView(CraftAgentView(store: craftStore))
        default:
            return fallbackDetail
        }
    }

    /// Stable environment-variable fallback for unavailable destinations.
    private var fallbackDetail: AnyView {
        AnyView(VariableListView(store: store, secrets: secrets, scope: scope ?? .all))
    }

    /// Isolated Project destination avoids expanding its complete workspace into the root switch type.
    @ViewBuilder
    private var githubProjectsDetail: some View {
        if let githubProjectsStore {
            GitHubProjectsView(store: githubProjectsStore) {
                requestedSettingsPane = .security
                showSettings = true
            }
        } else {
            VariableListView(store: store, secrets: secrets, scope: .all)
        }
    }

    /// Wraps a sidebar group in native collapsible sections when the feature is enabled.
    @ViewBuilder
    private func sidebarSection<Header: View, Content: View>(
        _ section: SidebarSectionID,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if FeatureFlag.collapsibleSidebarSections.isEnabled {
            Section(isExpanded: sidebarExpansionBinding(for: section), content: content, header: header)
        } else {
            Section(content: content, header: header)
        }
    }

    /// Binding that bridges persisted collapsed section IDs to SwiftUI's expanded state.
    private func sidebarExpansionBinding(for section: SidebarSectionID) -> Binding<Bool> {
        Binding {
            SidebarSectionExpansionState(storageValue: collapsedSidebarSections)
                .isExpanded(section)
        } set: { isExpanded in
            var state = SidebarSectionExpansionState(storageValue: collapsedSidebarSections)
            state.setExpanded(isExpanded, for: section)
            collapsedSidebarSections = state.storageValue
        }
    }

    /// Returns whether a tool has local configuration available.
    private func toolExists(_ tool: AITool) -> Bool {
        switch tool {
        case .codex: return codexStore.directoryExists
        case .claudeCode:
            if case .available = claudeCodeStore?.sidebarState { return true }
            return false
        case .cursor: return cursorStore.directoryExists
        case .craftAgents: return craftStore.directoryExists
        }
    }

    /// Count shown in the sidebar badge for one AI tool.
    private func toolBadgeCount(_ tool: AITool) -> Int {
        switch tool {
        case .codex: return codexStore.variables.count
        case .claudeCode:
            if case .available(let count) = claudeCodeStore?.sidebarState { return count }
            return 0
        case .cursor: return cursorStore.envEntries.count
        case .craftAgents: return craftStore.secretFiles.count + (craftStore.encryptedStore != nil ? 1 : 0)
        }
    }

    /// Keeps Claude neutral before discovery instead of implying a missing configuration or zero count.
    @ViewBuilder
    private func aiToolSidebarLabel(_ tool: AITool) -> some View {
        if tool == .claudeCode {
            let sourceState = claudeCodeStore?.sidebarState ?? .neutral
            sidebarCountLabel(
                toolLabel(tool)
                    .foregroundStyle(sourceState == .missing ? .secondary : .primary),
                state: .claudeCode(sourceState)
            )
        } else if tool == .cursor {
            sidebarCountLabel(
                toolLabel(tool)
                    .foregroundStyle(cursorStore.loadState == .missing ? .secondary : .primary),
                state: .cursor(
                    count: cursorStore.envEntries.count,
                    loadState: cursorStore.loadState
                )
            )
        } else {
            toolLabel(tool)
                .foregroundStyle(toolExists(tool) ? .primary : .secondary)
                .badge(toolBadgeCount(tool))
        }
    }

    /// Shared icon-and-title label for one AI tool destination.
    private func toolLabel(_ tool: AITool) -> some View {
        Label {
            Text(verbatim: tool.displayName)
        } icon: {
            Image(systemName: tool.systemImage)
        }
    }

    /// Applies a native progress indicator or exact numeric badge without inventing count data.
    @ViewBuilder
    private func sidebarCountLabel<LabelContent: View>(
        _ label: LabelContent,
        state: SidebarCountState
    ) -> some View {
        switch state {
        case .neutral:
            label
        case .loading:
            HStack(spacing: 8) {
                label
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
        case .available(let count):
            label.badge(Text(count, format: .number))
        case .refused:
            HStack(spacing: 8) {
                label
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Access blocked")
            }
        }
    }

    /// Runs the synchronous bounded backup scan with explicit sidebar lifecycle state.
    private func reloadBackupBrowser() {
        guard let backupBrowserStore else { return }
        backupSidebarLoadPhase = .loading
        backupBrowserStore.reload()
        backupSidebarLoadPhase = .loaded
    }

    /// Materializes Claude configuration state only after the user navigates there.
    private func loadClaudeCodeStoreIfNeeded() {
        guard claudeCodeStore == nil else { return }
        claudeCodeStore = makeClaudeCodeStore()
    }
}

#Preview {
    ContentView()
        .environment(MenuActions())
}
