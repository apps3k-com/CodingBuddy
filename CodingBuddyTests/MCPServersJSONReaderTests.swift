//
//  MCPServersJSONReaderTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct MCPServersJSONReaderTests {

    private let document = """
    {
      "mcpServers": {
        "shopify": {
          "command": "npx",
          "args": ["-y", "@shopify/dev-mcp@latest"],
          "env": { "API_KEY": "x", "SECOND": "y" }
        },
        "linear": {
          "type": "http",
          "url": "https://mcp.linear.app/mcp",
          "headers": { "Authorization": "Bearer abc" }
        }
      }
    }
    """

    @Test func parsesStdioAndRemoteServers() {
        let servers = MCPServersJSONReader.servers(inDocument: document, scope: "user")

        #expect(servers.map(\.name).sorted() == ["linear", "shopify"])

        let shopify = servers.first { $0.name == "shopify" }
        #expect(shopify?.command == "npx")
        #expect(shopify?.args == ["-y", "@shopify/dev-mcp@latest"])
        #expect(shopify?.envKeys == ["API_KEY", "SECOND"])
        #expect(shopify?.scope == "user")

        let linear = servers.first { $0.name == "linear" }
        #expect(linear?.type == "http")
        #expect(linear?.url == "https://mcp.linear.app/mcp")
        #expect(linear?.headerKeys == ["Authorization"])
    }

    @Test func invalidOrEmptyDocumentsYieldNothing() {
        #expect(MCPServersJSONReader.servers(inDocument: "{ broken", scope: "user").isEmpty)
        #expect(MCPServersJSONReader.servers(inDocument: "{}", scope: "user").isEmpty)
    }
}
