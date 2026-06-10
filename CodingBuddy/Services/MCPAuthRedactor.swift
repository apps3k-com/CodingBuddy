//
//  MCPAuthRedactor.swift
//  CodingBuddy
//

import Foundation

/// Builds masked previews of credential files: values of secret-bearing JSON
/// keys are replaced before anything reaches the screen.
nonisolated enum MCPAuthRedactor {
    private static let sensitiveKeyFragments = ["token", "secret", "verifier", "password", "key"]
    private static let mask = "••••••••"

    static func maskedPreview(text: String, isJSON: Bool) -> String {
        guard isJSON,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            // Non-JSON files (code_verifier.txt) are secrets in their entirety.
            return mask
        }
        let redacted = redact(object)
        guard let output = try? JSONSerialization.data(
            withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys]
        ), let string = String(data: output, encoding: .utf8) else {
            return mask
        }
        return string
    }

    private static func redact(_ value: Any, keyHint: String? = nil) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return Dictionary(uniqueKeysWithValues: dictionary.map { key, value in
                (key, redact(value, keyHint: key))
            })
        case let array as [Any]:
            return array.map { redact($0, keyHint: keyHint) }
        case let string as String:
            if let key = keyHint?.lowercased(),
               sensitiveKeyFragments.contains(where: { key.contains($0) }) {
                return mask
            }
            return string
        default:
            return value
        }
    }
}
