//
//  ContentView.swift
//  CodingBuddy
//

import SwiftUI

/// Navigation destinations shown in the app sidebar.
enum SidebarScope: Hashable {
    /// Environment variables across all managed dotfiles.
    case all
    /// Environment variables from one managed dotfile.
    case file(ShellConfigFile)
    /// Local MCP authentication entries.
    case mcpAuth
    /// Agent setup diagnostics.
    case agentDoctor
    /// Agent governance and context inspection.
    case agentContextInspector
    /// Repository readiness checklist.
    case repoReadinessChecklist
    /// Cross-tool MCP server inventory.
    case mcpServerInventory
    /// GitHub pull request monitor for agent follow-up.
    case agentPRMonitor
    /// Local backup browser.
    case backupBrowser
    /// Configuration for one supported AI coding tool.
    case aiTool(AITool)

    /// Dotfile represented by this scope when it is file-backed.
    var file: ShellConfigFile? {
        if case .file(let file) = self { return file }
        return nil
    }

    /// Localized sidebar title for the scope.
    var title: String {
        switch self {
        case .all: String(localized: "All Variables")
        case .file(let file): file.rawValue
        case .mcpAuth: "MCP Auth"
        case .agentDoctor: String(localized: "Agent Doctor")
        case .agentContextInspector: String(localized: "Agent Context")
        case .repoReadinessChecklist: String(localized: "Repo Readiness")
        case .mcpServerInventory: String(localized: "MCP Inventory")
        case .agentPRMonitor: String(localized: "Agent PR Monitor")
        case .backupBrowser: String(localized: "Backups")
        case .aiTool(let tool): tool.displayName
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
    /// Claude Code configuration store.
    @State private var claudeCodeStore = ClaudeCodeStore()
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
        FeatureFlag.mcpServerInventory.isEnabled ? MCPServerInventoryStore() : nil
    /// GitHub authorization state shared between Settings and Agent PR Monitor.
    @State private var githubAuthorizationStore: GitHubAuthorizationStore
    /// Agent PR Monitor store when the feature flag is enabled.
    @State private var agentPRMonitorStore: AgentPRMonitorStore?
    /// Backup Browser store when the feature flag is enabled.
    @State private var backupBrowserStore: BackupBrowserStore? =
        FeatureFlag.backupBrowser.isEnabled ? BackupBrowserStore() : nil
    /// Secret masking state shared across editors.
    @State private var secrets = SecretsGuard()
    /// Current sidebar selection.
    @State private var scope: SidebarScope? = .all
    /// Persisted collapsed top-level sidebar groups.
    @AppStorage("sidebar.collapsedSections") private var collapsedSidebarSections = ""
    /// Whether the settings sheet is visible.
    @State private var showSettings = false
    /// Settings pane requested by the action that opened Settings.
    @State private var requestedSettingsPane = SettingsInitialPane.general

    /// Creates root-owned stores and shares GitHub token persistence.
    init(githubTokenStore: any GitHubTokenStore = KeychainGitHubTokenStore()) {
        _githubAuthorizationStore = State(initialValue: GitHubAuthorizationStore(tokenStore: githubTokenStore))
        _agentPRMonitorStore = State(initialValue: FeatureFlag.agentPRMonitor.isEnabled
            ? AgentPRMonitorStore(tokenStore: githubTokenStore)
            : nil)
    }

    /// Main app navigation and detail content.
    var body: some View {
        NavigationSplitView {
            List(selection: $scope) {
                Label("All Variables", systemImage: "list.bullet")
                    .tag(SidebarScope.all)
                sidebarSection(.files) {
                    Text("Files")
                } content: {
                    ForEach(ShellConfigFile.allCases) { file in
                        Label(file.rawValue, systemImage: "doc.text")
                            .foregroundStyle(store.existingFiles.contains(file) ? .primary : .secondary)
                            .badge(store.variables(in: file).count)
                            .tag(SidebarScope.file(file))
                    }
                }
                if AITool.allCases.contains(where: { $0.featureFlag.isEnabled }) {
                    sidebarSection(.aiTools) {
                        Text("AI Tools")
                    } content: {
                        ForEach(AITool.allCases.filter { $0.featureFlag.isEnabled }) { tool in
                            Label {
                                Text(verbatim: tool.displayName)
                            } icon: {
                                Image(systemName: tool.systemImage)
                            }
                            .foregroundStyle(toolExists(tool) ? .primary : .secondary)
                            .badge(toolBadgeCount(tool))
                            .tag(SidebarScope.aiTool(tool))
                        }
                    }
                }
                if FeatureFlag.mcpAuthManager.isEnabled {
                    sidebarSection(.credentials) {
                        Text("Credentials")
                    } content: {
                        Label {
                            Text(verbatim: "MCP Auth")
                        } icon: {
                            Image(systemName: "key.radiowaves.forward")
                        }
                        .foregroundStyle(mcpAuthStore.rootExists ? .primary : .secondary)
                        .badge(mcpAuthStore.entries.count)
                        .tag(SidebarScope.mcpAuth)
                    }
                }
                if let agentDoctorStore {
                    sidebarSection(.health) {
                        Text("Health")
                    } content: {
                        Label("Agent Doctor", systemImage: "stethoscope")
                            .badge(agentDoctorStore.problemCount)
                            .tag(SidebarScope.agentDoctor)
                    }
                    .onAppear {
                        agentDoctorStore.reload()
                    }
                }
                if agentContextInspectorStore != nil || repoReadinessStore != nil
                    || mcpServerInventoryStore != nil || agentPRMonitorStore != nil {
                    sidebarSection(.inventory) {
                        Text("Inventory")
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
                        if let mcpServerInventoryStore {
                            Label("MCP Inventory", systemImage: "server.rack")
                                .badge(mcpServerInventoryStore.count)
                                .tag(SidebarScope.mcpServerInventory)
                        }
                        if let agentPRMonitorStore {
                            Label("Agent PR Monitor", systemImage: "arrow.triangle.pull")
                                .badge(agentPRMonitorStore.attentionCount)
                                .tag(SidebarScope.agentPRMonitor)
                        }
                    }
                    .onAppear {
                        agentContextInspectorStore?.reload()
                        repoReadinessStore?.reload()
                        mcpServerInventoryStore?.reload()
                        if agentPRMonitorStore?.selectedRepository != nil {
                            agentPRMonitorStore?.refresh()
                        }
                    }
                }
                if let backupBrowserStore {
                    sidebarSection(.safety) {
                        Text("Safety")
                    } content: {
                        Label("Backups", systemImage: "clock.arrow.circlepath")
                            .badge(backupBrowserStore.count)
                            .tag(SidebarScope.backupBrowser)
                    }
                    .onAppear {
                        backupBrowserStore.reload()
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            switch scope {
            case .mcpAuth:
                MCPAuthListView(store: mcpAuthStore, secrets: secrets)
            case .agentDoctor:
                if let agentDoctorStore {
                    AgentDoctorView(store: agentDoctorStore)
                } else {
                    VariableListView(store: store, secrets: secrets, scope: .all)
                }
            case .agentContextInspector:
                if let agentContextInspectorStore {
                    AgentContextInspectorView(store: agentContextInspectorStore)
                } else {
                    VariableListView(store: store, secrets: secrets, scope: .all)
                }
            case .repoReadinessChecklist:
                if let repoReadinessStore {
                    RepoReadinessView(store: repoReadinessStore)
                } else {
                    VariableListView(store: store, secrets: secrets, scope: .all)
                }
            case .mcpServerInventory:
                if let mcpServerInventoryStore {
                    MCPServerInventoryView(store: mcpServerInventoryStore) { tool in
                        scope = .aiTool(tool)
                    }
                } else {
                    VariableListView(store: store, secrets: secrets, scope: .all)
                }
            case .agentPRMonitor:
                if let agentPRMonitorStore {
                    AgentPRMonitorView(store: agentPRMonitorStore) {
                        requestedSettingsPane = .security
                        showSettings = true
                    }
                } else {
                    VariableListView(store: store, secrets: secrets, scope: .all)
                }
            case .backupBrowser:
                if let backupBrowserStore {
                    BackupBrowserView(store: backupBrowserStore)
                } else {
                    VariableListView(store: store, secrets: secrets, scope: .all)
                }
            case .aiTool(.codex):
                CodexView(store: codexStore, secrets: secrets)
            case .aiTool(.claudeCode):
                ClaudeCodeView(store: claudeCodeStore, secrets: secrets)
            case .aiTool(.cursor):
                CursorView(store: cursorStore, secrets: secrets)
            case .aiTool(.craftAgents):
                CraftAgentView(store: craftStore)
            default:
                VariableListView(store: store, secrets: secrets, scope: scope ?? .all)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                githubAuthorizationStore: githubAuthorizationStore,
                initialPane: requestedSettingsPane
            ) { change in
                agentPRMonitorStore?.handleGitHubAuthorizationChange(change)
            }
        }
        .onChange(of: menuActions.settingsRequested, initial: true) {
            if menuActions.settingsRequested {
                requestedSettingsPane = .general
                showSettings = true
                menuActions.settingsRequested = false
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
        case .codex: codexStore.directoryExists
        case .claudeCode: claudeCodeStore.directoryExists
        case .cursor: cursorStore.directoryExists
        case .craftAgents: craftStore.directoryExists
        }
    }

    /// Count shown in the sidebar badge for one AI tool.
    private func toolBadgeCount(_ tool: AITool) -> Int {
        switch tool {
        case .codex: codexStore.variables.count
        case .claudeCode: claudeCodeStore.envEntries.count
        case .cursor: cursorStore.envEntries.count
        case .craftAgents: craftStore.secretFiles.count + (craftStore.encryptedStore != nil ? 1 : 0)
        }
    }
}

#Preview {
    ContentView()
        .environment(MenuActions())
}
