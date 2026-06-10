//
//  TokenStatusBadge.swift
//  CodingBuddy
//

import SwiftUI

/// Token lifecycle badge shared by every credential section.
struct TokenStatusBadge: View {
    let status: TokenStatus

    var body: some View {
        switch status {
        case .active(let expiry):
            VStack(alignment: .leading, spacing: 1) {
                Text("Active")
                    .foregroundStyle(.green)
                if let expiry {
                    Text("expires \(expiry, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .expired:
            Text("Access token expired")
                .foregroundStyle(.orange)
                .help("The server may refresh the session automatically; reset the entry if it is stuck.")
        case .incomplete:
            Text("Incomplete (no tokens)")
                .foregroundStyle(.secondary)
        }
    }
}
