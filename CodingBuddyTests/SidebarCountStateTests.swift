//
//  SidebarCountStateTests.swift
//  CodingBuddyTests
//

import Testing
@testable import CodingBuddy

/// Regression coverage for conservative sidebar count presentation.
struct SidebarCountStateTests {
    /// Missing and refused files must not inherit the parser's empty-array count.
    @Test func shellCountRequiresSuccessfullyLoadedFile() {
        #expect(SidebarCountState.shell(count: 3, accessState: .loaded) == .available(count: 3))
        #expect(SidebarCountState.shell(count: 0, accessState: .missing) == .neutral)
        #expect(SidebarCountState.shell(count: 0, accessState: .refused(.unreadable)) == .refused)
    }

    /// Missing roots are neutral while partial scans of existing roots are refused.
    @Test func credentialCountRequiresExistingRootAndCompleteScan() {
        #expect(SidebarCountState.mcpCredentials(
            count: 0,
            rootExists: false,
            hasScanRefusals: true
        ) == .neutral)
        #expect(SidebarCountState.mcpCredentials(
            count: 4,
            rootExists: true,
            hasScanRefusals: false
        ) == .available(count: 4))
        #expect(SidebarCountState.mcpCredentials(
            count: 2,
            rootExists: true,
            hasScanRefusals: true
        ) == .refused)
    }

    /// The backup badge remains absent before and during discovery and after refusal.
    @Test func backupCountTracksDiscoveryLifecycleAndRefusal() {
        #expect(SidebarCountState.backups(
            count: 0,
            phase: .neutral,
            hasDiscoveryError: false
        ) == .neutral)
        #expect(SidebarCountState.backups(
            count: 0,
            phase: .loading,
            hasDiscoveryError: false
        ) == .loading)
        #expect(SidebarCountState.backups(
            count: 5,
            phase: .loaded,
            hasDiscoveryError: false
        ) == .available(count: 5))
        #expect(SidebarCountState.backups(
            count: 0,
            phase: .loaded,
            hasDiscoveryError: true
        ) == .refused)
    }

    /// Cursor uses its authoritative load result, including a complete empty document.
    @Test func cursorCountUsesAuthoritativeLoadState() {
        #expect(SidebarCountState.cursor(count: 0, loadState: .missing) == .neutral)
        #expect(SidebarCountState.cursor(count: 0, loadState: .loaded) == .available(count: 0))
        #expect(SidebarCountState.cursor(count: 2, loadState: .loaded) == .available(count: 2))
        #expect(SidebarCountState.cursor(
            count: 0,
            loadState: .refused(.malformedJSON)
        ) == .refused)
    }

    /// Claude refusal must remain visibly distinct from a not-yet-loaded source.
    @Test func claudeCountPreservesRefusedState() {
        #expect(SidebarCountState.claudeCode(.neutral) == .neutral)
        #expect(SidebarCountState.claudeCode(.missing) == .neutral)
        #expect(SidebarCountState.claudeCode(.available(count: 3)) == .available(count: 3))
        #expect(SidebarCountState.claudeCode(.refused) == .refused)
    }

    /// Non-available states never expose a fallback zero or stale numeric count.
    @Test func onlyAvailableStateExposesNumericBadge() {
        #expect(SidebarCountState.neutral.badgeCount == nil)
        #expect(SidebarCountState.loading.badgeCount == nil)
        #expect(SidebarCountState.refused.badgeCount == nil)
        #expect(SidebarCountState.available(count: 7).badgeCount == 7)
    }
}
