//
//  GitHubTokenStore.swift
//  CodingBuddy
//

import Foundation
import Security

/// Minimal secret store used by the Agent PR Monitor.
nonisolated protocol GitHubTokenStore: Sendable {
    /// Returns the saved GitHub token, or nil when setup has not happened.
    func loadToken() throws -> String?

    /// Saves or replaces the GitHub token.
    func saveToken(_ token: String) throws

    /// Removes the saved GitHub token if present.
    func deleteToken() throws

    /// Returns the complete saved credential when the backend supports rotating OAuth tokens.
    func loadCredential() throws -> GitHubCredential?

    /// Saves an OAuth or PAT credential as one logical Keychain value.
    func saveCredential(_ credential: GitHubCredential) throws
}

extension GitHubTokenStore {
    /// Compatibility adapter for existing PAT-only test doubles and stores.
    nonisolated func loadCredential() throws -> GitHubCredential? {
        try loadToken().map(GitHubCredential.personalAccessToken)
    }

    /// Compatibility adapter that persists only the access token in PAT-only stores.
    nonisolated func saveCredential(_ credential: GitHubCredential) throws {
        try saveToken(credential.accessToken)
    }
}

/// Keychain-specific failures that never include the raw token value.
nonisolated enum GitHubTokenStoreError: LocalizedError, Equatable, Sendable {
    /// Keychain returned an OSStatus that CodingBuddy cannot recover from.
    case keychain(status: OSStatus)
    /// Keychain data existed but was not valid UTF-8 token text.
    case invalidData

    /// Localized safe error text for UI surfaces.
    var errorDescription: String? {
        switch self {
        case .keychain:
            String(localized: "CodingBuddy could not access the saved GitHub token in Keychain.")
        case .invalidData:
            String(localized: "The saved GitHub token could not be read.")
        }
    }
}

/// Security.framework-backed token store for the GitHub fine-grained PAT.
nonisolated final class KeychainGitHubTokenStore: GitHubTokenStore, @unchecked Sendable {
    /// Keychain service used for CodingBuddy GitHub secrets.
    private let service: String
    /// Account key for the single github.com token used by v1.
    private let account: String

    /// Creates a Keychain token store for GitHub.com.
    init(service: String = "apps3k.CodingBuddy.github", account: String = "github.com") {
        self.service = service
        self.account = account
    }

    /// Returns the token from Keychain without exposing it anywhere else.
    func loadToken() throws -> String? {
        try loadCredential()?.accessToken
    }

    /// Loads versioned credential metadata and migrates legacy raw PAT values in place on the next save.
    func loadCredential() throws -> GitHubCredential? {
        guard let data = try loadData() else { return nil }
        return try GitHubCredentialCodec.decode(data)
    }

    /// Returns raw Keychain bytes without decoding or logging the secret-bearing value.
    private func loadData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw GitHubTokenStoreError.keychain(status: status)
        }
        guard let data = item as? Data else {
            throw GitHubTokenStoreError.invalidData
        }
        return data
    }

    /// Saves a replacement token as a generic password item.
    func saveToken(_ token: String) throws {
        try saveCredential(.personalAccessToken(token))
    }

    /// Saves the complete credential in one versioned generic-password value.
    func saveCredential(_ credential: GitHubCredential) throws {
        let data = try GitHubCredentialCodec.encode(credential)
        try saveData(data)
    }

    /// Updates or creates the single Keychain item atomically from the caller's perspective.
    private func saveData(_ data: Data) throws {
        var query = baseQuery()

        let updateStatus = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ] as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw GitHubTokenStoreError.keychain(status: updateStatus)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GitHubTokenStoreError.keychain(status: addStatus)
        }
    }

    /// Deletes the token item from Keychain and ignores missing-item state.
    func deleteToken() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubTokenStoreError.keychain(status: status)
        }
    }

    /// Base Keychain query shared by load, save, and delete operations.
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Versioned secret-bearing payload stored as one Keychain item.
private nonisolated struct CredentialEnvelope: Codable {
    /// Current persisted representation version.
    static let currentVersion = 1
    /// Representation version used for fail-closed decoding.
    let version: Int
    /// Complete PAT or rotating GitHub App credential.
    let credential: GitHubCredential
}

/// Pure versioned codec separating credential validation from Keychain side effects.
nonisolated enum GitHubCredentialCodec {
    /// Encodes one complete credential into the current envelope version.
    static func encode(_ credential: GitHubCredential) throws -> Data {
        guard !credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubTokenStoreError.invalidData
        }
        do {
            return try JSONEncoder().encode(
                CredentialEnvelope(version: CredentialEnvelope.currentVersion, credential: credential)
            )
        } catch {
            throw GitHubTokenStoreError.invalidData
        }
    }

    /// Decodes the current envelope or migrates one non-JSON legacy raw PAT.
    static func decode(_ data: Data) throws -> GitHubCredential {
        if let envelope = try? JSONDecoder().decode(CredentialEnvelope.self, from: data),
           envelope.version == CredentialEnvelope.currentVersion,
           !envelope.credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envelope.credential
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitHubTokenStoreError.invalidData
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.first != "{" else {
            throw GitHubTokenStoreError.invalidData
        }
        return .personalAccessToken(trimmed)
    }
}
