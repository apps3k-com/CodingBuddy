//
//  PathEditorView.swift
//  CodingBuddy
//

import SwiftUI

/// Edits a `:`-separated value (PATH and friends) as a reorderable list of
/// segments. `$PATH`-style references stay verbatim as their own segment.
struct PathEditorView: View {
    /// Raw colon-separated value synchronized with the editable segment list.
    @Binding var rawValue: String

    private struct Segment: Identifiable, Equatable {
        /// Session-local identity that keeps list edits and reordering stable.
        let id = UUID()
        /// Verbatim path segment, including variable references or empty entries.
        var text: String
    }

    /// Editable segments initialized from ``rawValue``.
    @State private var segments: [Segment]

    /// Splits the initial bound value without expanding shell references.
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
                    TextField("Entry", text: $segment.text)
                        .monospaced()
                        .textFieldStyle(.plain)
                    Button {
                        segments.removeAll { $0.id == segment.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove entry")
                }
            }
            .onMove { source, destination in
                segments.move(fromOffsets: source, toOffset: destination)
            }
        }
        .frame(minHeight: 140)

        Button("Add Entry", systemImage: "plus") {
            segments.append(Segment(text: ""))
        }
        .buttonStyle(.borderless)

        // Sync back: the bound raw value is always the joined list.
        .onChange(of: segments) {
            rawValue = segments.map(\.text).joined(separator: ":")
        }
    }
}
