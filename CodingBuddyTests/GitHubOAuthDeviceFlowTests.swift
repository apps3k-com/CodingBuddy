//
//  GitHubOAuthDeviceFlowTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Deterministic protocol and validation tests for GitHub App device-flow authentication.
struct GitHubOAuthDeviceFlowTests {
    /// Verifies device authorization validates GitHub's URL and submits only the public client ID.
    @Test func requestsDeviceAuthorizationWithPinnedGitHubEndpoint() async throws {
        let transport = OAuthRecordingTransport(responses: [
            .json(#"{"device_code":"device-secret","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#),
        ])
        let client = makeClient(transport: transport)

        let authorization = try await client.requestAuthorization()

        #expect(authorization.userCode == "ABCD-EFGH")
        #expect(authorization.verificationURL.absoluteString == "https://github.com/login/device")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://github.com/login/device/code")
        #expect(request.httpMethod == "POST")
        #expect(String(data: try #require(request.httpBody), encoding: .utf8) == "client_id=Iv1TestClient")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    /// Verifies untrusted verification URLs never escape the pinned GitHub origin.
    @Test func rejectsUntrustedVerificationURL() async {
        let transport = OAuthRecordingTransport(responses: [
            .json(#"{"device_code":"device-secret","user_code":"ABCD-EFGH","verification_uri":"https://example.com/login/device","expires_in":900,"interval":5}"#),
        ])

        await #expect(throws: GitHubOAuthDeviceFlowError.invalidResponse) {
            try await makeClient(transport: transport).requestAuthorization()
        }
    }

    /// Verifies pending and slowdown responses adjust polling without real sleeps.
    @Test func honorsPendingAndSlowDownPollingIntervals() async throws {
        let clock = OAuthTestClock(date: Date(timeIntervalSince1970: 1_000))
        let transport = OAuthRecordingTransport(responses: [
            .json(#"{"error":"authorization_pending"}"#),
            .json(#"{"error":"slow_down"}"#),
            .json(#"{"access_token":"access-secret","token_type":"bearer","expires_in":28800,"refresh_token":"refresh-secret","refresh_token_expires_in":15552000}"#),
        ])
        let client = makeClient(transport: transport, clock: clock)
        let authorization = GitHubDeviceAuthorization(
            deviceCode: "device-secret",
            userCode: "ABCD-EFGH",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresAt: clock.current.addingTimeInterval(120),
            pollingInterval: 5
        )

        let credential = try await client.waitForAuthorization(authorization)

        #expect(clock.sleeps == [5, 5, 10])
        #expect(credential.source == .githubAppDeviceFlow)
        #expect(credential.accessToken == "access-secret")
        #expect(credential.refreshToken == "refresh-secret")
        #expect(credential.accessTokenExpiresAt == Date(timeIntervalSince1970: 1_000 + 20 + 28_800))
    }

    /// Verifies polling stops locally when the displayed code expires.
    @Test func stopsPollingAtAuthorizationExpiry() async {
        let clock = OAuthTestClock(date: Date(timeIntervalSince1970: 1_000))
        let transport = OAuthRecordingTransport(responses: [])
        let client = makeClient(transport: transport, clock: clock)
        let authorization = GitHubDeviceAuthorization(
            deviceCode: "device-secret",
            userCode: "ABCD-EFGH",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresAt: clock.current.addingTimeInterval(5),
            pollingInterval: 5
        )

        await #expect(throws: GitHubOAuthDeviceFlowError.expired) {
            try await client.waitForAuthorization(authorization)
        }
        #expect(transport.requests.isEmpty)
    }

    /// Verifies GitHub's explicit denial is represented without leaking server details.
    @Test func reportsAccessDenied() async {
        let clock = OAuthTestClock(date: Date(timeIntervalSince1970: 1_000))
        let transport = OAuthRecordingTransport(responses: [.json(#"{"error":"access_denied"}"#)])
        let authorization = GitHubDeviceAuthorization(
            deviceCode: "device-secret",
            userCode: "ABCD-EFGH",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresAt: clock.current.addingTimeInterval(30),
            pollingInterval: 1
        )

        await #expect(throws: GitHubOAuthDeviceFlowError.accessDenied) {
            try await makeClient(transport: transport, clock: clock).waitForAuthorization(authorization)
        }
    }

    /// Verifies a refresh rotates both tokens using no client secret.
    @Test func refreshesCredentialWithoutClientSecret() async throws {
        let clock = OAuthTestClock(date: Date(timeIntervalSince1970: 1_000))
        let transport = OAuthRecordingTransport(responses: [
            .json(#"{"access_token":"new-access","token_type":"bearer","expires_in":28800,"refresh_token":"new-refresh","refresh_token_expires_in":15552000}"#),
        ])
        let existing = GitHubCredential(
            source: .githubAppDeviceFlow,
            accessToken: "old-access",
            refreshToken: "old-refresh",
            accessTokenExpiresAt: clock.current,
            refreshTokenExpiresAt: clock.current.addingTimeInterval(100)
        )

        let refreshed = try await makeClient(transport: transport, clock: clock).refresh(existing)

        #expect(refreshed.accessToken == "new-access")
        #expect(refreshed.refreshToken == "new-refresh")
        let body = String(data: try #require(transport.requests.first?.httpBody), encoding: .utf8)
        #expect(body?.contains("client_id=Iv1TestClient") == true)
        #expect(body?.contains("grant_type=refresh_token") == true)
        #expect(body?.contains("refresh_token=old-refresh") == true)
        #expect(body?.contains("client_secret") == false)
    }

    /// Verifies oversized OAuth responses fail before decoding.
    @Test func rejectsOversizedResponse() async {
        let transport = OAuthRecordingTransport(responses: [
            .response(Data(repeating: 0x41, count: 65_537), statusCode: 200),
        ])

        await #expect(throws: GitHubOAuthDeviceFlowError.responseTooLarge) {
            try await makeClient(transport: transport).requestAuthorization()
        }
    }

    /// Creates a production-shaped client with deterministic test boundaries.
    private func makeClient(
        transport: OAuthRecordingTransport,
        clock: OAuthTestClock = OAuthTestClock(date: Date(timeIntervalSince1970: 1_000))
    ) -> GitHubOAuthDeviceFlowClient {
        GitHubOAuthDeviceFlowClient(
            configuration: GitHubOAuthConfiguration(
                clientID: "Iv1TestClient",
                deviceCodeEndpoint: URL(string: "https://github.com/login/device/code")!,
                accessTokenEndpoint: URL(string: "https://github.com/login/oauth/access_token")!
            ),
            transport: transport,
            now: { clock.current },
            sleep: { duration in clock.advance(by: duration) }
        )
    }
}

/// Thread-safe clock that turns cooperative sleeps into deterministic time advances.
private final class OAuthTestClock: @unchecked Sendable {
    /// Lock protecting date and sleep history.
    private let lock = NSLock()
    /// Mutable test date.
    private var date: Date
    /// Recorded sleep intervals in seconds.
    private var recordedSleeps: [TimeInterval] = []

    /// Creates a clock at a fixed date.
    init(date: Date) {
        self.date = date
    }

    /// Current deterministic date.
    var current: Date {
        lock.withLock { date }
    }

    /// Sleep intervals observed so far.
    var sleeps: [TimeInterval] {
        lock.withLock { recordedSleeps }
    }

    /// Advances time by a Swift duration and records the interval.
    func advance(by duration: Duration) {
        let components = duration.components
        let seconds = TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        lock.withLock {
            recordedSleeps.append(seconds)
            date.addTimeInterval(seconds)
        }
    }
}

/// Thread-safe queued OAuth transport that records every request.
private final class OAuthRecordingTransport: GitHubTransport, @unchecked Sendable {
    /// One deterministic HTTP result.
    enum Response {
        /// JSON response with UTF-8 encoding.
        case json(String)
        /// Arbitrary response body and status.
        case response(Data, statusCode: Int)
    }

    /// Lock protecting queued responses and recorded requests.
    private let lock = NSLock()
    /// Responses returned in FIFO order.
    private var responses: [Response]
    /// Requests received by the transport.
    private var recordedRequests: [URLRequest] = []

    /// Creates a transport from queued responses.
    init(responses: [Response]) {
        self.responses = responses
    }

    /// Requests recorded so far.
    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    /// Records a request and returns the next queued response.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = try lock.withLock { () throws -> Response in
            recordedRequests.append(request)
            guard !responses.isEmpty else { throw URLError(.cancelled) }
            return responses.removeFirst()
        }
        let data: Data
        let statusCode: Int
        switch response {
        case .json(let json):
            data = Data(json.utf8)
            statusCode = 200
        case .response(let body, let code):
            data = body
            statusCode = code
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(data.count)]
        )!
        return (data, httpResponse)
    }
}
