//
//  PackageMaintenanceView.swift
//  CodingBuddy
//

import AppKit
import SwiftUI

/// Global package inventory, confirmation, and sequential update surface.
struct PackageMaintenanceView: View {
    @Bindable var store: PackageMaintenanceStore
    var openSettings: () -> Void

    @State private var inspectedPackageID: InstalledPackage.ID?

    private var inspectedPackage: InstalledPackage? {
        inspectedPackageID.flatMap { id in store.packages.first { $0.id == id } }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding {
            store.pendingPlan != nil
        } set: { isPresented in
            if !isPresented { store.pendingPlan = nil }
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding {
            inspectedPackage != nil
        } set: { isPresented in
            if !isPresented {
                inspectedPackageID = nil
                store.clearReleaseNotes()
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.issues.isEmpty {
                ProviderIssueStrip(issues: store.issues, openSettings: openSettings)
                Divider()
            }

            Table(store.filteredPackages, selection: $store.selection) {
                TableColumn("Name") { package in
                    Text(verbatim: package.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                .width(min: 140, ideal: 190)

                TableColumn("Manager") { package in
                    Label(package.manager.displayName, systemImage: package.manager.systemImage)
                        .lineLimit(1)
                }
                .width(min: 90, ideal: 110, max: 130)

                TableColumn("Installed") { package in
                    Text(verbatim: package.installedVersion)
                        .monospaced()
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 95, max: 130)

                TableColumn("Available") { package in
                    Text(verbatim: package.targetVersion(for: store.updateMode) ?? "—")
                        .monospaced()
                        .lineLimit(1)
                        .foregroundStyle(package.status.isUpdateAvailable ? .primary : .secondary)
                }
                .width(min: 80, ideal: 95, max: 130)

                TableColumn("Status") { package in
                    PackageStatusLabel(status: package.status)
                }
                .width(min: 110, ideal: 130, max: 170)
            }
            .overlay {
                if store.state == .loading, store.packages.isEmpty {
                    ProgressView("Scanning package managers…")
                } else if store.state != .loading, store.filteredPackages.isEmpty {
                    ContentUnavailableView(
                        store.packages.isEmpty ? "No packages found" : "No matching packages",
                        systemImage: "shippingbox",
                        description: Text(store.packages.isEmpty
                            ? "Install a supported package manager or choose its executable in Settings."
                            : "Change the filter or search text.")
                    )
                }
            }

            if !store.updateEvents.isEmpty {
                Divider()
                UpdateEventLog(events: store.updateEvents)
                    .frame(minHeight: 110, idealHeight: 150, maxHeight: 200)
            }
        }
        .navigationTitle("Software Updates")
        .searchable(text: $store.searchText, prompt: "Search packages")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Filter", selection: $store.filter) {
                    ForEach(PackageInventoryFilter.allCases, id: \.self) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("Update target", selection: $store.updateMode) {
                    ForEach(PackageUpdateMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()

                if store.isUpdating {
                    Button("Stop", systemImage: "stop.circle", role: .destructive) {
                        store.cancelUpdates()
                    }
                    .help("Stop before the next package starts")
                } else {
                    Button("Update Selected", systemImage: "arrow.up.circle") {
                        store.prepareUpdatePlan()
                    }
                    .help("Review selected package updates")
                    .disabled(store.state == .preparing || !store.packages.contains {
                        store.selection.contains($0.id) && $0.isUpdateAvailable(for: store.updateMode)
                    })
                }

                if store.state == .preparing {
                    ProgressView()
                        .controlSize(.small)
                        .help("Validating Homebrew updates")
                }

                Button("Refresh", systemImage: "arrow.clockwise") {
                    store.reload()
                }
                .help("Scan all package managers")
                .disabled(store.isUpdating || store.isPreparing)
            }
        }
        .confirmationDialog(
            "Update selected packages?",
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Run Updates") { store.confirmPendingPlan() }
            Button("Cancel", role: .cancel) { store.pendingPlan = nil }
        } message: {
            if let plan = store.pendingPlan {
                Text(plan.items.map {
                    "\($0.package.name): \($0.package.installedVersion) → \($0.targetVersion)"
                }.joined(separator: "\n"))
            }
        }
        .alert("Error", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
        .inspector(isPresented: inspectorBinding) {
            if let inspectedPackage {
                PackageInspector(package: inspectedPackage, releaseNotesState: store.releaseNotesState)
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
            }
        }
        .onChange(of: store.selection) {
            if store.selection.count == 1, let id = store.selection.first,
               let package = store.packages.first(where: { $0.id == id }) {
                inspectedPackageID = id
                store.loadReleaseNotes(for: package)
            } else {
                inspectedPackageID = nil
                store.clearReleaseNotes()
            }
        }
        .onChange(of: store.updateMode) {
            if let inspectedPackage { store.loadReleaseNotes(for: inspectedPackage) }
        }
        .onAppear {
            if store.state == .idle { store.reload() }
        }
    }
}

private struct PackageStatusLabel: View {
    var status: PackageStatus

    var body: some View {
        Label(status.displayName, systemImage: systemImage)
            .foregroundStyle(foregroundStyle)
            .lineLimit(1)
    }

    private var systemImage: String {
        switch status {
        case .current: "checkmark.circle"
        case .updateAvailable: "arrow.up.circle"
        case .majorUpdateAvailable: "arrow.up.forward.circle"
        case .pinned: "pin.fill"
        case .selfUpdating: "arrow.triangle.2.circlepath"
        case .notWritable: "lock"
        case .unknown: "questionmark.circle"
        }
    }

    private var foregroundStyle: Color {
        switch status {
        case .updateAvailable: .blue
        case .majorUpdateAvailable: .orange
        case .pinned, .selfUpdating, .notWritable, .unknown, .current: .secondary
        }
    }
}

private struct ProviderIssueStrip: View {
    var issues: [PackageProviderIssue]
    var openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(issues) { issue in
                    Text(verbatim: "\(issue.manager.displayName): \(issue.message)")
                        .font(.caption)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("Settings…", action: openSettings)
        }
        .padding(10)
    }
}

private struct UpdateEventLog: View {
    var events: [PackageUpdateEvent]

    var body: some View {
        List(events) { event in
            HStack(alignment: .firstTextBaseline) {
                Label(event.packageName, systemImage: event.state.systemImage)
                    .frame(minWidth: 180, alignment: .leading)
                Text(event.message.isEmpty ? event.state.displayName : event.message)
                    .font(.caption)
                    .foregroundStyle(event.state == .failed ? .red : .secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .accessibilityLabel("Update log")
    }
}

private extension PackageUpdateEventState {
    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .running: "progress.indicator"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle"
        }
    }

    var displayName: String {
        switch self {
        case .queued: String(localized: "Queued")
        case .running: String(localized: "Running")
        case .succeeded: String(localized: "Succeeded")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        }
    }
}

private struct PackageInspector: View {
    var package: InstalledPackage
    var releaseNotesState: PackageReleaseNotesState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(package.manager.displayName, systemImage: package.manager.systemImage)
                        .foregroundStyle(.secondary)
                    Text(verbatim: package.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    PackageStatusLabel(status: package.status)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Installed", value: package.installedVersion)
                    LabeledContent("Compatible", value: package.wantedVersion ?? "—")
                    LabeledContent("Latest", value: package.latestVersion ?? "—")
                    LabeledContent("Package type", value: package.isDirect
                        ? String(localized: "Direct")
                        : String(localized: "Dependency"))
                    LabeledContent("Installation") {
                        Text(verbatim: package.installationID)
                            .font(.caption)
                            .monospaced()
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if let explanation = statusExplanation {
                    Text(explanation)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Release Notes")
                        .font(.headline)
                    switch releaseNotesState {
                    case .idle, .loading:
                        ProgressView()
                    case .unavailable:
                        Text("No release notes available")
                            .foregroundStyle(.secondary)
                    case .loaded(let notes):
                        Text(verbatim: notes.title)
                            .fontWeight(.medium)
                        if let body = notes.body, !body.isEmpty {
                            Text(verbatim: body)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Button("Open Release Notes", systemImage: "arrow.up.right.square") {
                            NSWorkspace.shared.open(notes.sourceURL)
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Details")
    }

    private var statusExplanation: String? {
        switch package.status {
        case .pinned:
            String(localized: "Pinned packages must be unpinned in Homebrew before they can be updated.")
        case .selfUpdating:
            String(localized: "This cask updates itself and is not upgraded directly by CodingBuddy.")
        case .notWritable:
            String(localized: "CodingBuddy cannot update this installation without additional permissions.")
        default:
            nil
        }
    }
}
