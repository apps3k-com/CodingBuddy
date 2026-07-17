//
//  EnvFileCodec.swift
//  CodingBuddy
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Editable name/value data imported from one unambiguous dotenv assignment.
nonisolated struct EnvFileEntry: Identifiable, Equatable {
    /// Ephemeral identity used only for SwiftUI collection diffing.
    let id = UUID()
    /// Environment variable name parsed from the assignment.
    var name: String
    /// Unquoted value preserved for editing and later encoding.
    var rawValue: String
}

/// Reads and writes dotenv-style files (one NAME=value per line).
nonisolated enum EnvFileCodec {
    /// Preferred document type for `.env` exports, with plain text as a fallback.
    static let contentType = UTType(filenameExtension: "env") ?? .plainText

    /// Encodes only editable variables and appends a final newline when output is nonempty.
    static func encode(_ variables: [EnvVariable]) -> String {
        let lines = variables.filter(\.isEditable).map { variable -> String in
            let quoting = ShellQuoting.bestQuoting(for: variable.rawValue, preferred: .none) ?? .double
            return variable.name + "=" + quoting.delimiter + variable.rawValue + quoting.delimiter
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// dotenv lines are a subset of shell assignments, so the shell parser
    /// does the heavy lifting; comments, blanks and complex lines are skipped.
    static func decode(_ content: String) -> [EnvFileEntry] {
        content.components(separatedBy: .newlines).compactMap { line in
            guard let assignment = ShellConfigParser.parseLine(line), assignment.isEditable else {
                return nil
            }
            return EnvFileEntry(name: assignment.name, rawValue: assignment.rawValue)
        }
    }
}

/// Minimal text document for the SwiftUI file exporter.
nonisolated struct EnvFileDocument: FileDocument {
    /// File types accepted by the importer, ordered from specific to general.
    static var readableContentTypes: [UTType] { [EnvFileCodec.contentType, .plainText] }

    /// UTF-8 text represented by the document.
    var text: String

    /// Creates an exportable document from already encoded text.
    init(text: String) {
        self.text = text
    }

    /// Loads regular-file bytes as UTF-8, producing empty text when no decodable payload exists.
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    /// Emits the current text as a regular UTF-8 file without additional normalization.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
