//
//  ExternalFileOpener.swift
//  CodingBuddy
//

import AppKit
import Foundation

/// Result of a user-requested external file open action.
nonisolated enum ExternalFileOpenResult: Equatable, Sendable {
    /// Launch Services accepted the request with the system default app.
    case openedWithSystemDefault
    /// Launch Services accepted the request with the configured editor.
    case openedWithSelectedEditor
    /// The configured editor was unavailable, so the system default was used.
    case fellBackToSystemDefault
    /// The URL is not a local file URL and was not opened by this service.
    case unsupportedURL
    /// Launch Services rejected the open request.
    case failed
}

/// Minimal workspace surface used by `ExternalFileOpener`.
@MainActor protocol ExternalFileWorkspace {
    /// Opens a URL with Launch Services' system default app.
    func openDefault(_ url: URL) -> Bool

    /// Opens a URL with a specific application.
    func open(_ url: URL, withApplicationAt applicationURL: URL) async -> Bool

    /// Resolves an installed application by bundle identifier.
    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?

    /// Returns whether the path exists and is a directory.
    func isDirectory(at url: URL) -> Bool

    /// Returns whether the path exists and is a symbolic link.
    func isSymbolicLink(at url: URL) -> Bool

    /// Returns whether the path exists.
    func fileExists(at url: URL) -> Bool
}

/// AppKit-backed workspace implementation.
@MainActor struct AppKitExternalFileWorkspace: ExternalFileWorkspace {
    /// Opens a URL with Launch Services' system default app.
    func openDefault(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    /// Opens a URL with a specific application and reports the Launch Services result.
    func open(_ url: URL, withApplicationAt applicationURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    /// Resolves an installed application by bundle identifier.
    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Returns whether the path exists and is a directory.
    func isDirectory(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    /// Returns whether the path exists and is a symbolic link.
    func isSymbolicLink(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// Returns whether the path exists.
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// Opens CodingBuddy-owned text-like files with the configured default editor.
@MainActor struct ExternalFileOpener {
    /// Workspace implementation used for Launch Services calls.
    private let workspace: any ExternalFileWorkspace

    /// Creates a file opener backed by AppKit Launch Services.
    init() {
        self.workspace = AppKitExternalFileWorkspace()
    }

    /// Creates a file opener with an injectable workspace for tests.
    init(workspace: any ExternalFileWorkspace) {
        self.workspace = workspace
    }

    /// Opens a local URL, using the configured editor only for real text-like files.
    func open(
        _ url: URL,
        preference: DefaultTextEditorPreference = .load()
    ) async -> ExternalFileOpenResult {
        guard url.isFileURL else { return .unsupportedURL }

        guard shouldUseTextEditor(for: url) else {
            return openWithSystemDefault(url)
        }

        guard preference != .systemDefault else {
            return openWithSystemDefault(url)
        }

        guard let selectedApplicationURL = selectedApplicationURL(for: preference) else {
            return workspace.openDefault(url) ? .fellBackToSystemDefault : .failed
        }

        return await workspace.open(url, withApplicationAt: selectedApplicationURL)
            ? .openedWithSelectedEditor
            : workspace.openDefault(url) ? .fellBackToSystemDefault : .failed
    }

    /// Returns the configured application URL if it is still available.
    private func selectedApplicationURL(for preference: DefaultTextEditorPreference) -> URL? {
        guard case .application(let bundleIdentifier, let applicationURL, _) = preference else {
            return nil
        }

        if let bundleIdentifier,
           let installedURL = workspace.applicationURL(forBundleIdentifier: bundleIdentifier) {
            return installedURL
        }

        return workspace.fileExists(at: applicationURL) ? applicationURL : nil
    }

    /// Returns whether a URL should be opened with the configured text editor.
    private func shouldUseTextEditor(for url: URL) -> Bool {
        workspace.fileExists(at: url)
            && !workspace.isDirectory(at: url)
            && !workspace.isSymbolicLink(at: url)
            && TextFileClassifier.isTextLike(url)
    }

    /// Opens a URL with the system default and marks editor-unavailable fallback when appropriate.
    private func openWithSystemDefault(_ url: URL) -> ExternalFileOpenResult {
        workspace.openDefault(url) ? .openedWithSystemDefault : .failed
    }
}

/// File-name based classifier for text-like repository files.
nonisolated enum TextFileClassifier {
    /// File extensions that should respect the default editor preference.
    private static let textExtensions: Set<String> = [
        "bash", "conf", "config", "env", "fish", "ini", "json", "jsonc",
        "md", "markdown", "sh", "toml", "txt", "xml", "yaml", "yml", "zsh"
    ]

    /// Extensionless or dotfile names that should respect the editor preference.
    private static let textFileNames: Set<String> = [
        ".bash_profile", ".bashrc", ".env", ".gitignore", ".profile",
        ".zprofile", ".zshenv", ".zshrc", "dockerfile", "makefile"
    ]

    /// Returns true for Markdown, structured config, shell, and common dotfile text names.
    static func isTextLike(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let pathExtension = url.pathExtension.lowercased()
        return textExtensions.contains(pathExtension) || textFileNames.contains(name)
    }
}
