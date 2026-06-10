//
//  JSONPatcher.swift
//  CodingBuddy
//

import Foundation

/// Value-precise edits in JSON documents that other tools own (Claude Code's
/// settings.json, Cursor's mcp.json): a `JSONSerialization` roundtrip would
/// reorder keys and reformat the whole file, so the patcher touches only the
/// target bytes — and proves it afterwards by comparing the parsed result
/// against the expected mutation (fail closed: any mismatch throws and
/// nothing is returned).
nonisolated enum JSONPatcher {

    enum PatchError: LocalizedError, Equatable {
        case malformedJSON
        case pathNotFound
        case notAString
        case duplicateKey
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .malformedJSON:
                String(localized: "The file is not valid JSON.")
            case .pathNotFound:
                String(localized: "The entry was not found in the file.")
            case .notAString:
                String(localized: "Only text values can be edited.")
            case .duplicateKey:
                String(localized: "The file contains duplicate keys — it is left untouched.")
            case .verificationFailed:
                String(localized: "The change could not be applied safely — the file is left untouched.")
            }
        }
    }

    // MARK: - Operations

    /// Replaces the string value at `path` (object keys only).
    static func replaceString(in text: String, at path: [String], with newValue: String) throws -> String {
        guard let key = path.last else { throw PatchError.pathNotFound }
        let parsedOld = try parse(text)
        let object = try objectInfo(in: text, at: Array(path.dropLast()))
        guard let member = object.members.first(where: { $0.key == key }) else {
            throw PatchError.pathNotFound
        }
        guard text[member.valueRange.lowerBound] == "\"" else { throw PatchError.notAString }

        var result = text
        result.replaceSubrange(member.valueRange, with: encodeJSONString(newValue))

        try verify(old: parsedOld, newText: result, path: path) { dict in
            var dict = dict
            dict[key] = newValue
            return dict
        }
        return result
    }

    /// Inserts `"key": "value"` into the object at `objectPath`, matching the
    /// indentation of the existing members.
    static func insertPair(in text: String, at objectPath: [String], key: String, value: String) throws -> String {
        let parsedOld = try parse(text)
        let object = try objectInfo(in: text, at: objectPath)
        guard !object.members.contains(where: { $0.key == key }) else {
            throw PatchError.duplicateKey
        }

        let pair = "\(encodeJSONString(key)): \(encodeJSONString(value))"
        var result = text
        if let last = object.members.last {
            let indent = indentation(of: last.keyStart, in: text)
            result.insert(contentsOf: ",\n\(indent)\(pair)", at: last.valueRange.upperBound)
        } else {
            result.insert(contentsOf: " \(pair) ", at: text.index(after: object.openBrace))
        }

        try verify(old: parsedOld, newText: result, path: objectPath + [key]) { dict in
            var dict = dict
            dict[key] = value
            return dict
        }
        return result
    }

    /// Removes the `"key": value` pair at `path`, including the surrounding
    /// comma so the document stays valid.
    static func removePair(in text: String, at path: [String]) throws -> String {
        guard let key = path.last else { throw PatchError.pathNotFound }
        let parsedOld = try parse(text)
        let object = try objectInfo(in: text, at: Array(path.dropLast()))
        guard let memberIndex = object.members.firstIndex(where: { $0.key == key }) else {
            throw PatchError.pathNotFound
        }
        let member = object.members[memberIndex]

        var result = text
        if object.members.count == 1 {
            result.removeSubrange(text.index(after: object.openBrace)..<object.closeBrace)
        } else if memberIndex < object.members.count - 1 {
            // Up to the next key: wipes value, comma and inter-pair whitespace.
            result.removeSubrange(member.keyStart..<object.members[memberIndex + 1].keyStart)
        } else {
            // Last pair: from the end of the previous value (eats the comma).
            let previous = object.members[memberIndex - 1]
            result.removeSubrange(previous.valueRange.upperBound..<member.valueRange.upperBound)
        }

        try verify(old: parsedOld, newText: result, path: path) { dict in
            var dict = dict
            dict.removeValue(forKey: key)
            return dict
        }
        return result
    }

    // MARK: - Verification

    private static func parse(_ text: String) throws -> Any {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            throw PatchError.malformedJSON
        }
        return object
    }

    /// Applies the expected mutation to the parsed old document and demands
    /// that the patched text parses to exactly that.
    private static func verify(
        old: Any, newText: String, path: [String],
        transform: ([String: Any]) -> [String: Any]
    ) throws {
        guard let newParsed = try? parse(newText),
              let expected = mutated(old, parentPath: Array(path.dropLast()), transform: transform),
              (expected as AnyObject).isEqual(newParsed)
        else {
            throw PatchError.verificationFailed
        }
    }

    private static func mutated(
        _ node: Any, parentPath: [String],
        transform: ([String: Any]) -> [String: Any]
    ) -> Any? {
        guard let dict = node as? [String: Any] else { return nil }
        guard let key = parentPath.first else { return transform(dict) }
        guard let child = dict[key],
              let mutatedChild = mutated(child, parentPath: Array(parentPath.dropFirst()), transform: transform)
        else { return nil }
        var copy = dict
        copy[key] = mutatedChild
        return copy
    }

    // MARK: - Scanning

    private struct Member {
        var key: String
        var keyStart: String.Index
        var valueRange: Range<String.Index>
    }

    private struct ObjectInfo {
        var openBrace: String.Index
        var closeBrace: String.Index
        var members: [Member]
    }

    /// Walks the raw text down `path` and returns the target object with the
    /// exact ranges of its members. Throws on duplicate keys anywhere along
    /// the visited chain — patching an ambiguous document is unsafe.
    private static func objectInfo(in text: String, at path: [String]) throws -> ObjectInfo {
        var scanner = TextScanner(text)
        scanner.skipWhitespace()
        var info = try scanner.scanObject()
        try ensureUniqueKeys(info)

        for key in path {
            guard let member = info.members.first(where: { $0.key == key }),
                  text[member.valueRange.lowerBound] == "{"
            else { throw PatchError.pathNotFound }
            var sub = TextScanner(text, at: member.valueRange.lowerBound)
            info = try sub.scanObject()
            try ensureUniqueKeys(info)
        }
        return info
    }

    private static func ensureUniqueKeys(_ info: ObjectInfo) throws {
        guard Set(info.members.map(\.key)).count == info.members.count else {
            throw PatchError.duplicateKey
        }
    }

    /// Leading whitespace of the line containing `position`.
    private static func indentation(of position: String.Index, in text: String) -> String {
        var start = position
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous] == "\n" { break }
            start = previous
        }
        return String(text[start..<position].prefix { $0 == " " || $0 == "\t" })
    }

    // MARK: - String encoding

    static func encodeJSONString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Low-level scanner

    private struct TextScanner {
        let text: String
        var index: String.Index

        init(_ text: String, at index: String.Index? = nil) {
            self.text = text
            self.index = index ?? text.startIndex
        }

        var current: Character? { index < text.endIndex ? text[index] : nil }

        mutating func advance() {
            index = text.index(after: index)
        }

        mutating func skipWhitespace() {
            while let character = current, character == " " || character == "\t" || character == "\n" || character == "\r" {
                advance()
            }
        }

        mutating func scanObject() throws -> ObjectInfo {
            guard current == "{" else { throw PatchError.malformedJSON }
            let open = index
            advance()
            var members: [Member] = []

            skipWhitespace()
            if current == "}" {
                return ObjectInfo(openBrace: open, closeBrace: index, members: members)
            }
            while true {
                skipWhitespace()
                let keyStart = index
                let key = try scanString().decoded
                skipWhitespace()
                guard current == ":" else { throw PatchError.malformedJSON }
                advance()
                skipWhitespace()
                let valueRange = try skipValue()
                members.append(Member(key: key, keyStart: keyStart, valueRange: valueRange))
                skipWhitespace()
                if current == "," {
                    advance()
                    continue
                }
                guard current == "}" else { throw PatchError.malformedJSON }
                return ObjectInfo(openBrace: open, closeBrace: index, members: members)
            }
        }

        mutating func skipValue() throws -> Range<String.Index> {
            switch current {
            case "\"":
                return try scanString().range
            case "{":
                let start = index
                let info = try scanObject()
                index = text.index(after: info.closeBrace)
                return start..<index
            case "[":
                let start = index
                advance()
                skipWhitespace()
                if current == "]" {
                    advance()
                    return start..<index
                }
                while true {
                    skipWhitespace()
                    _ = try skipValue()
                    skipWhitespace()
                    if current == "," { advance(); continue }
                    guard current == "]" else { throw PatchError.malformedJSON }
                    advance()
                    return start..<index
                }
            default:
                // Literals: true/false/null/numbers.
                let start = index
                while let character = current,
                      character != ",", character != "}", character != "]",
                      character != " ", character != "\t", character != "\n", character != "\r" {
                    advance()
                }
                guard index > start else { throw PatchError.malformedJSON }
                return start..<index
            }
        }

        /// Scans a JSON string, decoding escapes (incl. \uXXXX surrogate
        /// pairs) so keys compare correctly.
        mutating func scanString() throws -> (decoded: String, range: Range<String.Index>) {
            guard current == "\"" else { throw PatchError.malformedJSON }
            let start = index
            advance()
            var decoded = ""
            while let character = current {
                if character == "\"" {
                    advance()
                    return (decoded, start..<index)
                }
                if character == "\\" {
                    advance()
                    guard let escape = current else { break }
                    switch escape {
                    case "n": decoded.append("\n")
                    case "t": decoded.append("\t")
                    case "r": decoded.append("\r")
                    case "b": decoded.append("\u{08}")
                    case "f": decoded.append("\u{0C}")
                    case "u":
                        advance()
                        guard let first = try scanHexScalar() else { throw PatchError.malformedJSON }
                        // UTF-16 surrogate pair: combine with the following \uXXXX.
                        if (0xD800...0xDBFF).contains(first), current == "\\" {
                            let saved = index
                            advance()
                            if current == "u" {
                                advance()
                                if let second = try scanHexScalar(),
                                   (0xDC00...0xDFFF).contains(second) {
                                    let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                                    if let unicode = Unicode.Scalar(combined) {
                                        decoded.unicodeScalars.append(unicode)
                                    }
                                    continue
                                }
                            }
                            index = saved
                        }
                        if !(0xD800...0xDFFF).contains(first), let unicode = Unicode.Scalar(first) {
                            decoded.unicodeScalars.append(unicode)
                        }
                        continue
                    default: decoded.append(escape)
                    }
                    advance()
                    continue
                }
                decoded.append(character)
                advance()
            }
            throw PatchError.malformedJSON
        }

        /// Reads exactly four hex digits; leaves the cursor after them.
        mutating func scanHexScalar() throws -> UInt32? {
            var hex = ""
            for _ in 0..<4 {
                guard let character = current else { throw PatchError.malformedJSON }
                hex.append(character)
                advance()
            }
            return UInt32(hex, radix: 16)
        }
    }
}
