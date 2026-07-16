//
//  TOMLReader.swift
//  CodingBuddy
//

import Foundation

/// A TOML value as far as CodingBuddy needs it (reading Codex configs).
nonisolated indirect enum TOMLValue: Equatable {
    /// A TOML string value.
    case string(String)
    /// A TOML integer value.
    case int(Int)
    /// A TOML floating-point value.
    case double(Double)
    /// A TOML Boolean value.
    case bool(Bool)
    /// An ordered TOML array.
    case array([TOMLValue])
    /// A keyed TOML table.
    case table([String: TOMLValue])
}

/// Root table with path-based accessors.
nonisolated struct TOMLTable: Equatable {
    /// Root key-value storage for the parsed document.
    var values: [String: TOMLValue] = [:]

    /// Returns the value at a nested key path, or `nil` when the path is empty or unresolved.
    func value(at path: [String]) -> TOMLValue? {
        var current: TOMLValue = .table(values)
        for key in path {
            guard case .table(let table) = current, let next = table[key] else { return nil }
            current = next
        }
        return path.isEmpty ? nil : current
    }

    /// Returns the string at a nested key path when its TOML type matches.
    func string(at path: [String]) -> String? {
        if case .string(let value) = value(at: path) { return value }
        return nil
    }

    /// Returns the integer at a nested key path when its TOML type matches.
    func int(at path: [String]) -> Int? {
        if case .int(let value) = value(at: path) { return value }
        return nil
    }

    /// Returns the Boolean at a nested key path when its TOML type matches.
    func bool(at path: [String]) -> Bool? {
        if case .bool(let value) = value(at: path) { return value }
        return nil
    }

    /// Returns only string elements from the array at a nested key path.
    func stringArray(at path: [String]) -> [String]? {
        guard case .array(let items) = value(at: path) else { return nil }
        return items.compactMap { if case .string(let s) = $0 { s } else { nil } }
    }

    /// Returns the table at a nested path, or the root values for an empty path.
    func table(at path: [String]) -> [String: TOMLValue]? {
        if path.isEmpty { return values }
        if case .table(let value) = value(at: path) { return value }
        return nil
    }
}

/// Minimal, deliberately lenient TOML reader — read-only consumption of
/// `~/.codex/config.toml`. The native-only rule forbids a parser dependency,
/// and unsupported constructs (arrays of tables, datetimes, multiline
/// strings) are skipped instead of failing: partial results beat none for a
/// display-only consumer.
nonisolated enum TOMLReader {

    /// Parses supported TOML constructs while skipping malformed or unsupported entries.
    static func parse(_ text: String) -> TOMLTable {
        var root: [String: TOMLValue] = [:]
        var currentPath: [String] = []
        var skippingTable = false

        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = stripComment(lines[index]).trimmingCharacters(in: .whitespaces)
            index += 1
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[[") {
                // Arrays of tables are out of scope — skip their contents.
                skippingTable = true
                continue
            }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let inner = String(line.dropFirst().dropLast())
                if let keys = parseKeyPath(inner) {
                    currentPath = keys
                    skippingTable = false
                } else {
                    skippingTable = true
                }
                continue
            }
            guard !skippingTable else { continue }

            guard let equalsIndex = topLevelEqualsIndex(in: line) else { continue }
            let rawKey = String(line[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            var rawValue = String(line[line.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
            guard let keyPath = parseKeyPath(rawKey), !keyPath.isEmpty else { continue }

            // Arrays may span lines: join until brackets balance.
            while bracketBalance(of: rawValue) > 0, index < lines.count {
                rawValue += "\n" + stripComment(lines[index])
                index += 1
            }

            if let value = parseValue(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                set(&root, path: currentPath + keyPath, value: value)
            }
        }
        return TOMLTable(values: root)
    }

    // MARK: - Values

    private static func parseValue(_ raw: String) -> TOMLValue? {
        guard let first = raw.first else { return nil }
        switch first {
        case "\"":
            return parseBasicString(raw).map { TOMLValue.string($0.value) }
        case "'":
            guard raw.count >= 2, raw.hasSuffix("'") else { return nil }
            return .string(String(raw.dropFirst().dropLast()))
        case "[":
            guard raw.hasSuffix("]") else { return nil }
            let inner = String(raw.dropFirst().dropLast())
            let items = splitTopLevel(inner).compactMap { parseValue($0) }
            return .array(items)
        case "{":
            guard raw.hasSuffix("}") else { return nil }
            let inner = String(raw.dropFirst().dropLast())
            var table: [String: TOMLValue] = [:]
            for pair in splitTopLevel(inner) {
                guard let equals = topLevelEqualsIndex(in: pair) else { continue }
                let key = String(pair[..<equals]).trimmingCharacters(in: .whitespaces)
                let value = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                guard let keyPath = parseKeyPath(key), keyPath.count == 1,
                      let parsed = parseValue(value) else { continue }
                table[keyPath[0]] = parsed
            }
            return .table(table)
        default:
            if raw == "true" { return .bool(true) }
            if raw == "false" { return .bool(false) }
            if let int = Int(raw) { return .int(int) }
            if let double = Double(raw) { return .double(double) }
            return nil  // datetimes & friends: skipped leniently
        }
    }

    /// Parses a `"basic string"` from the start of `raw`; returns the decoded
    /// value and the index after the closing quote.
    private static func parseBasicString(_ raw: String) -> (value: String, end: String.Index)? {
        var value = ""
        var index = raw.index(after: raw.startIndex)
        var escaped = false
        while index < raw.endIndex {
            let character = raw[index]
            if escaped {
                switch character {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                default: value.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return (value, raw.index(after: index))
            } else {
                value.append(character)
            }
            index = raw.index(after: index)
        }
        return nil
    }

    // MARK: - Keys

    /// Splits `a.b."c.d"` into ["a", "b", "c.d"]; nil on anything malformed.
    private static func parseKeyPath(_ raw: String) -> [String]? {
        var keys: [String] = []
        var current = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            switch character {
            case "\"", "'":
                let quote = character
                index = raw.index(after: index)
                while index < raw.endIndex, raw[index] != quote {
                    current.append(raw[index])
                    index = raw.index(after: index)
                }
                guard index < raw.endIndex else { return nil }
            case ".":
                let key = current.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                keys.append(key)
                current = ""
            default:
                current.append(character)
            }
            index = raw.index(after: index)
        }
        let key = current.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        keys.append(key)
        return keys
    }

    // MARK: - Scanning helpers

    /// Removes a `#` comment, respecting quoted strings.
    private static func stripComment(_ line: String) -> String {
        var inBasic = false
        var inLiteral = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            switch character {
            case "\\" where inBasic: escaped = true
            case "\"" where !inLiteral: inBasic.toggle()
            case "'" where !inBasic: inLiteral.toggle()
            case "#" where !inBasic && !inLiteral:
                return String(line[..<index])
            default: break
            }
        }
        return line
    }

    private static func topLevelEqualsIndex(in text: String) -> String.Index? {
        var inBasic = false
        var inLiteral = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            switch character {
            case "\\" where inBasic: escaped = true
            case "\"" where !inLiteral: inBasic.toggle()
            case "'" where !inBasic: inLiteral.toggle()
            case "=" where !inBasic && !inLiteral: return index
            default: break
            }
        }
        return nil
    }

    /// Net `[`/`{` balance outside strings — > 0 means the value continues
    /// on the next line.
    private static func bracketBalance(of text: String) -> Int {
        var balance = 0
        var inBasic = false
        var inLiteral = false
        var escaped = false
        for character in text {
            if escaped { escaped = false; continue }
            switch character {
            case "\\" where inBasic: escaped = true
            case "\"" where !inLiteral: inBasic.toggle()
            case "'" where !inBasic: inLiteral.toggle()
            case "[", "{": if !inBasic && !inLiteral { balance += 1 }
            case "]", "}": if !inBasic && !inLiteral { balance -= 1 }
            default: break
            }
        }
        return balance
    }

    /// Splits on top-level commas (outside strings, brackets, braces),
    /// dropping empty segments (trailing commas).
    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inBasic = false
        var inLiteral = false
        var escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            switch character {
            case "\\" where inBasic:
                current.append(character); escaped = true
            case "\"" where !inLiteral:
                current.append(character); inBasic.toggle()
            case "'" where !inBasic:
                current.append(character); inLiteral.toggle()
            case "[", "{":
                if !inBasic && !inLiteral { depth += 1 }
                current.append(character)
            case "]", "}":
                if !inBasic && !inLiteral { depth -= 1 }
                current.append(character)
            case "," where depth == 0 && !inBasic && !inLiteral:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Assembly

    private static func set(_ table: inout [String: TOMLValue], path: [String], value: TOMLValue) {
        guard let first = path.first else { return }
        if path.count == 1 {
            table[first] = value
            return
        }
        var child: [String: TOMLValue] = [:]
        if case .table(let existing)? = table[first] { child = existing }
        set(&child, path: Array(path.dropFirst()), value: value)
        table[first] = .table(child)
    }
}
