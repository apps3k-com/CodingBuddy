//
//  SidebarNavigationState.swift
//  CodingBuddy
//

import Foundation

/// Navigation destinations shown in the app sidebar.
nonisolated enum SidebarScope: Hashable, Sendable {
    /// Explainable cross-repository queue for the next useful PR action.
    case attentionQueue
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
    /// Unified inventory and hygiene findings for local agent capabilities.
    case capabilityHygiene
    /// GitHub pull request monitor for agent follow-up.
    case agentPRMonitor
    /// Focused GitHub pull request conversation, checks, and action workbench.
    case pullRequestReviewDesk
    /// GitHub Projects table, board, and planning drift workbench.
    case githubProjects
    /// Local backup browser.
    case backupBrowser
    /// Global package inventory and controlled updates.
    case packageMaintenance
    /// Configuration for one supported AI coding tool.
    case aiTool(AITool)

    /// Stable identifier persisted between app launches.
    var storageID: String {
        switch self {
        case .attentionQueue: "attentionQueue"
        case .all: "all"
        case .file(let file): "file:\(file.rawValue)"
        case .mcpAuth: "mcpAuth"
        case .agentDoctor: "agentDoctor"
        case .agentContextInspector: "agentContextInspector"
        case .repoReadinessChecklist: "repoReadinessChecklist"
        case .mcpServerInventory: "mcpServerInventory"
        case .capabilityHygiene: "capabilityHygiene"
        case .agentPRMonitor: "agentPRMonitor"
        case .pullRequestReviewDesk: "pullRequestReviewDesk"
        case .githubProjects: "githubProjects"
        case .backupBrowser: "backupBrowser"
        case .packageMaintenance: "packageMaintenance"
        case .aiTool(let tool): "aiTool:\(tool.rawValue)"
        }
    }

    /// Restores a destination from its persisted identifier.
    init?(storageID: String) {
        if storageID.hasPrefix("file:"),
           let file = ShellConfigFile(rawValue: String(storageID.dropFirst("file:".count))) {
            self = .file(file)
            return
        }
        if storageID.hasPrefix("aiTool:"),
           let tool = AITool(rawValue: String(storageID.dropFirst("aiTool:".count))) {
            self = .aiTool(tool)
            return
        }
        switch storageID {
        case "attentionQueue": self = .attentionQueue
        case "all": self = .all
        case "mcpAuth": self = .mcpAuth
        case "agentDoctor": self = .agentDoctor
        case "agentContextInspector": self = .agentContextInspector
        case "repoReadinessChecklist": self = .repoReadinessChecklist
        case "mcpServerInventory": self = .mcpServerInventory
        case "capabilityHygiene": self = .capabilityHygiene
        case "agentPRMonitor": self = .agentPRMonitor
        case "pullRequestReviewDesk": self = .pullRequestReviewDesk
        case "githubProjects": self = .githubProjects
        case "backupBrowser": self = .backupBrowser
        case "packageMaintenance": self = .packageMaintenance
        default: return nil
        }
    }

    /// Whether the destination is enabled in the current release channel.
    var isEnabled: Bool {
        switch self {
        case .attentionQueue:
            FeatureFlag.attentionCockpit.isEnabled
                && FeatureFlag.agentPRMonitor.isEnabled
                && FeatureFlag.explainableGuidance.isEnabled
        case .all, .file:
            true
        case .mcpAuth:
            FeatureFlag.mcpAuthManager.isEnabled
        case .agentDoctor:
            FeatureFlag.agentDoctor.isEnabled
        case .agentContextInspector:
            FeatureFlag.agentContextInspector.isEnabled
        case .repoReadinessChecklist:
            FeatureFlag.repoReadinessChecklist.isEnabled
        case .mcpServerInventory:
            FeatureFlag.mcpServerInventory.isEnabled && !FeatureFlag.capabilityHygiene.isEnabled
        case .capabilityHygiene:
            FeatureFlag.capabilityHygiene.isEnabled
        case .agentPRMonitor:
            FeatureFlag.agentPRMonitor.isEnabled
        case .pullRequestReviewDesk:
            FeatureFlag.pullRequestReviewDesk.isEnabled
                && FeatureFlag.agentPRMonitor.isEnabled
        case .githubProjects:
            FeatureFlag.githubProjectsBoard.isEnabled
        case .backupBrowser:
            FeatureFlag.backupBrowser.isEnabled
        case .packageMaintenance:
            FeatureFlag.packageMaintenance.isEnabled
        case .aiTool(let tool):
            tool.featureFlag.isEnabled
        }
    }

    /// Dotfile represented by this scope when it is file-backed.
    var file: ShellConfigFile? {
        if case .file(let file) = self { return file }
        return nil
    }

    /// Localized sidebar title for the scope.
    var title: String {
        switch self {
        case .attentionQueue: String(localized: "Attention Queue")
        case .all: String(localized: "All Variables")
        case .file(let file): file.rawValue
        case .mcpAuth: "MCP Auth"
        case .agentDoctor: String(localized: "Agent Doctor")
        case .agentContextInspector: String(localized: "Agent Context")
        case .repoReadinessChecklist: String(localized: "Repo Readiness")
        case .mcpServerInventory: String(localized: "MCP Inventory")
        case .capabilityHygiene: String(localized: "Capability Hygiene")
        case .agentPRMonitor: String(localized: "Agent PR Monitor")
        case .pullRequestReviewDesk: String(localized: "Review Desk")
        case .githubProjects: String(localized: "Projects")
        case .backupBrowser: String(localized: "Backups")
        case .packageMaintenance: String(localized: "Software Updates")
        case .aiTool(let tool): tool.displayName
        }
    }

    /// Existing destination that can resolve one Agent Doctor finding.
    static func followUpScope(for tool: AgentDiagnosticTool) -> SidebarScope {
        switch tool {
        case .zsh:
            .all
        case .codex:
            .aiTool(.codex)
        case .claudeCode:
            .aiTool(.claudeCode)
        case .cursor:
            .aiTool(.cursor)
        case .craftAgents:
            .aiTool(.craftAgents)
        case .mcpAuth:
            .mcpAuth
        }
    }
}

/// Restores a safe sidebar destination from persisted app state.
nonisolated enum SidebarSelectionState {
    /// UserDefaults key used by the root navigation view.
    static let storageKey = "sidebar.selectedScope"

    /// Returns the stored enabled destination, or the stable all-variables fallback.
    static func restoredScope(storageValue: String) -> SidebarScope {
        if storageValue == SidebarScope.mcpServerInventory.storageID,
           FeatureFlag.capabilityHygiene.isEnabled {
            return .capabilityHygiene
        }
        guard let scope = SidebarScope(storageID: storageValue), scope.isEnabled else {
            return .all
        }
        return scope
    }
}
