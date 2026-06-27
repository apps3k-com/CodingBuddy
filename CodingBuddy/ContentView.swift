//
//  ContentView.swift
//  CodingBuddy
//

import SwiftUI

enum SidebarScope: Hashable {
    case all
    case file(ShellConfigFile)
    case mcpAuth
    case agentDoctor
    case mcpServerInventory
    case aiTool(AITool)

    var file: ShellConfigFile? {
        if case .file(let file) = self { return file }
        return nil
    }

    var title: String {
        switch self {
        case .all: String(localized: "All Variables")
        case .file(let file): file.rawValue
        case .mcpAuth: "MCP Auth"
        case .agentDoctor: String(localized: "Agent Doctor")
        case .mcpServerInventory: String(localized: "MCP Inventory")
        case .aiTool(let tool): tool.displayName
        }
    }
}

struct ContentView: View {
    @Environment(MenuActions.self) private var menuActions
    @State private var store = EnvStore()
    @State private var mcpAuthStore = MCPAuthStore()
    @State private var codexStore = CodexStore()
    @State private var claudeCodeStore = ClaudeCodeStore()
    @State private var cursorStore = CursorStore()
    @State private var craftStore = CraftAgentStore()
    @State private var agentDoctorStore: AgentDoctorStore? = FeatureFlag.agentDoctor.isEnabled ? AgentDoctorStore() : nil
    @State private var mcpServerInventoryStore: MCPServerInventoryStore? =
        FeatureFlag.mcpServerInventory.isEnabled ? MCPServerInventoryStore() : nil
    @State private var secrets = SecretsGuard()
    @State private var scope: SidebarScope? = .all
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $scope) {
                Label("All Variables", systemImage: "list.bullet")
                    .tag(SidebarScope.all)
                Section("Files") {
                    ForEach(ShellConfigFile.allCases) { file in
                        Label(file.rawValue, systemImage: "doc.text")
                            .foregroundStyle(store.existingFiles.contains(file) ? .primary : .secondary)
                            .badge(store.variables(in: file).count)
                            .tag(SidebarScope.file(file))
                    }
                }
                if AITool.allCases.contains(where: { $0.featureFlag.isEnabled }) {
                    Section("AI Tools") {
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
                    Section("Credentials") {
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
                    Section("Health") {
                        Label("Agent Doctor", systemImage: "stethoscope")
                            .badge(agentDoctorStore.problemCount)
                            .tag(SidebarScope.agentDoctor)
                    }
                    .onAppear {
                        agentDoctorStore.reload()
                    }
                }
                if let mcpServerInventoryStore {
                    Section("Inventory") {
                        Label("MCP Inventory", systemImage: "server.rack")
                            .badge(mcpServerInventoryStore.count)
                            .tag(SidebarScope.mcpServerInventory)
                    }
                    .onAppear {
                        mcpServerInventoryStore.reload()
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
            case .mcpServerInventory:
                if let mcpServerInventoryStore {
                    MCPServerInventoryView(store: mcpServerInventoryStore) { tool in
                        scope = .aiTool(tool)
                    }
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
            SettingsView()
        }
        .onChange(of: menuActions.settingsRequested, initial: true) {
            if menuActions.settingsRequested {
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

    private func toolExists(_ tool: AITool) -> Bool {
        switch tool {
        case .codex: codexStore.directoryExists
        case .claudeCode: claudeCodeStore.directoryExists
        case .cursor: cursorStore.directoryExists
        case .craftAgents: craftStore.directoryExists
        }
    }

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
