//
//  JSONPatcherTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct JSONPatcherTests {

    /// Settings-style fixture: nested structures, mixed indentation, the env
    /// block somewhere in the middle. Everything outside the patch target
    /// must survive byte-for-byte.
    private let fixture = """
    {
      "model": "opus",
      "env": {
        "GITHUB_TOKEN": "old-secret",
        "PLAIN": "value",
        "LAST": "end"
      },
      "hooks": {
        "PostToolUse": [
          { "matcher": "Bash", "command": "echo done" }
        ]
      },
      "count": 3
    }
    """

    // MARK: - replaceString

    @Test func replaceChangesOnlyTheTargetValue() throws {
        let patched = try JSONPatcher.replaceString(
            in: fixture, at: ["env", "GITHUB_TOKEN"], with: "new-secret"
        )
        #expect(patched == fixture.replacingOccurrences(of: "\"old-secret\"", with: "\"new-secret\""))
    }

    @Test func replaceEscapesSpecialCharacters() throws {
        let patched = try JSONPatcher.replaceString(
            in: fixture, at: ["env", "PLAIN"], with: "a \"quote\" \\ back\nslash"
        )
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(patched.utf8)) as? [String: Any])
        let env = try #require(parsed["env"] as? [String: String])
        #expect(env["PLAIN"] == "a \"quote\" \\ back\nslash")
        // Rest unverändert:
        #expect(patched.contains("\"old-secret\""))
        #expect(patched.contains("\"echo done\""))
    }

    @Test func replaceRejectsNonStringTargets() {
        #expect(throws: JSONPatcher.PatchError.self) {
            try JSONPatcher.replaceString(in: fixture, at: ["count"], with: "x")
        }
    }

    @Test func replaceRejectsUnknownPaths() {
        #expect(throws: JSONPatcher.PatchError.self) {
            try JSONPatcher.replaceString(in: fixture, at: ["env", "NOPE"], with: "x")
        }
    }

    @Test func replaceIsIdempotent() throws {
        let once = try JSONPatcher.replaceString(in: fixture, at: ["env", "PLAIN"], with: "same")
        let twice = try JSONPatcher.replaceString(in: once, at: ["env", "PLAIN"], with: "same")
        #expect(once == twice)
    }

    @Test func unicodeEscapedKeysAreMatched() throws {
        let doc = #"{ "env": { "TOKEN": "old" } }"#
        let patched = try JSONPatcher.replaceString(in: doc, at: ["env", "TOKEN"], with: "new")
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(patched.utf8)) as? [String: Any])
        let env = try #require(parsed["env"] as? [String: String])
        #expect(env["TOKEN"] == "new")
    }

    // MARK: - insertPair

    @Test func insertIntoPopulatedObjectMatchesSiblingIndentation() throws {
        let patched = try JSONPatcher.insertPair(
            in: fixture, at: ["env"], key: "NEW_KEY", value: "new-value"
        )
        #expect(patched.contains("\"LAST\": \"end\",\n    \"NEW_KEY\": \"new-value\"\n"))
        // Alles außerhalb von env unverändert:
        #expect(patched.contains("\"count\": 3"))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(patched.utf8)) as? [String: Any])
        let env = try #require(parsed["env"] as? [String: String])
        #expect(env.count == 4)
    }

    @Test func insertIntoEmptyObject() throws {
        let doc = "{\n  \"env\": {}\n}"
        let patched = try JSONPatcher.insertPair(in: doc, at: ["env"], key: "A", value: "1")
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(patched.utf8)) as? [String: Any])
        #expect((parsed["env"] as? [String: String]) == ["A": "1"])
    }

    @Test func insertRejectsDuplicateKey() {
        #expect(throws: JSONPatcher.PatchError.self) {
            try JSONPatcher.insertPair(in: fixture, at: ["env"], key: "PLAIN", value: "x")
        }
    }

    // MARK: - removePair

    @Test func removeMiddlePairKeepsValidJSON() throws {
        let patched = try JSONPatcher.removePair(in: fixture, at: ["env", "PLAIN"])
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(patched.utf8)) as? [String: Any])
        let env = try #require(parsed["env"] as? [String: String])
        #expect(env == ["GITHUB_TOKEN": "old-secret", "LAST": "end"])
        #expect(patched.contains("\"hooks\""))
    }

    @Test func removeLastPairRemovesPrecedingComma() throws {
        let patched = try JSONPatcher.removePair(in: fixture, at: ["env", "LAST"])
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(patched.utf8)) as? [String: Any])
        let env = try #require(parsed["env"] as? [String: String])
        #expect(env == ["GITHUB_TOKEN": "old-secret", "PLAIN": "value"])
    }

    @Test func removeOnlyPairLeavesEmptyObject() throws {
        let doc = "{\n  \"env\": {\n    \"ONLY\": \"x\"\n  }\n}"
        let patched = try JSONPatcher.removePair(in: doc, at: ["env", "ONLY"])
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(patched.utf8)) as? [String: Any])
        #expect((parsed["env"] as? [String: String]) == [:])
    }

    // MARK: - Safety

    @Test func duplicateKeysInTargetObjectAreRefused() {
        let doc = #"{ "env": { "A": "1", "A": "2" } }"#
        #expect(throws: JSONPatcher.PatchError.self) {
            try JSONPatcher.replaceString(in: doc, at: ["env", "A"], with: "x")
        }
    }

    @Test func malformedJSONIsRefused() {
        #expect(throws: JSONPatcher.PatchError.self) {
            try JSONPatcher.replaceString(in: "{ broken", at: ["env"], with: "x")
        }
    }
}
