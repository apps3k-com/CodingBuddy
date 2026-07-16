//
//  MCPAuthListView.swift
//  CodingBuddy
//

import AppKit
import SwiftUI

/// Lists the MCP servers found in ~/.mcp-auth with status, allows surgical
/// resets (to the Trash) and opens the credential file editor.
struct MCPAuthListView: View {
    /// Credential metadata store and owner of reversible reset operations.
    var store: MCPAuthStore
    /// Authentication gate required before credential files can be viewed.
    var secrets: SecretsGuard

    @State private var selection: MCPAuthEntry.ID?
    @State private var inspectedEntry: MCPAuthEntry?
    @State private var pendingReset: MCPAuthEntry?
    @State private var confirmResetAll = false

    var body: some View {
        Table(store.entries, selection: $selection) {
            TableColumn("Server") { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName)
                        .fontWeight(entry.serverURL != nil ? .medium : .regular)
                        .monospaced(entry.serverURL == nil)
                    if let scope = entry.scope {
                        Text(scope)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 220, ideal: 300)

            TableColumn("Status") { entry in
                TokenStatusBadge(status: entry.status)
            }
            .width(min: 120, ideal: 170)

            TableColumn("Version") { entry in
                Text(entry.versionDirectory)
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 130)

            TableColumn("Files") { entry in
                Text(LocalizedCountText.files(entry.files.count))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: MCPAuthEntry.ID.self) { ids in
            if let entry = entry(for: ids.first) {
                Button("View Files…") { inspectedEntry = entry }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(entry.files.map(\.url))
                }
                Divider()
                Button("Reset Entry…", role: .destructive) { pendingReset = entry }
                    .disabled(hasResetSafetyBlocker)
            }
        } primaryAction: { ids in
            if let entry = entry(for: ids.first) { inspectedEntry = entry }
        }
        .navigationTitle(Text(verbatim: "MCP Auth"))
        .navigationSubtitle(Text(LocalizedCountText.servers(store.entries.count)))
        .safeAreaInset(edge: .top, spacing: 0) {
            if hasScanSafetyWarning, !store.entries.isEmpty {
                scanSafetyBanner
                Divider()
            }
        }
        .focusedSceneValue(\.mcpAuthCommandActions, commandActions)
        .focusedValue(\.secretLockCommandAction, secrets.isUnlocked ? { secrets.lock() } : nil)
        .toolbar {
            ToolbarItem {
                Button("View Files…", systemImage: "doc.text.magnifyingglass") {
                    openSelectedEntry()
                }
                .disabled(selectedEntry == nil)
                .help("View the selected credential files")
            }
            ToolbarItem {
                Button(String(localized: "Lock All Revealed Secrets"), systemImage: "lock.fill") {
                    secrets.lock()
                }
                .disabled(!secrets.isUnlocked)
                .help(String(localized: "Immediately hide all revealed secrets throughout CodingBuddy"))
            }
            if let recoveryDirectory {
                ToolbarItem {
                    Menu("Credential Recovery Required", systemImage: "folder.badge.questionmark") {
                        Button("Show Recovery Files in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([recoveryDirectory])
                        }
                        Button("Copy Recovery Path") {
                            copyRecoveryPath(recoveryDirectory)
                        }
                        Divider()
                        Button("Check Recovery Status", systemImage: "arrow.clockwise") {
                            store.reload()
                        }
                    }
                    .help(String(localized: "Resolve the retained recovery files before resetting more credentials"))
                }
            }
            ToolbarItem {
                Button("Reset All…", systemImage: "trash", role: .destructive) {
                    confirmResetAll = true
                }
                .disabled(store.entries.isEmpty || hasResetSafetyBlocker)
                .help("Move all MCP credentials to the Trash")
            }
        }
        .sheet(item: $inspectedEntry) { entry in
            MCPAuthFileEditorView(store: store, secrets: secrets, entry: entry)
        }
        .confirmationDialog(
            "Move credentials for “\(pendingReset?.displayName ?? "")” to the Trash?",
            isPresented: Binding(
                get: { pendingReset != nil },
                set: { if !$0 { pendingReset = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move Server Credentials to Trash", role: .destructive) {
                if let entry = pendingReset { store.reset(entry) }
                pendingReset = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next connection will trigger a fresh OAuth login.")
        }
        .confirmationDialog(
            "Move all MCP credentials to the Trash?",
            isPresented: $confirmResetAll,
            titleVisibility: .visible
        ) {
            Button("Move All MCP Credentials to Trash", role: .destructive) {
                store.resetAll()
                confirmResetAll = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every connected server will ask you to log in again.")
        }
        .alert(
            recoveryDirectory == nil ? "Credential Operation Failed" : "Credential Recovery Required",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.clearError() } }
            )
        ) {
            if let recoveryDirectory {
                Button("Show Recovery Files in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([recoveryDirectory])
                    store.clearError()
                }
                Button("Copy Recovery Path") {
                    copyRecoveryPath(recoveryDirectory)
                    store.clearError()
                }
            }
            Button("OK", role: .cancel) { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
        .overlay {
            if hasScanSafetyWarning, store.entries.isEmpty {
                ContentUnavailableView {
                    Label("MCP Credentials Could Not Be Scanned Safely", systemImage: "exclamationmark.shield")
                } description: {
                    Text("CodingBuddy found an unsafe or unexpectedly large credential cache and deliberately did not read it.")
                } actions: {
                    Button("Try Again", systemImage: "arrow.clockwise") { store.reload() }
                    Button("Show in Finder", systemImage: "folder") { showCredentialCache() }
                }
            } else if !store.rootExists {
                ContentUnavailableView(
                    "No MCP credentials",
                    systemImage: "key.slash",
                    description: Text("Connect to a remote MCP server first. CodingBuddy will list cached OAuth credentials here after they exist.")
                )
            } else if store.entries.isEmpty {
                ContentUnavailableView(
                    "No MCP credentials",
                    systemImage: "key.slash",
                    description: Text("Connect to an MCP server that uses OAuth. Its cached credentials will appear here.")
                )
            }
        }
    }

    /// Compact warning retained above partial results when some input was refused.
    private var scanSafetyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Credential Scan Limited for Safety")
                    .fontWeight(.medium)
                Text("Some credential or recovery files were not read because their type, ownership, permissions, size, or directory count was unsafe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Try Again", systemImage: "arrow.clockwise") { store.reload() }
                .labelStyle(.iconOnly)
                .help("Try Again")
            Button("Show in Finder", systemImage: "folder") { showCredentialCache() }
                .labelStyle(.iconOnly)
                .help("Show in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }

    private func entry(for id: MCPAuthEntry.ID?) -> MCPAuthEntry? {
        store.entries.first { $0.id == id }
    }

    /// Entry currently selected for toolbar and menu commands.
    private var selectedEntry: MCPAuthEntry? {
        entry(for: selection)
    }

    /// Opens the selected entry without relying on a context menu or double-click.
    private func openSelectedEntry() {
        guard let selectedEntry else { return }
        inspectedEntry = selectedEntry
    }

    /// Menu-bar actions whose availability mirrors the visible toolbar state.
    private var commandActions: MCPAuthCommandActions {
        MCPAuthCommandActions(
            viewSelectedFiles: selectedEntry == nil ? nil : { openSelectedEntry() },
            showRecoveryFiles: recoveryDirectory.map { directory in
                { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
            },
            resetAllCredentials: store.entries.isEmpty || hasResetSafetyBlocker
                ? nil
                : { confirmResetAll = true }
        )
    }

    /// Copies a retained transaction path without dismissing persistent state.
    private func copyRecoveryPath(_ directory: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(directory.path, forType: .string)
    }

    /// Recovery location retained by a failed reset transaction, when present.
    private var recoveryDirectory: URL? {
        store.lastRecoveryDirectory
    }

    /// Whether the latest scan deliberately omitted any security-sensitive input.
    private var hasScanSafetyWarning: Bool {
        (store.rootExists && !store.scanRefusals.isEmpty)
            || store.recoveryDiscoveryRefusedAt != nil
    }

    /// Whether reset must remain unavailable until recovery discovery is safe
    /// or a retained transaction has been resolved.
    private var hasResetSafetyBlocker: Bool {
        recoveryDirectory != nil
            || store.recoveryDiscoveryRefusedAt != nil
            || store.hasIncompleteCredentialInventory
    }

    /// Reveals the cache root without exposing a refused child path in UI copy.
    private func showCredentialCache() {
        let location = store.recoveryDiscoveryRefusedAt ?? store.rootDirectory
        NSWorkspace.shared.activateFileViewerSelecting([location])
    }
}
