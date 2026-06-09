//
//  PathEditorView.swift
//  EnvVarBuddy
//

import SwiftUI

/// Edits a `:`-separated value (PATH and friends) as a reorderable list of
/// segments. `$PATH`-style references stay verbatim as their own segment.
struct PathEditorView: View {
    @Binding var rawValue: String

    private struct Segment: Identifiable, Equatable {
        let id = UUID()
        var text: String
    }

    @State private var segments: [Segment]

    init(rawValue: Binding<String>) {
        _rawValue = rawValue
        _segments = State(initialValue: rawValue.wrappedValue
            .components(separatedBy: ":")
            .map { Segment(text: $0) })
    }

    var body: some View {
        List {
            ForEach($segments) { $segment in
                HStack {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                    TextField("Eintrag", text: $segment.text)
                        .monospaced()
                        .textFieldStyle(.plain)
                    Button {
                        segments.removeAll { $0.id == segment.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Eintrag entfernen")
                }
            }
            .onMove { source, destination in
                segments.move(fromOffsets: source, toOffset: destination)
            }
        }
        .frame(minHeight: 140)

        Button("Eintrag hinzufügen", systemImage: "plus") {
            segments.append(Segment(text: ""))
        }
        .buttonStyle(.borderless)

        // Sync back: the bound raw value is always the joined list.
        .onChange(of: segments) {
            rawValue = segments.map(\.text).joined(separator: ":")
        }
    }
}
