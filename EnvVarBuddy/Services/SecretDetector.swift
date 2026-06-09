//
//  SecretDetector.swift
//  EnvVarBuddy
//

import Foundation

/// Heuristic classification of variable names that likely hold credentials.
/// Deliberately conservative-by-inclusion: a false positive only costs one
/// authentication, a false negative would show a secret in plain text.
nonisolated enum SecretDetector {

    private static let sensitiveSegments: Set<String> = [
        "TOKEN", "SECRET", "SECRETS", "PASSWORD", "PASSWD", "PASS", "PWD",
        "KEY", "APIKEY", "CREDENTIAL", "CREDENTIALS", "AUTH", "BEARER",
        "PRIVATE", "CERT", "SALT", "DSN",
    ]

    private static let sensitiveSuffixes = ["TOKEN", "KEY", "SECRET", "PASSWORD"]

    /// True when the name looks like it holds a secret, judged segment-wise
    /// on the `_`-separated parts (e.g. `GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`,
    /// `NPM_AUTH`, `MY_APIKEY`).
    static func isSensitive(name: String) -> Bool {
        name.uppercased().split(separator: "_").contains { segment in
            let part = String(segment)
            return sensitiveSegments.contains(part)
                || sensitiveSuffixes.contains { part.hasSuffix($0) && part != $0 }
        }
    }
}
