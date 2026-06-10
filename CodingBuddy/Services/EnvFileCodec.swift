//
//  EnvFileCodec.swift
//  CodingBuddy
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct EnvFileEntry: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var rawValue: String
}

/// Reads and writes dotenv-style files (one NAME=value per line).
enum EnvFileCodec {
    static let contentType = UTType(filenameExtension: "env") ?? .plainText

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
struct EnvFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [EnvFileCodec.contentType, .plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
