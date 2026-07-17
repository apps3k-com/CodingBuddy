//
//  GitHubCredentialCoordinatorTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Tests the capability boundary and rotating credential lifecycle.
struct GitHubCredentialCoordinatorTests {
    /// Verifies legacy PATs remain useful for reads while all writes fail closed.
    @Test func legacyPATIsReadOnly() async throws {
        let store = MemoryCredentialStore(credential: .personalAccessToken("legacy-pat"))
        let coordinator = GitHubCredentialCoordinator(tokenStore: store, oauthClient: nil)

        let readCredential = try await coordinator.credential(for: .readOnly)
        #expect(readCredential.accessToken == "legacy-pat")
        await #expect(throws: GitHubCredentialCoordinatorError.githubAppRequired) {
            try await coordinator.credential(for: .write)
        }
    }

    /// Verifies a valid GitHub App credential authorizes both reads and writes.
    @Test func githubAppCredentialAuthorizesWrites() async throws {
        let credential = GitHubCredential(
            source: .githubAppDeviceFlow,
            accessToken: "app-token",
            refreshToken: "refresh-token",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 10_000),
            refreshTokenExpiresAt: Date(timeIntervalSince1970: 20_000)
        )
        let coordinator = GitHubCredentialCoordinator(
            tokenStore: MemoryCredentialStore(credential: credential),
            oauthClient: nil
        )

        let result = try await coordinator.credential(
            for: .write,
            at: Date(timeIntervalSince1970: 1_000)
        )
        #expect(result.source == .githubAppDeviceFlow)
        #expect(result.accessToken == "app-token")
    }

    /// Verifies expired access tokens are rotated and the complete replacement is persisted.
    @Test func refreshesAndPersistsExpiredGitHubAppCredential() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let oldCredential = GitHubCredential(
            source: .githubAppDeviceFlow,
            accessToken: "old-access",
            refreshToken: "old-refresh",
            accessTokenExpiresAt: now,
            refreshTokenExpiresAt: now.addingTimeInterval(1_000)
        )
        let store = MemoryCredentialStore(credential: oldCredential)
        let transport = CoordinatorOAuthTransport()
        let client = GitHubOAuthDeviceFlowClient(
            configuration: GitHubOAuthConfiguration(
                clientID: "Iv1TestClient",
                deviceCodeEndpoint: URL(string: "https://github.com/login/device/code")!,
                accessTokenEndpoint: URL(string: "https://github.com/login/oauth/access_token")!
            ),
            transport: transport,
            now: { now }
        )
        let coordinator = GitHubCredentialCoordinator(tokenStore: store, oauthClient: client)

        let refreshed = try await coordinator.credential(for: .write, at: now)

        #expect(refreshed.accessToken == "new-access")
        #expect(refreshed.refreshToken == "new-refresh")
        #expect(store.credential?.accessToken == "new-access")
        #expect(transport.requestCount == 1)
    }

    /// Verifies every concurrent caller shares one refresh and receives its persisted result.
    @Test func concurrentCallersShareOneValidatedRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = MemoryCredentialStore(credential: expiringCredential(at: now))
        let transport = CoordinatorOAuthTransport()
        let client = GitHubOAuthDeviceFlowClient(
            configuration: GitHubOAuthConfiguration(
                clientID: "Iv1TestClient",
                deviceCodeEndpoint: URL(string: "https://github.com/login/device/code")!,
                accessTokenEndpoint: URL(string: "https://github.com/login/oauth/access_token")!
            ),
            transport: transport,
            now: { now }
        )
        let coordinator = GitHubCredentialCoordinator(tokenStore: store, oauthClient: client)

        async let first = coordinator.credential(for: .write, at: now)
        async let second = coordinator.credential(for: .write, at: now)
        let results = try await [first, second]

        #expect(results.allSatisfy { $0.accessToken == "new-access" })
        #expect(store.credential?.accessToken == "new-access")
        #expect(transport.requestCount == 1)
    }

    /// Verifies missing Keychain state never falls through to a network request.
    @Test func missingCredentialFailsLocally() async {
        let coordinator = GitHubCredentialCoordinator(
            tokenStore: MemoryCredentialStore(credential: nil),
            oauthClient: nil
        )

        await #expect(throws: GitHubCredentialCoordinatorError.missingCredential) {
            try await coordinator.credential(for: .readOnly)
        }
    }

    /// Verifies deletion wins over a suspended refresh and the old result is never restored.
    @Test func deleteInvalidatesSuspendedRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = MemoryCredentialStore(credential: expiringCredential(at: now))
        let transport = SuspendingCoordinatorOAuthTransport()
        let coordinator = makeCoordinator(store: store, transport: transport, now: now)
        let refresh = Task { try await coordinator.credential(for: .write, at: now) }
        await transport.waitUntilRequested()

        try await coordinator.deleteCredential()
        transport.succeed()

        await #expect(throws: CancellationError.self) { try await refresh.value }
        #expect(store.credential == nil)
    }

    /// Verifies a PAT replacement wins over a suspended refresh result.
    @Test func replacementInvalidatesSuspendedRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = MemoryCredentialStore(credential: expiringCredential(at: now))
        let transport = SuspendingCoordinatorOAuthTransport()
        let coordinator = makeCoordinator(store: store, transport: transport, now: now)
        let refresh = Task { try await coordinator.credential(for: .write, at: now) }
        await transport.waitUntilRequested()

        try await coordinator.savePersonalAccessToken("replacement-pat")
        transport.succeed()

        await #expect(throws: CancellationError.self) { try await refresh.value }
        #expect(store.credential == .personalAccessToken("replacement-pat"))
    }

    /// Verifies sign-out wins over a suspended device-flow completion.
    @Test func deleteInvalidatesSuspendedDeviceFlowCompletion() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = MemoryCredentialStore(credential: nil)
        let transport = SuspendingCoordinatorOAuthTransport()
        let coordinator = makeCoordinator(store: store, transport: transport, now: now)
        let authorization = GitHubDeviceAuthorization(
            deviceCode: "device-code",
            userCode: "ABCD-EFGH",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresAt: now.addingTimeInterval(120),
            pollingInterval: 1
        )
        let completion = Task {
            try await coordinator.completeDeviceAuthorization(authorization)
        }
        await transport.waitUntilRequested()

        try await coordinator.deleteCredential()
        transport.succeed()

        await #expect(throws: CancellationError.self) { try await completion.value }
        #expect(store.credential == nil)
    }

    /// Creates one expiring credential for refresh-race tests.
    private func expiringCredential(at date: Date) -> GitHubCredential {
        GitHubCredential(
            source: .githubAppDeviceFlow,
            accessToken: "old-access",
            refreshToken: "old-refresh",
            accessTokenExpiresAt: date,
            refreshTokenExpiresAt: date.addingTimeInterval(1_000)
        )
    }

    /// Creates a coordinator using a transport whose response is test-controlled.
    private func makeCoordinator(
        store: MemoryCredentialStore,
        transport: SuspendingCoordinatorOAuthTransport,
        now: Date
    ) -> GitHubCredentialCoordinator {
        let client = GitHubOAuthDeviceFlowClient(
            configuration: GitHubOAuthConfiguration(
                clientID: "Iv1TestClient",
                deviceCodeEndpoint: URL(string: "https://github.com/login/device/code")!,
                accessTokenEndpoint: URL(string: "https://github.com/login/oauth/access_token")!
            ),
            transport: transport,
            now: { now },
            sleep: { _ in }
        )
        return GitHubCredentialCoordinator(tokenStore: store, oauthClient: client)
    }
}

/// Thread-safe credential store preserving complete OAuth metadata in tests.
private final class MemoryCredentialStore: GitHubTokenStore, @unchecked Sendable {
    /// Lock protecting the credential.
    private let lock = NSLock()
    /// Mutable stored credential.
    private var storedCredential: GitHubCredential?

    /// Creates a store with optional state.
    init(credential: GitHubCredential?) {
        storedCredential = credential
    }

    /// Current complete credential.
    var credential: GitHubCredential? {
        lock.withLock { storedCredential }
    }

    /// Returns only the access token for legacy clients.
    func loadToken() throws -> String? {
        lock.withLock { storedCredential?.accessToken }
    }

    /// Saves a legacy PAT.
    func saveToken(_ token: String) throws {
        lock.withLock { storedCredential = .personalAccessToken(token) }
    }

    /// Deletes the credential.
    func deleteToken() throws {
        lock.withLock { storedCredential = nil }
    }

    /// Returns the complete credential.
    func loadCredential() throws -> GitHubCredential? {
        lock.withLock { storedCredential }
    }

    /// Saves the complete credential.
    func saveCredential(_ credential: GitHubCredential) throws {
        lock.withLock { storedCredential = credential }
    }
}

/// OAuth transport returning one deterministic rotated credential.
private final class CoordinatorOAuthTransport: GitHubTransport, @unchecked Sendable {
    /// Lock protecting request count.
    private let lock = NSLock()
    /// Number of refresh calls.
    private var count = 0

    /// Current request count.
    var requestCount: Int {
        lock.withLock { count }
    }

    /// Returns a successful token rotation response.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { count += 1 }
        let data = Data(#"{"access_token":"new-access","token_type":"bearer","expires_in":28800,"refresh_token":"new-refresh","refresh_token_expires_in":15552000}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(data.count)]
        )!
        return (data, response)
    }
}

/// OAuth transport that exposes the exact suspension boundary used by race tests.
private final class SuspendingCoordinatorOAuthTransport: GitHubTransport, @unchecked Sendable {
    /// Lock protecting request state and the pending continuation.
    private let lock = NSLock()
    /// Whether a request reached the transport.
    private var requested = false
    /// Suspended network continuation completed by the test.
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

    /// Suspends the request until `succeed()` provides a deterministic response.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                requested = true
                self.continuation = continuation
            }
        }
    }

    /// Waits cooperatively until the production code reaches network I/O.
    func waitUntilRequested() async {
        while !lock.withLock({ requested }) {
            await Task.yield()
        }
    }

    /// Completes the suspended request with one valid rotating credential.
    func succeed() {
        let continuation = lock.withLock { () -> CheckedContinuation<(Data, HTTPURLResponse), Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        let data = Data(#"{"access_token":"new-access","token_type":"bearer","expires_in":28800,"refresh_token":"new-refresh","refresh_token_expires_in":15552000}"#.utf8)
        let response = HTTPURLResponse(
            url: URL(string: "https://github.com/login/oauth/access_token")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(data.count)]
        )!
        continuation?.resume(returning: (data, response))
    }
}
