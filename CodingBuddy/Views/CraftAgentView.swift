//
//  CraftAgentView.swift
//  CodingBuddy
//

import SwiftUI

/// Craft Agents section: read-only discovery of `~/.craft-agent/` with token
/// expiry per secret file and reversible resets (Trash). The encrypted
/// credential store is described, never opened.
struct CraftAgentView: View {
    /// Read-mostly store providing safe Craft metadata and reversible reset actions.
    var store: CraftAgentStore

    @State private var pendingSecretReset: CraftAgentStore.SecretFile?
    @State private var confirmEncryptedReset = false

    var body: some View {
        Group {
            if store.directoryExists {
                content
            } else {
                ContentUnavailableView(
                    "No Craft Agents configuration",
                    systemImage: "sparkles",
                    description: Text("~/.craft-agent does not exist — Craft Agents has not been set up on this Mac.")
                )
            }
        }
        .navigationTitle(Text(verbatim: "Craft Agents"))
        .confirmationDialog(
            "Move “\(pendingSecretReset?.fileName ?? "")” to the Trash?",
            isPresented: Binding(
                get: { pendingSecretReset != nil },
                set: { if !$0 { pendingSecretReset = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move Secret File to Trash", role: .destructive) {
                if let secret = pendingSecretReset { store.reset(secret) }
                pendingSecretReset = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next connection will trigger a fresh OAuth login.")
        }
        .confirmationDialog(
            "Move the encrypted credential store to the Trash?",
            isPresented: $confirmEncryptedReset,
            titleVisibility: .visible
        ) {
            Button("Move Credential Store to Trash", role: .destructive) {
                store.resetEncryptedStore()
                confirmEncryptedReset = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every Craft connector will ask you to log in again.")
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var content: some View {
        List {
            if !store.connections.isEmpty {
                Section("LLM connections") {
                    ForEach(store.connections) { connection in
                        HStack {
                            Text(verbatim: connection.name)
                                .fontWeight(.medium)
                            Spacer()
                            Text(verbatim: connection.providerType)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !store.secretFiles.isEmpty {
                Section("Token files") {
                    ForEach(store.secretFiles) { secret in
                        HStack {
                            Text(verbatim: secret.fileName)
                                .monospaced()
                            Spacer()
                            TokenStatusBadge(status: secret.status)
                            Button("Reset…", role: .destructive) {
                                pendingSecretReset = secret
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }

            if let encrypted = store.encryptedStore {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "credentials.enc")
                                .monospaced()
                            Text("Connector credentials, encrypted by Craft — CodingBuddy never opens this file.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(encrypted.byteCount.formatted(.byteCount(style: .file)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let modified = encrypted.modified {
                                Text(modified, format: .relative(presentation: .named))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Button("Reset…", role: .destructive) {
                            confirmEncryptedReset = true
                        }
                        .buttonStyle(.link)
                    }
                } header: {
                    Text("Encrypted credential store")
                }
            }
        }
        .overlay {
            if store.connections.isEmpty, store.secretFiles.isEmpty, store.encryptedStore == nil {
                ContentUnavailableView(
                    "No Craft credentials",
                    systemImage: "sparkles",
                    description: Text("Set up Craft Agents or connect a Craft connector. Credential files will appear here when Craft creates them.")
                )
            }
        }
    }
}
