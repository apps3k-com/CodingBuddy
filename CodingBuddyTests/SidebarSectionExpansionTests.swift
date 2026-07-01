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

        state.setExpanded(false, for: .inventory)
        state.setExpanded(false, for: .safety)

        let restored = SidebarSectionExpansionState(storageValue: state.storageValue)

        #expect(restored.isExpanded(.files))
        #expect(!restored.isExpanded(.inventory))
        #expect(!restored.isExpanded(.safety))
        #expect(restored.storageValue == "inventory,safety")
    }

    /// Unknown stored tokens are ignored so old preferences cannot break the sidebar.
    @Test func storedStateIgnoresUnknownSidebarSectionTokens() {
        let state = SidebarSectionExpansionState(storageValue: "inventory,unknown,safety")

        #expect(!state.isExpanded(.inventory))
        #expect(!state.isExpanded(.safety))
        #expect(state.storageValue == "inventory,safety")
    }
}
