//
//  SidebarSectionExpansionTests.swift
//  CodingBuddyTests
//

import Testing
@testable import CodingBuddy

/// Regression coverage for persisted sidebar group expansion state.
struct SidebarSectionExpansionTests {
    /// New users start with every top-level sidebar group expanded.
    @Test func defaultStateKeepsEverySidebarSectionExpanded() {
        let state = SidebarSectionExpansionState()

        for section in SidebarSectionID.allCases {
            #expect(state.isExpanded(section))
        }
        #expect(state.storageValue.isEmpty)
    }

    /// Collapsed sections round-trip through the compact AppStorage value.
    @Test func collapsedSectionsRoundTripThroughStorageValue() {
        var state = SidebarSectionExpansionState()

        state.setExpanded(false, for: .repositories)
        state.setExpanded(false, for: .maintenance)

        let restored = SidebarSectionExpansionState(storageValue: state.storageValue)

        #expect(restored.isExpanded(.environment))
        #expect(!restored.isExpanded(.repositories))
        #expect(!restored.isExpanded(.maintenance))
        #expect(restored.storageValue == "maintenance,repositories")
    }

    /// Unknown stored tokens are ignored so old preferences cannot break the sidebar.
    @Test func storedStateIgnoresUnknownSidebarSectionTokens() {
        let state = SidebarSectionExpansionState(storageValue: "repositories,unknown,maintenance")

        #expect(!state.isExpanded(.repositories))
        #expect(!state.isExpanded(.maintenance))
        #expect(state.storageValue == "maintenance,repositories")
    }

    /// Old group identifiers migrate to the new task-oriented sections.
    @Test func legacySectionIdentifiersMigrateToTaskGroups() {
        let state = SidebarSectionExpansionState(
            storageValue: "files,aiTools,credentials,inventory,safety"
        )

        #expect(!state.isExpanded(.environment))
        #expect(!state.isExpanded(.agentTools))
        #expect(!state.isExpanded(.healthSecurity))
        #expect(!state.isExpanded(.repositories))
        #expect(!state.isExpanded(.maintenance))
    }
}
