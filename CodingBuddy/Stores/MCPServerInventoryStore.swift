//
//  MCPServerInventoryStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Observable state for the read-only MCP Server Inventory.
@Observable
final class MCPServerInventoryStore {
    /// Home directory whose agent-tool configuration is inspected.
    let homeDirectory: URL

    /// Latest normalized MCP server rows in display order.
    private(set) var items: [MCPServerInventoryItem] = []

    /// Read-only scanner that produces inventory snapshots.
    @ObservationIgnored private let scanner: MCPServerInventoryScanner

    /// Current background reload, cancelled when a newer reload starts.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    /// Creates a store for one home directory without scanning it immediately.
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
        self.scanner = MCPServerInventoryScanner(homeDirectory: homeDirectory)
    }

    /// Cancels any pending background reload when the store is released.
    deinit {
        reloadTask?.cancel()
    }

    /// Number of configured MCP servers currently visible to the inventory.
    var count: Int {
        items.count
    }

    /// Re-runs all inventory checks and replaces the current snapshot.
    func reload() {
        reloadTask?.cancel()
        let scanner = scanner
        reloadTask = Task {
            let items = await Task.detached(priority: .userInitiated) {
                scanner.items()
            }.value
            guard !Task.isCancelled else { return }
            self.items = items
        }
    }
}
