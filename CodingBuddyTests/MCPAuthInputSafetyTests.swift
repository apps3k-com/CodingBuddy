//
//  MCPAuthInputSafetyTests.swift
//  CodingBuddyTests
//

import Darwin
import Foundation
import Testing
@testable import CodingBuddy

/// Adversarial coverage for credential preview and scanner input boundaries.
@MainActor
@Suite(.serialized)
struct MCPAuthInputSafetyTests {
    /// Creates an isolated directory and removes it after the current test.
    private func makeTempDir() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPAuthInputSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Creates one versioned credential-cache directory under an isolated root.
    private func makeCredentialDirectory(in temporaryDirectory: URL) throws -> (root: URL, version: URL) {
        let root = temporaryDirectory.appendingPathComponent(".mcp-auth", isDirectory: true)
        let version = root.appendingPathComponent("mcp-remote-9.9.9", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        return (root, version)
    }

    /// Returns a syntactically valid cache filename for one artifact suffix.
    private func credentialFileName(suffix: String = "tokens.json") -> String {
        "\(String(repeating: "ab", count: 16))_\(suffix)"
    }

    /// Verifies escaped quotes cannot expose the suffix of a sensitive JSON value.
    @Test func redactorMasksEntireEscapedJSONStringValue() throws {
        let secret = "SECRET\\\"}, \\\"injected\\\": \\\"ESCAPED_SUFFIX"
        let input = try JSONSerialization.data(withJSONObject: [
            "access_token": secret,
            "scope": "visible",
        ], options: [.sortedKeys])
        let text = try #require(String(data: input, encoding: .utf8))

        let preview = MCPAuthRedactor.maskedPreview(text: text, isJSON: true)

        #expect(!preview.contains("SECRET"))
        #expect(!preview.contains("ESCAPED_SUFFIX"))
        #expect(preview.contains("visible"))
    }

    /// Verifies every JSON value type under a sensitive key is replaced as one value.
    @Test func redactorMasksSensitiveObjectsArraysAndScalars() throws {
        let input = """
        {
          "client_secret": {"nested": "OBJECT_SECRET"},
          "access_tokens": ["ARRAY_SECRET", {"nested": 1}],
          "api_key": 123,
          "password": true,
          "code_verifier": null,
          "nested": {"refresh_token": false, "name": "visible"},
          "scope": "read"
        }
        """

        let preview = MCPAuthRedactor.maskedPreview(text: input, isJSON: true)
        let data = try #require(preview.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nested = try #require(object["nested"] as? [String: Any])

        #expect(object["client_secret"] as? String == "••••••••")
        #expect(object["access_tokens"] as? String == "••••••••")
        #expect(object["api_key"] as? String == "••••••••")
        #expect(object["password"] as? String == "••••••••")
        #expect(object["code_verifier"] as? String == "••••••••")
        #expect(nested["refresh_token"] as? String == "••••••••")
        #expect(nested["name"] as? String == "visible")
        #expect(object["scope"] as? String == "read")
        #expect(!preview.contains("OBJECT_SECRET"))
        #expect(!preview.contains("ARRAY_SECRET"))
    }

    /// Verifies malformed credential-bearing JSON is masked as a whole document.
    @Test func redactorMasksMalformedJSONAsWholeInput() {
        let malformed = #"{"access_token":"SECRET\"suffix", "scope":"LEAK""#

        let preview = MCPAuthRedactor.maskedPreview(text: malformed, isJSON: true)

        #expect(preview == "••••••••")
        #expect(!preview.contains("SECRET"))
        #expect(!preview.contains("LEAK"))
    }

    /// Verifies credential artifacts above the documented 1 MiB ceiling are skipped.
    @Test func scannerRejectsOversizedCredentialFile() throws {
        let temporaryDirectory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixture = try makeCredentialDirectory(in: temporaryDirectory)
        let oversized = Data(
            repeating: 0x41,
            count: MCPAuthScanner.maximumCredentialFileSize + 1
        )
        try oversized.write(to: fixture.version.appendingPathComponent(credentialFileName()))

        let result = MCPAuthScanner.scanResult(root: fixture.root, knownServerURLs: [])

        let entry = try #require(result.entries.first)
        #expect(entry.files.map(\.kind) == [.tokens])
        #expect(entry.files.allSatisfy { !$0.isSafelyReadable })
        #expect(entry.scope == nil)
        #expect(entry.accessTokenExpiry == nil)
        #expect(result.refusals == [.credentialArtifactUnreadable])
    }

    /// Verifies a visible symlink artifact is rejected as scanner metadata input.
    @Test func scannerRejectsSymlinkCredentialContents() throws {
        let temporaryDirectory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixture = try makeCredentialDirectory(in: temporaryDirectory)
        let external = temporaryDirectory.appendingPathComponent("external.json")
        try #"{"scope":"must-not-be-read"}"#.write(
            to: external,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.version.appendingPathComponent(credentialFileName()),
            withDestinationURL: external
        )

        let result = MCPAuthScanner.scanResult(root: fixture.root, knownServerURLs: [])

        let entry = try #require(result.entries.first)
        #expect(entry.files.map(\.kind) == [.tokens])
        #expect(entry.scope == nil)
        #expect(entry.accessTokenExpiry == nil)
        #expect(result.refusals.isEmpty)
    }

    /// Verifies FIFO and directory artifacts are rejected without attempting a blocking read.
    @Test func scannerRejectsFIFOAndOtherNonRegularInput() throws {
        let temporaryDirectory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixture = try makeCredentialDirectory(in: temporaryDirectory)
        let fifo = fixture.version.appendingPathComponent(credentialFileName())
        guard mkfifo(fifo.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.createDirectory(
            at: fixture.version.appendingPathComponent(credentialFileName(suffix: "client_info.json")),
            withIntermediateDirectories: false
        )

        let result = MCPAuthScanner.scanResult(root: fixture.root, knownServerURLs: [])

        let entry = try #require(result.entries.first)
        #expect(Set(entry.files.map(\.kind)) == Set([.tokens, .clientInfo]))
        #expect(entry.files.allSatisfy { !$0.isSafelyReadable })
        #expect(entry.scope == nil)
        #expect(entry.accessTokenExpiry == nil)
        #expect(result.refusals == [.credentialArtifactUnreadable])
    }

    /// Verifies credential files writable by another account class are skipped.
    @Test func scannerRejectsExternallyWritableCredentialFile() throws {
        let temporaryDirectory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixture = try makeCredentialDirectory(in: temporaryDirectory)
        let file = fixture.version.appendingPathComponent(credentialFileName())
        try #"{"scope":"unsafe"}"#.write(to: file, atomically: true, encoding: .utf8)
        guard chmod(file.path, 0o622) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let result = MCPAuthScanner.scanResult(root: fixture.root, knownServerURLs: [])

        let entry = try #require(result.entries.first)
        #expect(entry.files.map(\.kind) == [.tokens])
        #expect(entry.files.allSatisfy { !$0.isSafelyReadable })
        #expect(entry.scope == nil)
        #expect(entry.accessTokenExpiry == nil)
        #expect(result.refusals == [.credentialArtifactUnreadable])
    }

    /// Verifies version-directory enumeration is bounded before child contents are inspected.
    @Test func scannerRejectsExcessiveVersionDirectoryCount() throws {
        let temporaryDirectory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let root = temporaryDirectory.appendingPathComponent(".mcp-auth", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0...MCPAuthScanner.maximumVersionDirectoryCount {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("mcp-remote-\(index)", isDirectory: true),
                withIntermediateDirectories: false
            )
        }

        let result = MCPAuthScanner.scanResult(root: root, knownServerURLs: [])

        #expect(result.entries.isEmpty)
        #expect(result.refusals == [.versionDirectoryEnumeration])
    }

    /// Verifies many tiny artifacts cannot bypass the scanner's per-file byte ceiling.
    @Test func scannerRejectsExcessiveArtifactCount() throws {
        let temporaryDirectory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixture = try makeCredentialDirectory(in: temporaryDirectory)
        for index in 0...MCPAuthScanner.maximumCredentialArtifactsPerVersion {
            let name = credentialFileName(suffix: "artifact-\(index)")
            try Data().write(to: fixture.version.appendingPathComponent(name))
        }

        let result = MCPAuthScanner.scanResult(root: fixture.root, knownServerURLs: [])

        #expect(result.entries.isEmpty)
        #expect(result.refusals == [.credentialArtifactEnumeration])
    }

    /// Verifies an unsafe cache-root symlink is reported rather than presented as an empty cache.
    @Test func scannerReportsUnsafeRoot() throws {
        let temporaryDirectory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let target = temporaryDirectory.appendingPathComponent("target", isDirectory: true)
        let root = temporaryDirectory.appendingPathComponent(".mcp-auth", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)

        let result = MCPAuthScanner.scanResult(root: root, knownServerURLs: [])

        #expect(result.entries.isEmpty)
        #expect(result.refusals == [.cacheRoot])
    }

    /// Verifies an intermediate symlink cannot redirect root enumeration to an external cache.
    @Test func scannerRejectsIntermediateRootSymlinkWithoutReadingExternalTarget() throws {
        let temporaryDirectory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let externalParent = temporaryDirectory.appendingPathComponent("external", isDirectory: true)
        let externalFixture = try makeCredentialDirectory(in: externalParent)
        let credential = externalFixture.version.appendingPathComponent(credentialFileName())
        try #"{"scope":"must-not-be-read"}"#.write(
            to: credential,
            atomically: true,
            encoding: .utf8
        )
        let marker = externalParent.appendingPathComponent("marker")
        try "external-safe".write(to: marker, atomically: true, encoding: .utf8)

        let configuredParent = temporaryDirectory.appendingPathComponent("configured", isDirectory: true)
        try FileManager.default.createDirectory(at: configuredParent, withIntermediateDirectories: false)
        let redirect = configuredParent.appendingPathComponent("redirect", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: externalParent)
        let configuredRoot = redirect.appendingPathComponent(".mcp-auth", isDirectory: true)

        let result = MCPAuthScanner.scanResult(root: configuredRoot, knownServerURLs: [])

        #expect(result.entries.isEmpty)
        #expect(result.refusals == [.cacheRoot])
        #expect(try String(contentsOf: marker, encoding: .utf8) == "external-safe")
        #expect(try String(contentsOf: credential, encoding: .utf8).contains("must-not-be-read"))
    }

    /// Verifies the narrowly permitted `/var` temporary-directory alias remains usable.
    @Test func scannerAcceptsNormalSystemTemporaryPath() throws {
        let temporaryDirectory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixture = try makeCredentialDirectory(in: temporaryDirectory)
        try #"{"scope":"read"}"#.write(
            to: fixture.version.appendingPathComponent(credentialFileName()),
            atomically: true,
            encoding: .utf8
        )

        let result = MCPAuthScanner.scanResult(root: fixture.root, knownServerURLs: [])

        #expect(result.refusals.isEmpty)
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.scope == "read")
    }
}
