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

/// Incremental delimiter scanner for multiline arrays and inline tables.
private nonisolated struct BracketContinuationState {
    /// Expected closing delimiters retained across physical lines.
    private var expectedClosers: [Character] = []
    /// Whether malformed quoting or mismatched delimiters were observed.
    private var isMalformed = false

    /// Whether another physical line is required to close the value.
    var needsMoreLines: Bool { !isMalformed && !expectedClosers.isEmpty }
    /// Whether the value ended with balanced, type-matched delimiters.
    var isComplete: Bool { !isMalformed && expectedClosers.isEmpty }

    /// Scans one physical line exactly once; ordinary TOML strings cannot cross it.
    mutating func scanLine(_ line: String) {
        guard !isMalformed else { return }
        var inBasic = false
        var inLiteral = false
        var escaped = false
        for character in line {
            if escaped {
                escaped = false
                continue
            }
            switch character {
            case "\\" where inBasic:
                escaped = true
            case "\"" where !inLiteral:
                inBasic.toggle()
            case "'" where !inBasic:
                inLiteral.toggle()
            case "[" where !inBasic && !inLiteral:
                expectedClosers.append("]")
            case "{" where !inBasic && !inLiteral:
                expectedClosers.append("}")
            case let closing where (closing == "]" || closing == "}") && !inBasic && !inLiteral:
                guard expectedClosers.last == closing else {
                    isMalformed = true
                    return
                }
                expectedClosers.removeLast()
            default:
                break
            }
        }
        if inBasic || inLiteral || escaped { isMalformed = true }
    }
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

    /// Returns the string array at a nested key path only when every element matches.
    func stringArray(at path: [String]) -> [String]? {
        guard case .array(let items) = value(at: path) else { return nil }
        var strings: [String] = []
        for item in items {
            guard case .string(let string) = item else { return nil }
            strings.append(string)
        }
        return strings
    }

    /// Returns the table at a nested path, or the root values for an empty path.
    func table(at path: [String]) -> [String: TOMLValue]? {
        if path.isEmpty { return values }
        if case .table(let value) = value(at: path) { return value }
        return nil
    }
}

/// Parsed supported TOML plus an explicit signal that unsupported or malformed input was skipped.
nonisolated struct TOMLParseResult: Equatable {
    /// Supported values retained by the native reader.
    let table: TOMLTable
    /// False when any non-comment construct could not be represented faithfully.
    let isComplete: Bool
}

/// Minimal, deliberately lenient TOML reader — read-only consumption of
/// `~/.codex/config.toml`. The native-only rule forbids a parser dependency,
/// and unsupported constructs (arrays of tables, datetimes, multiline
/// strings) are retained only as explicitly incomplete diagnostics.
nonisolated enum TOMLReader {

    /// Parses supported TOML constructs while skipping malformed or unsupported entries.
    static func parse(_ text: String) -> TOMLTable {
        parseWithDiagnostics(text).table
    }

    /// Parses supported TOML and reports whether every encountered construct was understood.
    static func parseWithDiagnostics(_ text: String) -> TOMLParseResult {
        var root: [String: TOMLValue] = [:]
        var currentPath: [String] = []
        var skippingTable = false
        var isComplete = true
        var occupiedPaths: [[String]: PathOccupation] = [:]

        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = stripComment(lines[index]).trimmingCharacters(in: .whitespaces)
            index += 1
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[[") {
                // Arrays of tables are out of scope — skip their contents.
                skippingTable = true
                isComplete = false
                continue
            }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let inner = String(line.dropFirst().dropLast())
                if let keys = parseKeyPath(inner) {
                    currentPath = keys
                    skippingTable = false
                    if !claimTablePath(keys, in: &occupiedPaths) {
                        isComplete = false
                    }
                } else {
                    skippingTable = true
                    isComplete = false
                }
                continue
            }
            if line.hasPrefix("[") {
                skippingTable = true
                isComplete = false
                continue
            }
            guard !skippingTable else { continue }

            guard let equalsIndex = topLevelEqualsIndex(in: line) else {
                isComplete = false
                continue
            }
            let rawKey = String(line[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            var rawValue = String(line[line.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
            guard let keyPath = parseKeyPath(rawKey), !keyPath.isEmpty else {
                isComplete = false
                continue
            }

            // Arrays and inline tables may span lines. Scan each appended line once so
            // a bounded but adversarial document cannot force quadratic rescanning.
            var continuation = BracketContinuationState()
            continuation.scanLine(rawValue)
            while continuation.needsMoreLines, index < lines.count {
                let nextLine = stripComment(lines[index])
                rawValue += "\n" + nextLine
                continuation.scanLine(nextLine)
                index += 1
            }
            guard continuation.isComplete else {
                isComplete = false
                continue
            }

            let canonicalPath = currentPath + keyPath
            guard claimValuePath(
                canonicalPath,
                tableContextDepth: currentPath.count,
                in: &occupiedPaths
            ) else {
                isComplete = false
                continue
            }

            if let value = parseValue(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                set(&root, path: canonicalPath, value: value)
            } else {
                isComplete = false
            }
        }
        return TOMLParseResult(table: TOMLTable(values: root), isComplete: isComplete)
    }

    // MARK: - Values

    private static func parseValue(_ raw: String) -> TOMLValue? {
        guard let first = raw.first else { return nil }
        switch first {
        case "\"":
            guard let parsed = parseBasicString(raw), parsed.end == raw.endIndex else { return nil }
            return .string(parsed.value)
        case "'":
            let contentStart = raw.index(after: raw.startIndex)
            guard let closingQuote = raw[contentStart...].firstIndex(of: "'"),
                  raw.index(after: closingQuote) == raw.endIndex else { return nil }
            return .string(String(raw[contentStart..<closingQuote]))
        case "[":
            guard raw.hasSuffix("]") else { return nil }
            let inner = String(raw.dropFirst().dropLast())
            var items: [TOMLValue] = []
            var members = splitTopLevel(inner)
            if members.count == 1, members[0].isEmpty { return .array([]) }
            if members.last?.isEmpty == true { members.removeLast() }
            guard !members.isEmpty, members.allSatisfy({ !$0.isEmpty }) else { return nil }
            for item in members {
                guard let parsed = parseValue(item) else { return nil }
                items.append(parsed)
            }
            return .array(items)
        case "{":
            guard raw.hasSuffix("}") else { return nil }
            let inner = String(raw.dropFirst().dropLast())
            var table: [String: TOMLValue] = [:]
            let members = splitTopLevel(inner)
            if members.count == 1, members[0].isEmpty { return .table([:]) }
            guard members.allSatisfy({ !$0.isEmpty }) else { return nil }
            for pair in members {
                guard let equals = topLevelEqualsIndex(in: pair) else { return nil }
                let key = String(pair[..<equals]).trimmingCharacters(in: .whitespaces)
                let value = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                guard let keyPath = parseKeyPath(key), keyPath.count == 1,
                      table[keyPath[0]] == nil,
                      let parsed = parseValue(value) else { return nil }
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

    /// Splits on top-level commas (outside strings, brackets, braces), preserving malformed gaps.
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
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Assembly

    /// Canonical path occupancy distinguishes extendable tables from closed values.
    private enum PathOccupation {
        /// A parent table implied by a deeper declaration.
        case implicitHeaderTable
        /// A table created by a dotted key and therefore closed to later table redeclaration.
        case dottedKeyTable
        /// A table declared by a table header.
        case explicitTable
        /// A scalar, array, or closed inline-table value.
        case value
    }

    /// Claims one explicit table without reopening a value or redeclaring a table.
    private static func claimTablePath(
        _ path: [String],
        in occupiedPaths: inout [[String]: PathOccupation]
    ) -> Bool {
        guard claimParentTables(
            of: path,
            creating: .implicitHeaderTable,
            in: &occupiedPaths
        ) else { return false }
        switch occupiedPaths[path] {
        case nil:
            occupiedPaths[path] = .explicitTable
            return true
        case .implicitHeaderTable:
            occupiedPaths[path] = .explicitTable
            return true
        case .dottedKeyTable, .explicitTable, .value:
            return false
        }
    }

    /// Claims one exact key while refusing any table/value collision on its path.
    private static func claimValuePath(
        _ path: [String],
        tableContextDepth: Int,
        in occupiedPaths: inout [[String]: PathOccupation]
    ) -> Bool {
        guard claimParentTables(
            of: path,
            creating: .dottedKeyTable,
            preservingPrefixesThrough: tableContextDepth,
            in: &occupiedPaths
        ), occupiedPaths[path] == nil else {
            return false
        }
        occupiedPaths[path] = .value
        return true
    }

    /// Materializes implicit parent tables unless a closed value already owns a prefix.
    private static func claimParentTables(
        of path: [String],
        creating occupation: PathOccupation,
        preservingPrefixesThrough preservedDepth: Int = 0,
        in occupiedPaths: inout [[String]: PathOccupation]
    ) -> Bool {
        guard !path.isEmpty else { return false }
        for length in 1..<path.count {
            let prefix = Array(path.prefix(length))
            if occupiedPaths[prefix] == .value { return false }
            if occupiedPaths[prefix] == nil {
                occupiedPaths[prefix] = occupation
            } else if length > preservedDepth,
                      occupiedPaths[prefix] == .implicitHeaderTable,
                      occupation == .dottedKeyTable {
                occupiedPaths[prefix] = .dottedKeyTable
            }
        }
        return true
    }

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
