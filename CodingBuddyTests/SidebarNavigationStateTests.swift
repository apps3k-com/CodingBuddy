//
//  SidebarNavigationStateTests.swift
//  CodingBuddyTests
//

import Testing
@testable import CodingBuddy

/// Regression coverage for stable sidebar destination persistence.
struct SidebarNavigationStateTests {
    /// Every destination with associated data round-trips through its stable identifier.
    @Test func scopesRoundTripThroughStorageIdentifiers() {
        let scopes: [SidebarScope] = [
            .all,
            .file(.zshrc),
            .mcpAuth,
            .agentDoctor,
            .agentContextInspector,
            .repoReadinessChecklist,
            .mcpServerInventory,
            .agentPRMonitor,
            .backupBrowser,
            .packageMaintenance,
            .aiTool(.codex),
            .aiTool(.claudeCode),
        ]

        for scope in scopes {
            #expect(SidebarScope(storageID: scope.storageID) == scope)
        }
    }

    /// Unknown or malformed stored values cannot leave navigation without a valid detail view.
    @Test func malformedStorageFallsBackToAllVariables() {
        #expect(SidebarSelectionState.restoredScope(storageValue: "") == .all)
        #expect(SidebarSelectionState.restoredScope(storageValue: "file:.bashrc") == .all)
        #expect(SidebarSelectionState.restoredScope(storageValue: "future-feature") == .all)
    }

    /// Doctor findings route to an existing editor instead of ending at diagnosis text.
    @Test func doctorToolsMapToFollowUpDestinations() {
        #expect(SidebarScope.followUpScope(for: .zsh) == .all)
        #expect(SidebarScope.followUpScope(for: .codex) == .aiTool(.codex))
        #expect(SidebarScope.followUpScope(for: .claudeCode) == .aiTool(.claudeCode))
        #expect(SidebarScope.followUpScope(for: .cursor) == .aiTool(.cursor))
        #expect(SidebarScope.followUpScope(for: .craftAgents) == .aiTool(.craftAgents))
        #expect(SidebarScope.followUpScope(for: .mcpAuth) == .mcpAuth)
    }
}
