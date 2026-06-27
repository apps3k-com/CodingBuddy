//
//  AgentDoctorView.swift
//  CodingBuddy
//

import SwiftUI

/// Read-only Agent Doctor dashboard that surfaces local agent configuration diagnostics.
struct AgentDoctorView: View {
    /// Observable state that owns the latest scanner snapshot.
    var store: AgentDoctorStore

    /// Currently selected table row, used only for native table affordances.
    @State private var selection: AgentDiagnostic.ID?

    /// Table-based dashboard layout with refresh and empty states.
    var body: some View {
        Table(store.diagnostics, selection: $selection) {
            TableColumn("Severity") { diagnostic in
                SeverityCell(severity: diagnostic.severity)
            }
            .width(min: 95, ideal: 115, max: 135)

            TableColumn("Tool") { diagnostic in
                Text(verbatim: diagnostic.tool.displayName)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 140, max: 180)

            TableColumn("Finding") { diagnostic in
                FindingCell(diagnostic: diagnostic)
            }
            .width(min: 240, ideal: 340)

            TableColumn("Source") { diagnostic in
                SourceCell(diagnostic: diagnostic)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Next Action") { diagnostic in
                Text(diagnostic.suggestion)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            .width(min: 220, ideal: 320)
        }
        .navigationTitle("Agent Doctor")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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

/// Source metadata cell for paths, hashes, modes, and referenced environment variables.
private struct SourceCell: View {
    /// Diagnostic whose non-secret source metadata should be shown.
    var diagnostic: AgentDiagnostic

    /// Monospaced source and optional subject stack.
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: diagnostic.source)
                .font(.caption)
                .monospaced()
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            if let subject = diagnostic.subject, !subject.isEmpty {
                Text(verbatim: subject)
                    .font(.caption2)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.tertiary)
            }
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
