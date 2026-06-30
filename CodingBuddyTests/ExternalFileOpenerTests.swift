//
//  ExternalFileOpenerTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct ExternalFileOpenerTests {
    @Test func systemDefaultPreferenceOpensTextFileWithSystemDefault() async {
        let workspace = FakeExternalFileWorkspace()
        let opener = ExternalFileOpener(workspace: workspace)
        let url = URL(fileURLWithPath: "/tmp/README.md")

        let result = await opener.open(url, preference: .systemDefault)

        #expect(result == .openedWithSystemDefault)
        #expect(workspace.defaultOpenedURLs == [url])
        #expect(workspace.appOpenedURLs.isEmpty)
    }

    @Test func selectedEditorOpensMarkdownWithConfiguredApplication() async {
        let appURL = URL(fileURLWithPath: "/Applications/Editor.app")
        let url = URL(fileURLWithPath: "/tmp/AGENTS.md")
        let workspace = FakeExternalFileWorkspace(
            bundleApplications: ["com.example.Editor": appURL],
            existingURLs: [appURL, url]
        )
        let opener = ExternalFileOpener(workspace: workspace)

        let result = await opener.open(
            url,
            preference: .application(
                bundleIdentifier: "com.example.Editor",
                applicationURL: appURL,
                displayName: "Editor"
            )
        )

        #expect(result == .openedWithSelectedEditor)
        #expect(workspace.defaultOpenedURLs.isEmpty)
        #expect(workspace.appOpenedURLs == [FakeExternalFileWorkspace.AppOpen(url: url, applicationURL: appURL)])
    }

    @Test func selectedEditorFallsBackWhenApplicationIsUnavailable() async {
        let url = URL(fileURLWithPath: "/tmp/.mcp.json")
        let workspace = FakeExternalFileWorkspace(existingURLs: [url])
        let opener = ExternalFileOpener(workspace: workspace)

        let result = await opener.open(
            url,
            preference: .application(
                bundleIdentifier: "com.example.MissingEditor",
                applicationURL: URL(fileURLWithPath: "/Applications/Missing.app"),
                displayName: "Missing"
            )
        )

        #expect(result == .fellBackToSystemDefault)
        #expect(workspace.defaultOpenedURLs == [url])
        #expect(workspace.appOpenedURLs.isEmpty)
    }

    @Test func selectedEditorUsesStoredApplicationPathWhenBundleLookupFails() async {
        let appURL = URL(fileURLWithPath: "/Applications/Editor.app")
        let url = URL(fileURLWithPath: "/tmp/project.yml")
        let workspace = FakeExternalFileWorkspace(existingURLs: [appURL, url])
        let opener = ExternalFileOpener(workspace: workspace)

        let result = await opener.open(
            url,
            preference: .application(
                bundleIdentifier: "com.example.UnresolvedEditor",
                applicationURL: appURL,
                displayName: "Editor"
            )
        )

        #expect(result == .openedWithSelectedEditor)
        #expect(workspace.defaultOpenedURLs.isEmpty)
        #expect(workspace.appOpenedURLs == [FakeExternalFileWorkspace.AppOpen(url: url, applicationURL: appURL)])
    }

    @Test func selectedEditorOpenFailureFallsBackToSystemDefault() async {
        let appURL = URL(fileURLWithPath: "/Applications/Editor.app")
        let url = URL(fileURLWithPath: "/tmp/README.md")
        let workspace = FakeExternalFileWorkspace(
            bundleApplications: ["com.example.Editor": appURL],
            existingURLs: [appURL, url],
            appOpenSucceeds: false,
            appOpenYieldsBeforeResult: true
        )
        let opener = ExternalFileOpener(workspace: workspace)

        let result = await opener.open(
            url,
            preference: .application(
                bundleIdentifier: "com.example.Editor",
                applicationURL: appURL,
                displayName: "Editor"
            )
        )

        #expect(result == .fellBackToSystemDefault)
        #expect(workspace.defaultOpenedURLs == [url])
        #expect(workspace.appOpenedURLs == [FakeExternalFileWorkspace.AppOpen(url: url, applicationURL: appURL)])
    }

    @Test func missingTextFileUsesSystemDefaultInsteadOfSelectedEditor() async {
        let appURL = URL(fileURLWithPath: "/Applications/Editor.app")
        let workspace = FakeExternalFileWorkspace(
            bundleApplications: ["com.example.Editor": appURL],
            existingURLs: [appURL]
        )
        let opener = ExternalFileOpener(workspace: workspace)
        let url = URL(fileURLWithPath: "/tmp/Missing.md")

        let result = await opener.open(
            url,
            preference: .application(
                bundleIdentifier: "com.example.Editor",
                applicationURL: appURL,
                displayName: "Editor"
            )
        )

        #expect(result == .openedWithSystemDefault)
        #expect(workspace.defaultOpenedURLs == [url])
        #expect(workspace.appOpenedURLs.isEmpty)
    }

    @Test func failedSystemDefaultOpenReturnsFailedResult() async {
        let workspace = FakeExternalFileWorkspace(defaultOpenSucceeds: false)
        let opener = ExternalFileOpener(workspace: workspace)
        let url = URL(fileURLWithPath: "/tmp/README.md")

        let result = await opener.open(url, preference: .systemDefault)

        #expect(result == .failed)
        #expect(workspace.defaultOpenedURLs == [url])
        #expect(workspace.appOpenedURLs.isEmpty)
    }

    @Test func nonFileURLsAreNotOpened() async {
        let workspace = FakeExternalFileWorkspace()
        let opener = ExternalFileOpener(workspace: workspace)

        let result = await opener.open(URL(string: "https://example.com/README.md")!, preference: .systemDefault)

        #expect(result == .unsupportedURL)
        #expect(workspace.defaultOpenedURLs.isEmpty)
        #expect(workspace.appOpenedURLs.isEmpty)
    }

    @Test func directoriesUseSystemDefaultInsteadOfSelectedEditor() async {
        let appURL = URL(fileURLWithPath: "/Applications/Editor.app")
        let directoryURL = URL(fileURLWithPath: "/tmp/.cursor/rules", isDirectory: true)
        let workspace = FakeExternalFileWorkspace(
            directoryURLs: [directoryURL],
            bundleApplications: ["com.example.Editor": appURL],
            existingURLs: [appURL, directoryURL]
        )
        let opener = ExternalFileOpener(workspace: workspace)

        let result = await opener.open(
            directoryURL,
            preference: .application(
                bundleIdentifier: "com.example.Editor",
                applicationURL: appURL,
                displayName: "Editor"
            )
        )

        #expect(result == .openedWithSystemDefault)
        #expect(workspace.defaultOpenedURLs == [directoryURL])
        #expect(workspace.appOpenedURLs.isEmpty)
    }

    @Test func symlinksUseSystemDefaultInsteadOfSelectedEditor() async {
        let appURL = URL(fileURLWithPath: "/Applications/Editor.app")
        let symlinkURL = URL(fileURLWithPath: "/tmp/CLAUDE.md")
        let workspace = FakeExternalFileWorkspace(
            symlinkURLs: [symlinkURL],
            bundleApplications: ["com.example.Editor": appURL],
            existingURLs: [appURL, symlinkURL]
        )
        let opener = ExternalFileOpener(workspace: workspace)

        let result = await opener.open(
            symlinkURL,
            preference: .application(
                bundleIdentifier: "com.example.Editor",
                applicationURL: appURL,
                displayName: "Editor"
            )
        )

        #expect(result == .openedWithSystemDefault)
        #expect(workspace.defaultOpenedURLs == [symlinkURL])
        #expect(workspace.appOpenedURLs.isEmpty)
    }
}

@MainActor
private final class FakeExternalFileWorkspace: ExternalFileWorkspace {
    /// One app-specific open request captured by the fake.
    struct AppOpen: Equatable {
        /// File URL passed to the opener.
        let url: URL
        /// Application URL passed to the opener.
        let applicationURL: URL
    }

    /// URLs opened with the system default.
    private(set) var defaultOpenedURLs: [URL] = []
    /// URLs opened with a specific application.
    private(set) var appOpenedURLs: [AppOpen] = []

    /// URLs treated as directories.
    private let directoryURLs: Set<URL>
    /// URLs treated as symbolic links.
    private let symlinkURLs: Set<URL>
    /// Application URLs resolved by bundle identifier.
    private let bundleApplications: [String: URL]
    /// URLs treated as existing files.
    private let existingURLs: Set<URL>
    /// Whether system-default open requests should report success.
    private let defaultOpenSucceeds: Bool
    /// Whether app-specific open requests should report success.
    private let appOpenSucceeds: Bool
    /// Whether app-specific open requests should suspend before returning.
    private let appOpenYieldsBeforeResult: Bool

    /// Creates a fake workspace with deterministic filesystem and app state.
    init(
        directoryURLs: Set<URL> = [],
        symlinkURLs: Set<URL> = [],
        bundleApplications: [String: URL] = [:],
        existingURLs: Set<URL> = [],
        defaultOpenSucceeds: Bool = true,
        appOpenSucceeds: Bool = true,
        appOpenYieldsBeforeResult: Bool = false
    ) {
        self.directoryURLs = directoryURLs
        self.symlinkURLs = symlinkURLs
        self.bundleApplications = bundleApplications
        self.existingURLs = existingURLs
        self.defaultOpenSucceeds = defaultOpenSucceeds
        self.appOpenSucceeds = appOpenSucceeds
        self.appOpenYieldsBeforeResult = appOpenYieldsBeforeResult
    }

    /// Records a system-default open request.
    func openDefault(_ url: URL) -> Bool {
        defaultOpenedURLs.append(url)
        return defaultOpenSucceeds
    }

    /// Records an app-specific open request.
    func open(_ url: URL, withApplicationAt applicationURL: URL) async -> Bool {
        appOpenedURLs.append(AppOpen(url: url, applicationURL: applicationURL))
        if appOpenYieldsBeforeResult {
            await Task.yield()
        }
        return appOpenSucceeds
    }

    /// Returns a fake application URL for a known bundle identifier.
    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        bundleApplications[bundleIdentifier]
    }

    /// Returns whether a URL is modeled as a directory.
    func isDirectory(at url: URL) -> Bool {
        directoryURLs.contains(url)
    }

    /// Returns whether a URL is modeled as a symbolic link.
    func isSymbolicLink(at url: URL) -> Bool {
        symlinkURLs.contains(url)
    }

    /// Returns whether a URL exists in the fake filesystem.
    func fileExists(at url: URL) -> Bool {
        existingURLs.contains(url)
    }
}
