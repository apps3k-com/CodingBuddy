//
//  CursorStoreTests.swift
//  CodingBuddyTests
//

import Darwin
import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct CursorStoreTests {

    private let fixture = """
    {
      "mcpServers": {
        "shopify": {
          "command": "npx",
          "args": ["-y", "@shopify/dev-mcp@latest"],
          "env": {
            "API_TOKEN": "secret-a",
            "PLAIN": "value"
          }
        },
        "linear": {
          "type": "http",
          "url": "https://mcp.linear.app/mcp"
        }
      }
    }
    """

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingBuddyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeHome(mcpJSON: String? = nil) throws -> URL {
        let home = try makeTempDir()
        let cursor = home.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        if let mcpJSON {
            let url = cursor.appendingPathComponent("mcp.json")
            try mcpJSON.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return home
    }

    private func makeStore(
        home: URL,
        transactionHook: ((SafeFileWriter.TransactionPoint) throws -> Void)? = nil
    ) -> CursorStore {
        CursorStore(
            cursorDirectory: home.appendingPathComponent(".cursor", isDirectory: true),
            backupDirectory: home.appendingPathComponent("Backups"),
            transactionHook: transactionHook
        )
    }

    @Test func loadsServersAndEnvEntries() throws {
        let store = makeStore(home: try makeHome(mcpJSON: fixture))

        #expect(store.loadState == .loaded)
        #expect(store.servers.map(\.name).sorted() == ["linear", "shopify"])
        #expect(store.envEntries.count == 2)
        #expect(store.envEntries.allSatisfy { $0.server == "shopify" })
    }

    @Test func missingFileHasExplicitMissingState() throws {
        let store = makeStore(home: try makeHome())

        #expect(store.loadState == .missing)
        #expect(store.servers.isEmpty)
        #expect(store.envEntries.isEmpty)
    }

    @Test func malformedJSONRefusesAndClearsPreviouslyLoadedValues() throws {
        let home = try makeHome(mcpJSON: fixture)
        let store = makeStore(home: home)
        let target = home.appendingPathComponent(".cursor/mcp.json")
        try Data("{not-json".utf8).write(to: target)

        store.reload()

        #expect(store.loadState == .refused(.malformedJSON))
        #expect(store.servers.isEmpty)
        #expect(store.envEntries.isEmpty)
    }

    @Test func unsupportedJSONStructureIsRefused() throws {
        let store = makeStore(home: try makeHome(mcpJSON: #"{"mcpServers": []}"#))

        #expect(store.loadState == .refused(.unsupportedStructure))
        #expect(store.servers.isEmpty)
        #expect(store.envEntries.isEmpty)
    }

    @Test func invalidUTF8IsRefused() throws {
        let home = try makeHome()
        try Data([0xFF, 0xFE]).write(to: home.appendingPathComponent(".cursor/mcp.json"))

        let store = makeStore(home: home)

        #expect(store.loadState == .refused(.invalidUTF8))
        #expect(store.servers.isEmpty)
        #expect(store.envEntries.isEmpty)
    }

    @Test func finalSymlinkIsRefusedAsUnsafePath() throws {
        let home = try makeHome()
        let external = home.appendingPathComponent("external.json")
        try fixture.write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".cursor/mcp.json"),
            withDestinationURL: external
        )

        let store = makeStore(home: home)

        #expect(store.loadState == .refused(.unsafePath))
        #expect(store.servers.isEmpty)
        #expect(store.envEntries.isEmpty)
    }

    @Test func unsupportedFileTypeIsRefusedWithoutOpeningFIFO() throws {
        let home = try makeHome()
        let target = home.appendingPathComponent(".cursor/mcp.json")
        guard mkfifo(target.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let store = makeStore(home: home)

        #expect(store.loadState == .refused(.unsupportedFileType))
        #expect(store.servers.isEmpty)
        #expect(store.envEntries.isEmpty)
    }

    @Test func unreadableRegularFileIsRefused() throws {
        let home = try makeHome(mcpJSON: fixture)
        let target = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }

        let store = makeStore(home: home)

        #expect(store.loadState == .refused(.unreadable))
        #expect(store.servers.isEmpty)
        #expect(store.envEntries.isEmpty)
    }

    @Test func oversizedDocumentHasTypedRefusal() throws {
        let home = try makeHome()
        let target = home.appendingPathComponent(".cursor/mcp.json")
        try Data(
            repeating: 0x20,
            count: CursorStore.maximumConfigurationFileSize + 1
        ).write(to: target)

        let store = makeStore(home: home)

        #expect(store.loadState == .refused(.tooLarge))
        #expect(store.servers.isEmpty)
        #expect(store.envEntries.isEmpty)
    }

    @Test func updateRewritesOnlyTheTargetValueAndKeepsPermissions() throws {
        let home = try makeHome(mcpJSON: fixture)
        let store = makeStore(home: home)
        let entry = try #require(store.envEntries.first { $0.key == "API_TOKEN" })
        let server = try #require(store.serverSnapshots.first {
            $0.configuration.name == entry.server
        })

        store.update(entry, expectedServer: server, newValue: "secret-b")

        let url = home.appendingPathComponent(".cursor/mcp.json")
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content == fixture.replacingOccurrences(of: "\"secret-a\"", with: "\"secret-b\""))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(store.lastError == nil)
    }

    @Test func updateRejectsExternallyChangedValues() throws {
        let home = try makeHome(mcpJSON: fixture)
        let store = makeStore(home: home)
        let entry = try #require(store.envEntries.first { $0.key == "API_TOKEN" })
        let server = try #require(store.serverSnapshots.first {
            $0.configuration.name == entry.server
        })

        let url = home.appendingPathComponent(".cursor/mcp.json")
        let external = fixture.replacingOccurrences(of: "\"secret-a\"", with: "\"outside\"")
        try external.write(to: url, atomically: true, encoding: .utf8)

        let saved = store.update(entry, expectedServer: server, newValue: "secret-b")

        #expect(!saved)
        #expect(store.lastError != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == external)
    }

    @Test func updateRejectsSameContentSymlinkReplacementAfterSnapshot() throws {
        let home = try makeHome(mcpJSON: fixture)
        let target = home.appendingPathComponent(".cursor/mcp.json")
        let displaced = home.appendingPathComponent("displaced-mcp.json")
        let external = home.appendingPathComponent("external-mcp.json")
        try fixture.write(to: external, atomically: true, encoding: .utf8)
        let store = makeStore(
            home: home,
            transactionHook: { point in
                guard case .beforeSnapshotValidation = point else { return }
                try FileManager.default.moveItem(at: target, to: displaced)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
            }
        )
        let entry = try #require(store.envEntries.first { $0.key == "API_TOKEN" })
        let server = try #require(store.serverSnapshots.first {
            $0.configuration.name == entry.server
        })

        store.update(entry, expectedServer: server, newValue: "secret-b")

        #expect(store.lastError != nil)
        #expect(try String(contentsOf: displaced, encoding: .utf8) == fixture)
        #expect(try String(contentsOf: external, encoding: .utf8) == fixture)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Backups").path))
    }

    @Test func updateRejectsFIFOWithoutOpeningIt() throws {
        let home = try makeHome(mcpJSON: fixture)
        let store = makeStore(home: home)
        let entry = try #require(store.envEntries.first { $0.key == "API_TOKEN" })
        let server = try #require(store.serverSnapshots.first {
            $0.configuration.name == entry.server
        })
        let target = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.removeItem(at: target)
        guard mkfifo(target.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        store.update(entry, expectedServer: server, newValue: "secret-b")

        #expect(store.lastError != nil)
        let type = try FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType
        #expect(type == .typeUnknown)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Backups").path))
    }

    @Test func updateRejectsOversizedMCPDocument() throws {
        let home = try makeHome(mcpJSON: fixture)
        let store = makeStore(home: home)
        let entry = try #require(store.envEntries.first { $0.key == "API_TOKEN" })
        let server = try #require(store.serverSnapshots.first {
            $0.configuration.name == entry.server
        })
        let target = home.appendingPathComponent(".cursor/mcp.json")
        let oversized = Data(
            repeating: 0x20,
            count: CursorStore.maximumConfigurationFileSize + 1
        )
        try oversized.write(to: target)

        store.update(entry, expectedServer: server, newValue: "secret-b")

        #expect(store.lastError != nil)
        #expect(try Data(contentsOf: target).count == oversized.count)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Backups").path))
    }

    @Test func mutationIsGatedAfterReloadRefusal() throws {
        let home = try makeHome(mcpJSON: fixture)
        let store = makeStore(home: home)
        let entry = try #require(store.envEntries.first { $0.key == "API_TOKEN" })
        let server = try #require(store.serverSnapshots.first {
            $0.configuration.name == entry.server
        })
        let target = home.appendingPathComponent(".cursor/mcp.json")
        let malformed = "{not-json"
        try malformed.write(to: target, atomically: true, encoding: .utf8)
        store.reload()

        let saved = store.update(entry, expectedServer: server, newValue: "secret-b")

        #expect(!saved)
        #expect(store.loadState == .refused(.malformedJSON))
        #expect(try String(contentsOf: target, encoding: .utf8) == malformed)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Backups").path))
    }

    @Test func mutationIsGatedWhenConfigurationIsMissing() throws {
        let home = try makeHome(mcpJSON: fixture)
        let store = makeStore(home: home)
        let server = try #require(store.serverSnapshots.first {
            $0.configuration.name == "shopify"
        })
        let target = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.removeItem(at: target)
        store.reload()

        let saved = store.add(key: "NEW_KEY", value: "new", toServer: server)

        #expect(!saved)
        #expect(store.loadState == .missing)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor/mcp.json").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Backups").path))
    }

    @Test func addAndDeleteMutateTheServerEnv() throws {
        let home = try makeHome(mcpJSON: fixture)
        let store = makeStore(home: home)
        let server = try #require(store.serverSnapshots.first {
            $0.configuration.name == "shopify"
        })

        store.add(key: "NEW_KEY", value: "new", toServer: server)
        #expect(store.envEntries.contains { $0.key == "NEW_KEY" && $0.server == "shopify" })

        let entry = try #require(store.envEntries.first { $0.key == "PLAIN" })
        let currentServer = try #require(store.serverSnapshots.first {
            $0.configuration.name == entry.server
        })
        store.delete(entry, expectedServer: currentServer)
        #expect(!store.envEntries.contains { $0.key == "PLAIN" })
        #expect(store.lastError == nil)
    }

    @Test func addFailsForServerWithoutEnvObject() throws {
        let store = makeStore(home: try makeHome(mcpJSON: fixture))
        let server = try #require(store.serverSnapshots.first {
            $0.configuration.name == "linear"
        })

        store.add(key: "X", value: "1", toServer: server)

        #expect(store.lastError != nil)
    }

    /// A same-name replacement must not receive a secret from a stale editor.
    @Test func addRejectsReplacedServerDefinitionWithSameName() throws {
        let home = try makeHome(mcpJSON: fixture)
        let store = makeStore(home: home)
        let expectedServer = try #require(store.serverSnapshots.first {
            $0.configuration.name == "shopify"
        })
        let target = home.appendingPathComponent(".cursor/mcp.json")
        let replacement = fixture.replacingOccurrences(
            of: #""command": "npx""#,
            with: #""command": "unexpected-command""#
        )
        try replacement.write(to: target, atomically: true, encoding: .utf8)

        let saved = store.add(key: "NEW_SECRET", value: "secret", toServer: expectedServer)

        #expect(!saved)
        #expect(store.lastError != nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == replacement)
        #expect(!store.envEntries.contains { $0.key == "NEW_SECRET" })
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Backups").path))
    }

    /// Hidden environment values participate in the semantic server fingerprint.
    @Test func addRejectsChangedExistingEnvironmentValueWithSameKeys() throws {
        let home = try makeHome(mcpJSON: fixture)
        let store = makeStore(home: home)
        let expectedServer = try #require(store.serverSnapshots.first {
            $0.configuration.name == "shopify"
        })
        let target = home.appendingPathComponent(".cursor/mcp.json")
        let replacement = fixture.replacingOccurrences(
            of: #""PLAIN": "value""#,
            with: #""PLAIN": "externally-changed""#
        )
        try replacement.write(to: target, atomically: true, encoding: .utf8)

        let saved = store.add(key: "NEW_SECRET", value: "secret", toServer: expectedServer)

        #expect(!saved)
        #expect(store.lastError != nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == replacement)
        #expect(!store.envEntries.contains { $0.key == "NEW_SECRET" })
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Backups").path))
    }

    @Test func missingDirectoryYieldsEmptyState() throws {
        let store = makeStore(home: try makeTempDir())
        #expect(store.loadState == .missing)
        #expect(!store.directoryExists)
        #expect(store.servers.isEmpty)
        #expect(store.envEntries.isEmpty)
    }
}
