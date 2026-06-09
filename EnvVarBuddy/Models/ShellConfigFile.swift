//
//  ShellConfigFile.swift
//  EnvVarBuddy
//

import Foundation

/// The zsh startup files managed by the app, ordered by zsh load order for an
/// interactive login shell: .zshenv → .zprofile → .zshrc. Later files win when
/// the same variable is assigned in more than one of them.
enum ShellConfigFile: String, CaseIterable, Identifiable, Hashable {
    case zshenv = ".zshenv"
    case zprofile = ".zprofile"
    case zshrc = ".zshrc"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// Position in zsh's load order; files with a higher value load later and
    /// override assignments from earlier files.
    var loadOrder: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    func url(in homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(rawValue, isDirectory: false)
    }
}
