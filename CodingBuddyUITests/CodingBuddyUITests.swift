//
//  CodingBuddyUITests.swift
//  CodingBuddyUITests
//
//  Created by Björn von Känel on 09.06.2026.
//

import Foundation
import XCTest

/// End-to-end safety journeys that exercise production launch and persistence paths.
final class CodingBuddyUITests: XCTestCase {
    /// Temporary fixture roots removed after every test.
    private var temporaryDirectories: [URL] = []

    /// Stops after the first failed UI assertion to avoid interacting with an unexpected window.
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Removes only fixture directories created by the current test process.
    override func tearDownWithError() throws {
        for directory in temporaryDirectories.reversed() {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    /// An invalid UTF-8 shell file must remain visibly blocked in a German launch.
    @MainActor
    func testInvalidUTF8ZshrcBlocksUnsafeActionsInGerman() throws {
        let homeDirectory = try makeTemporaryDirectory()
        let zshrcURL = homeDirectory.appendingPathComponent(".zshrc", isDirectory: false)
        try Data([0x65, 0x78, 0x70, 0x6F, 0x72, 0x74, 0x20, 0x80, 0x0A])
            .write(to: zshrcURL, options: .atomic)

        let app = makeApplication(
            homeDirectory: homeDirectory,
            language: "de",
            defaults: [
                "sidebar.selectedScope": "file:.zshrc",
                "flag.envImportExport": "YES"
            ]
        )
        app.launch()
        defer { app.terminate() }

        let blockedState = element(named: "Zugriff auf Shell-Datei blockiert", in: app)
        assertExists(blockedState, timeout: 12)
        assertExists(
            text(containing: "kein gültiges UTF-8", in: app),
            timeout: 5
        )

        let retryButton = element(named: "Erneut versuchen", in: app)
        let showInFinderButton = element(named: "Im Finder zeigen", in: app)
        assertExists(retryButton)
        assertExists(showInFinderButton)
        XCTAssertTrue(retryButton.isEnabled)
        XCTAssertTrue(showInFinderButton.isEnabled)

        let newVariableButton = element(named: "Neue Variable", in: app)
        let importExportButton = element(named: "Import/Export", in: app)
        assertExists(newVariableButton)
        assertExists(importExportButton)
        XCTAssertFalse(newVariableButton.isEnabled, "New must stay disabled for an incomplete snapshot.")
        XCTAssertFalse(importExportButton.isEnabled, "Import and export must stay disabled for an incomplete snapshot.")
        XCTAssertFalse(
            element(named: "Bearbeiten…", in: app).exists,
            "No editable row or edit action may be exposed for a refused file."
        )

        app.activate()
        app.typeKey("i", modifierFlags: [.command, .shift])
        app.typeKey("e", modifierFlags: [.command, .shift])
        runMainLoop(for: 0.5)
        XCTAssertEqual(app.sheets.count, 0, "Keyboard commands must not bypass the blocked toolbar state.")
        XCTAssertEqual(app.dialogs.count, 0, "No import or export dialog may open for refused data.")

        retryButton.click()
        assertExists(blockedState, timeout: 5)
        XCTAssertFalse(element(named: "Keine Variablen", in: app).exists)
        assertStableLaunchWindowSize(in: app)
    }

    /// A final-component repository symlink must produce an explicit refusal, never an empty result.
    @MainActor
    func testAgentContextSymlinkRepositoryShowsSecurityRefusal() throws {
        let homeDirectory = try makeTemporaryDirectory()
        let fixtureDirectory = try makeTemporaryDirectory()
        let realRepository = fixtureDirectory.appendingPathComponent("real-repository", isDirectory: true)
        let linkedRepository = fixtureDirectory.appendingPathComponent("linked-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: realRepository, withIntermediateDirectories: false)
        try "STALE_CONTEXT_MUST_NOT_APPEAR\n".write(
            to: realRepository.appendingPathComponent("AGENTS.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: linkedRepository, withDestinationURL: realRepository)

        let app = makeApplication(
            homeDirectory: homeDirectory,
            language: "en",
            defaults: [
                "sidebar.selectedScope": "agentContextInspector",
                "agentContextInspectorRepositoryPath": linkedRepository.path,
                "flag.agentContextInspector": "YES"
            ]
        )
        app.launch()
        defer { app.terminate() }

        let blockedState = element(named: "Repository inspection blocked", in: app)
        assertExists(blockedState, timeout: 12)
        assertExists(
            text(containing: "contains a symbolic link", in: app),
            timeout: 5
        )

        let retryButton = element(named: "Retry", in: app)
        let chooseAnotherFolderButton = element(named: "Choose Another Folder...", in: app)
        assertExists(retryButton)
        assertExists(chooseAnotherFolderButton)
        XCTAssertTrue(retryButton.isEnabled)
        XCTAssertTrue(chooseAnotherFolderButton.isEnabled)

        XCTAssertFalse(element(named: "No Results", in: app).exists)
        XCTAssertFalse(element(named: "AGENTS.md", in: app).exists)
        XCTAssertFalse(element(named: "STALE_CONTEXT_MUST_NOT_APPEAR", in: app).exists)

        retryButton.click()
        assertExists(blockedState, timeout: 5)
        XCTAssertFalse(element(named: "No Results", in: app).exists)
        assertStableLaunchWindowSize(in: app)
    }

    /// Creates one private home or repository fixture root with restrictive permissions.
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingBuddyUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        temporaryDirectories.append(directory)
        return directory
    }

    /// Builds an isolated app launch using only supported defaults and Foundation home overrides.
    @MainActor
    private func makeApplication(
        homeDirectory: URL,
        language: String,
        defaults: [String: String]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CFFIXED_USER_HOME"] = homeDirectory.path
        app.launchEnvironment["HOME"] = homeDirectory.path
        app.launchArguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language == "de" ? "de_DE" : "en_US",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        for key in defaults.keys.sorted() {
            app.launchArguments.append(contentsOf: ["-\(key)", defaults[key] ?? ""])
        }
        return app
    }

    /// Finds an accessibility element by its localized label or identifier.
    @MainActor
    private func element(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: name).firstMatch
    }

    /// Finds the first visible text element containing a stable semantic fragment.
    @MainActor
    private func text(containing fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// Waits for an element while retaining the caller's source location in failures.
    @MainActor
    private func assertExists(
        _ element: XCUIElement,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected UI element did not appear: \(element)",
            file: file,
            line: line
        )
    }

    /// Verifies the stable default launch envelope without fragile resize gestures.
    @MainActor
    private func assertStableLaunchWindowSize(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch
        assertExists(window, timeout: 5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(window.frame.width, 800, file: file, line: line)
        XCTAssertGreaterThanOrEqual(window.frame.height, 500, file: file, line: line)
    }

    /// Gives AppKit enough time to present a dialog if an unsafe command escaped its guard.
    @MainActor
    private func runMainLoop(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }
}
