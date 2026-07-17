//
//  MCPAuthRedactor.swift
//  CodingBuddy
//

import Foundation

/// Builds masked previews of JSON and opaque credential files before content reaches the screen.
nonisolated enum MCPAuthRedactor {
    /// Determines how aggressively structurally valid JSON values are hidden.
    enum Policy: Equatable, Sendable {
        /// Masks values selected by the credential schema while retaining known metadata.
        case credentialArtifact
        /// Masks every scalar value while preserving only JSON keys and container shape.
        case backupPreview
    }

    private static let sensitiveKeyFragments = ["token", "secret", "verifier", "password", "key"]
    private static let mask = "••••••••"

    /// Returns a display-safe preview, masking sensitive JSON fields or the entire non-JSON value.
    static func maskedPreview(
        text: String,
        isJSON: Bool,
        policy: Policy = .credentialArtifact
    ) -> String {
        guard isJSON,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            // Non-JSON files (code_verifier.txt) are secrets in their entirety.
            return mask
        }
        guard policy != .credentialArtifact || object is [String: Any] else {
            // Credential artifacts are object-shaped; every other root could be
            // an opaque secret and must therefore fail closed as one value.
            return mask
        }
        let redacted = redact(object, policy: policy)
        guard let output = try? JSONSerialization.data(
            withJSONObject: redacted, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]
        ), let string = String(data: output, encoding: .utf8) else {
            return mask
        }
        return string
    }

    /// Recursively redacts values according to the caller's display boundary.
    private static func redact(_ value: Any, policy: Policy) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return Dictionary(uniqueKeysWithValues: dictionary.map { key, value in
                switch policy {
                case .credentialArtifact:
                    (key, isSensitive(key) ? mask : redact(value, policy: policy))
                case .backupPreview:
                    (key, redact(value, policy: policy))
                }
            })
        case let array as [Any]:
            return array.map { redact($0, policy: policy) }
        default:
            return policy == .backupPreview ? mask : value
        }
    }

    private static func isSensitive(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }
}
