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
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw GitHubTokenStoreError.keychain(status: status)
        }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw GitHubTokenStoreError.invalidData
        }
        return token
    }

    /// Saves a replacement token as a generic password item.
    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
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
