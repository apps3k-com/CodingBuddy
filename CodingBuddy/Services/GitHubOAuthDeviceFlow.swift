//
//  GitHubOAuthDeviceFlow.swift
//  CodingBuddy
//

import Foundation

/// Token-safe failures emitted by the GitHub App device authorization flow.
nonisolated enum GitHubOAuthDeviceFlowError: LocalizedError, Equatable, Sendable {
    /// The release build does not contain a valid public GitHub App client ID.
    case missingConfiguration
    /// GitHub returned a response larger than the bounded OAuth payload limit.
    case responseTooLarge
    /// GitHub returned malformed or semantically invalid OAuth data.
    case invalidResponse
    /// GitHub rejected the configured public client ID or disabled device flow.
    case invalidApplication
    /// The user denied the authorization request.
    case accessDenied
    /// The displayed device code expired before authorization completed.
    case expired
    /// A refresh token is absent, expired, or rejected and a new login is required.
    case reauthenticationRequired
    /// GitHub is unavailable or the network request failed.
    case networkUnavailable
    /// GitHub returned an unexpected HTTP status.
    case server(statusCode: Int)

    /// Localized explanation that never includes OAuth codes or tokens.
    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            String(localized: "This CodingBuddy build is not configured for GitHub App sign-in.")
        case .responseTooLarge, .invalidResponse:
            String(localized: "GitHub returned an invalid sign-in response.")
        case .invalidApplication:
            String(localized: "GitHub App sign-in is unavailable for this CodingBuddy build.")
        case .accessDenied:
            String(localized: "GitHub sign-in was canceled.")
        case .expired:
            String(localized: "The GitHub sign-in code expired. Start again to request a new code.")
        case .reauthenticationRequired:
            String(localized: "GitHub authorization expired. Sign in again to continue.")
        case .networkUnavailable:
            String(localized: "GitHub is unreachable. Check your network connection and try again.")
        case .server(let statusCode):
            String(format: String(localized: "GitHub returned HTTP %lld."), Int64(statusCode))
        }
    }
}

/// Native OAuth 2.0 device-flow client for the CodingBuddy GitHub App.
nonisolated struct GitHubOAuthDeviceFlowClient: Sendable {
    /// OAuth responses are intentionally tiny; larger payloads fail closed.
    private static let maximumResponseBytes = 64 * 1_024
    /// Upper bound for any individual token or device-code field.
    private static let maximumSecretBytes = 8 * 1_024

    /// Public GitHub App configuration.
    let configuration: GitHubOAuthConfiguration
    /// Injectable network boundary shared with GitHub API tests.
    let transport: any GitHubTransport
    /// Injectable wall clock for expiry tests.
    let now: @Sendable () -> Date
    /// Injectable cooperative sleeper for deterministic polling tests.
    let sleep: @Sendable (Duration) async throws -> Void

    /// Creates a device-flow client with production defaults and injectable timing.
    init(
        configuration: GitHubOAuthConfiguration,
        transport: any GitHubTransport = URLSessionGitHubTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    /// Requests a bounded short-lived user code without persisting the device secret.
    func requestAuthorization() async throws -> GitHubDeviceAuthorization {
        let request = formRequest(
            url: configuration.deviceCodeEndpoint,
            values: ["client_id": configuration.clientID]
        )
        let response: DeviceCodeResponse = try await perform(request)
        guard isBoundedSecret(response.deviceCode),
              isBoundedDisplayCode(response.userCode),
              (1...3_600).contains(response.expiresIn),
              (1...60).contains(response.interval),
              let verificationURL = URL(string: response.verificationURI),
              verificationURL.scheme == "https",
              verificationURL.host?.lowercased() == "github.com",
              verificationURL.path == "/login/device" else {
            throw GitHubOAuthDeviceFlowError.invalidResponse
        }
        return GitHubDeviceAuthorization(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURL: verificationURL,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn)),
            pollingInterval: TimeInterval(response.interval)
        )
    }

    /// Polls no faster than GitHub permits and returns the first authorized credential.
    func waitForAuthorization(_ authorization: GitHubDeviceAuthorization) async throws -> GitHubCredential {
        var interval = max(1, authorization.pollingInterval)
        while now() < authorization.expiresAt {
            try Task.checkCancellation()
            try await sleep(.seconds(interval))
            try Task.checkCancellation()
            guard now() < authorization.expiresAt else {
                throw GitHubOAuthDeviceFlowError.expired
            }

            let request = formRequest(
                url: configuration.accessTokenEndpoint,
                values: [
                    "client_id": configuration.clientID,
                    "device_code": authorization.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            )
            let response: TokenResponse = try await perform(request)
            if let credential = try decodedCredential(from: response) {
                return credential
            }
            switch response.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = min(60, max(interval + 5, TimeInterval(response.interval ?? 0)))
            case "expired_token", "token_expired":
                throw GitHubOAuthDeviceFlowError.expired
            case "access_denied":
                throw GitHubOAuthDeviceFlowError.accessDenied
            case "incorrect_client_credentials", "device_flow_disabled":
                throw GitHubOAuthDeviceFlowError.invalidApplication
            default:
                throw GitHubOAuthDeviceFlowError.invalidResponse
            }
        }
        throw GitHubOAuthDeviceFlowError.expired
    }

    /// Rotates an expiring device-flow credential without embedding a client secret.
    func refresh(_ credential: GitHubCredential) async throws -> GitHubCredential {
        let currentDate = now()
        guard credential.canRefresh(at: currentDate), let refreshToken = credential.refreshToken else {
            throw GitHubOAuthDeviceFlowError.reauthenticationRequired
        }
        let request = formRequest(
            url: configuration.accessTokenEndpoint,
            values: [
                "client_id": configuration.clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ]
        )
        let response: TokenResponse = try await perform(request)
        if let refreshed = try decodedCredential(from: response) {
            return refreshed
        }
        if response.error == "bad_refresh_token" || response.error == "expired_token" {
            throw GitHubOAuthDeviceFlowError.reauthenticationRequired
        }
        if response.error == "incorrect_client_credentials" {
            throw GitHubOAuthDeviceFlowError.invalidApplication
        }
        throw GitHubOAuthDeviceFlowError.invalidResponse
    }

    /// Converts a successful token payload into absolute, bounded expiry metadata.
    private func decodedCredential(from response: TokenResponse) throws -> GitHubCredential? {
        guard let accessToken = response.accessToken else { return nil }
        guard response.error == nil,
              isBoundedSecret(accessToken),
              response.tokenType?.lowercased() == "bearer",
              response.refreshToken.map(isBoundedSecret) ?? true,
              response.expiresIn.map({ (1...31_536_000).contains($0) }) ?? true,
              response.refreshTokenExpiresIn.map({ (1...31_536_000).contains($0) }) ?? true else {
            throw GitHubOAuthDeviceFlowError.invalidResponse
        }
        let currentDate = now()
        return GitHubCredential(
            source: .githubAppDeviceFlow,
            accessToken: accessToken,
            refreshToken: response.refreshToken,
            accessTokenExpiresAt: response.expiresIn.map {
                currentDate.addingTimeInterval(TimeInterval($0))
            },
            refreshTokenExpiresAt: response.refreshTokenExpiresIn.map {
                currentDate.addingTimeInterval(TimeInterval($0))
            }
        )
    }

    /// Sends and decodes one bounded OAuth request with token-safe error mapping.
    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GitHubOAuthDeviceFlowError.networkUnavailable
        }
        guard (200...299).contains(response.statusCode) else {
            throw GitHubOAuthDeviceFlowError.server(statusCode: response.statusCode)
        }
        guard data.count <= Self.maximumResponseBytes,
              response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
            throw GitHubOAuthDeviceFlowError.responseTooLarge
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubOAuthDeviceFlowError.invalidResponse
        }
    }

    /// Creates a form-encoded POST request accepted by GitHub's OAuth endpoints.
    private func formRequest(url: URL, values: [String: String]) -> URLRequest {
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("CodingBuddy", forHTTPHeaderField: "User-Agent")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return request
    }

    /// Validates opaque secrets without interpreting or logging their values.
    private func isBoundedSecret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= Self.maximumSecretBytes
    }

    /// Validates the short human-facing device code separately from opaque secrets.
    private func isBoundedDisplayCode(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
    }
}

/// GitHub device-code response decoded without retaining unknown server fields.
private nonisolated struct DeviceCodeResponse: Decodable {
    /// Opaque device verification code.
    let deviceCode: String
    /// Human-readable browser code.
    let userCode: String
    /// Browser verification URL.
    let verificationURI: String
    /// Authorization lifetime in seconds.
    let expiresIn: Int
    /// Minimum polling interval in seconds.
    let interval: Int

    /// GitHub device-code payload keys use snake case.
    private enum CodingKeys: String, CodingKey {
        /// Opaque device secret consumed only by the polling request.
        case deviceCode = "device_code"
        /// Short code displayed to the user.
        case userCode = "user_code"
        /// Browser destination for device authorization.
        case verificationURI = "verification_uri"
        /// Server-declared device authorization lifetime.
        case expiresIn = "expires_in"
        /// Server-declared minimum polling interval.
        case interval
    }
}

/// Successful or pending GitHub OAuth token response.
private nonisolated struct TokenResponse: Decodable {
    /// Issued access token on success.
    let accessToken: String?
    /// Token type, expected to be bearer.
    let tokenType: String?
    /// Access-token lifetime in seconds.
    let expiresIn: Int?
    /// Rotating refresh token when expiration is enabled.
    let refreshToken: String?
    /// Refresh-token lifetime in seconds.
    let refreshTokenExpiresIn: Int?
    /// OAuth error code while authorization is pending or failed.
    let error: String?
    /// Updated polling interval returned with `slow_down`.
    let interval: Int?

    /// GitHub token payload keys use snake case.
    private enum CodingKeys: String, CodingKey {
        /// Issued bearer token.
        case accessToken = "access_token"
        /// Provider token-type assertion.
        case tokenType = "token_type"
        /// Issued access-token lifetime.
        case expiresIn = "expires_in"
        /// Rotating refresh token.
        case refreshToken = "refresh_token"
        /// Issued refresh-token lifetime.
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        /// OAuth protocol error while polling or refreshing.
        case error
        /// Optional provider polling-interval update.
        case interval
    }
}
