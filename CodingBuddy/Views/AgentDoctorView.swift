//
//  AgentDoctorView.swift
//  CodingBuddy
//

import SwiftUI

/// Read-only Agent Doctor dashboard that surfaces local agent configuration diagnostics.
struct AgentDoctorView: View {
    /// Observable state that owns the latest scanner snapshot.
    var store: AgentDoctorStore
    /// Routes a finding to the existing editor or credential view that owns it.
    var onOpenDestination: (AgentDiagnosticTool) -> Void = { _ in }

    /// Currently selected table row, used only for native table affordances.
    @State private var selection: AgentDiagnostic.ID?

    /// Selected finding, if it still exists in the current scanner snapshot.
    private var selectedDiagnostic: AgentDiagnostic? {
        selection.flatMap { id in store.diagnostics.first { $0.id == id } }
    }

    /// Existing absolute source file that can be opened safely.
    private var selectedSourceURL: URL? {
        guard let source = selectedDiagnostic?.source, source.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: source)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Inspector visibility follows table selection and clears it when dismissed.
    private var inspectorBinding: Binding<Bool> {
        Binding {
            selectedDiagnostic != nil
        } set: { isPresented in
            if !isPresented { selection = nil }
        }
    }

    /// Table-based dashboard layout with refresh and empty states.
    var body: some View {
        Table(store.diagnostics, selection: $selection) {
            TableColumn("Severity") { diagnostic in
                SeverityCell(severity: diagnostic.severity)
            }
            .width(min: 95, ideal: 115, max: 135)

            TableColumn("Finding") { diagnostic in
                FindingCell(diagnostic: diagnostic)
            }
            .width(min: 240, ideal: 340)

            TableColumn("Tool") { diagnostic in
                Text(verbatim: diagnostic.tool.displayName)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 140, max: 180)
        }
        .navigationTitle("Agent Doctor")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open Tool", systemImage: "arrow.right.circle") {
                    if let selectedDiagnostic {
                        onOpenDestination(selectedDiagnostic.tool)
                    }
                }
                .help("Open the selected finding's tool")
                .disabled(selectedDiagnostic == nil)

                Button("Open Source", systemImage: "doc.text") {
                    openSelectedSource()
                }
                .help("Open the selected source file")
                .disabled(selectedSourceURL == nil)

                Button("Refresh", systemImage: "arrow.clockwise") {
                    store.reload()
                }
                .help("Refresh diagnostics")
            }
        }
        .overlay {
            if store.diagnostics.isEmpty {
                ContentUnavailableView(
                    "No diagnostics",
                    systemImage: "checkmark.circle",
                    description: Text("Agent Doctor did not find anything that needs attention.")
                )
            }
        }
        .inspector(isPresented: inspectorBinding) {
            if let selectedDiagnostic {
                AgentDiagnosticInspector(
                    diagnostic: selectedDiagnostic,
                    canOpenSource: selectedSourceURL != nil,
                    openDestination: { onOpenDestination(selectedDiagnostic.tool) },
                    openSource: openSelectedSource
                )
                .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
            }
        }
    }

    /// Opens the selected diagnostic source with the configured external editor.
    private func openSelectedSource() {
        guard let selectedSourceURL else { return }
        Task {
            _ = await ExternalFileOpener().open(selectedSourceURL)
        }
    }
}

/// Complete metadata and follow-up actions for one selected diagnostic.
private struct AgentDiagnosticInspector: View {
    /// Diagnostic represented by the inspector.
    var diagnostic: AgentDiagnostic
    /// Whether the source points to an existing local file.
    var canOpenSource: Bool
    /// Opens the owning CodingBuddy destination.
    var openDestination: () -> Void
    /// Opens the source file in the configured editor.
    var openSource: () -> Void

    /// Quiet, unframed detail layout that keeps the table focused on triage.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    SeverityCell(severity: diagnostic.severity)
                    Text(diagnostic.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(diagnostic.detail)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Tool", value: diagnostic.tool.displayName)
                    LabeledContent("Source") {
                        Text(verbatim: diagnostic.source)
                            .monospaced()
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    if let subject = diagnostic.subject, !subject.isEmpty {
                        LabeledContent("Subject") {
                            Text(verbatim: subject)
                                .monospaced()
                                .textSelection(.enabled)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Next Action")
                        .font(.headline)
                    Text(diagnostic.suggestion)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Open Tool", systemImage: "arrow.right.circle", action: openDestination)
                    Button("Open Source", systemImage: "doc.text", action: openSource)
                        .disabled(!canOpenSource)
                }
            }
            .padding(16)
        }
        .navigationTitle("Details")
    }
}

/// Compact severity indicator used by the Agent Doctor table.
private struct SeverityCell: View {
    /// Severity represented by this compact table cell.
    var severity: AgentDiagnosticSeverity

    /// Label with SF Symbol and localized severity text.
    var body: some View {
        Label {
            Text(severity.localizedTitle)
        } icon: {
            Image(systemName: severity.systemImageName)
                .foregroundStyle(severity.tint)
        }
        .lineLimit(1)
    }
}

/// Two-line finding summary that keeps localized diagnostic prose scannable.
private struct FindingCell: View {
    /// Diagnostic whose title and explanatory detail should be shown.
    var diagnostic: AgentDiagnostic

    /// Two-line text stack optimized for dense table rows.
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(diagnostic.title)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(diagnostic.detail)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
        }
    }
}

/// Presentation helpers for Agent Doctor severity values.
private extension AgentDiagnosticSeverity {
    /// Localized severity name shown in the table.
    var localizedTitle: String {
        switch self {
        case .error:
            String(localized: "Error")
        case .warning:
            String(localized: "Warning")
        case .info:
            String(localized: "Info")
        }
    }

    /// SF Symbol that visually distinguishes severity levels.
    var systemImageName: String {
        switch self {
        case .error:
            "xmark.octagon.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .info:
            "info.circle.fill"
        }
    }

    /// Semantic tint for the severity symbol.
    var tint: Color {
        switch self {
        case .error:
            .red
        case .warning:
            .orange
        case .info:
            .blue
        }
    }
}
