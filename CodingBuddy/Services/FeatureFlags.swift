//
//  FeatureFlags.swift
//  CodingBuddy
//

import Foundation

/// Release channel of the running build.
///
/// The channel is derived from the marketing version that release-please
/// stamps into the build: `x.y.z-beta.n` → beta, plain `x.y.z` → stable.
/// Debug builds are always alpha. No extra Info.plist keys needed.
nonisolated enum ReleaseChannel: String, Sendable {
    /// Internal alpha builds with every experimental feature enabled.
    case alpha
    /// Beta builds with features that are ready for wider validation.
    case beta
    /// Stable builds for regular users.
    case stable

    /// How far towards "everyone" the channel reaches. Alpha builds see the
    /// most, stable builds the least experimental feature set.
    var rank: Int {
        switch self {
        case .alpha: 0
        case .beta: 1
        case .stable: 2
        }
    }

    /// Release channel inferred from the current app bundle version.
    static var current: ReleaseChannel {
        #if DEBUG
        .alpha
        #else
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if version.contains("-alpha") { return .alpha }
        if version.contains("-beta") { return .beta }
        return .stable
        #endif
    }
}

/// Registry of all feature flags.
///
/// Rules (enforced by `scripts/check-feature-flags.sh` in the pre-push hook
/// and CI): every case has a `### \`flagName\`` section in
/// docs/FEATURE_FLAGS.md, and vice versa.
nonisolated enum FeatureFlag: String, CaseIterable, Sendable {
    /// Enables Codex tool configuration in the AI tools area.
    case aiToolsCodex
    /// Enables Claude Code tool configuration in the AI tools area.
    case aiToolsClaudeCode
    /// Enables Cursor tool configuration in the AI tools area.
    case aiToolsCursor
    /// Enables Craft Agents tool configuration in the AI tools area.
    case aiToolsCraftAgent
    /// Hides variable rows overridden by later dotfiles.
    case hideOverriddenVariables
    /// Enables UI affordances for masking and revealing secrets.
    case secretsProtection
    /// Enables import/export workflows for environment variables.
    case envImportExport
    /// Enables the local MCP authentication manager.
    case mcpAuthManager
    /// Enables local agent setup diagnostics.
    case agentDoctor
    /// Enables governance and context file inspection.
    case agentContextInspector
    /// Enables repository readiness checks.
    case repoReadinessChecklist
    /// Enables cross-tool MCP server inventory.
    case mcpServerInventory
    /// Enables the read-only GitHub Agent PR Monitor.
    case agentPRMonitor
    /// Enables local backup discovery and restore.
    case backupBrowser

    /// The most stable channel in which the feature is active. `.alpha` means
    /// alpha builds only, `.beta` means alpha + beta, `.stable` means everyone.
    var maturity: ReleaseChannel {
        switch self {
        case .aiToolsCodex: .alpha
        case .aiToolsClaudeCode: .alpha
        case .aiToolsCursor: .alpha
        case .aiToolsCraftAgent: .alpha
        // Stable from the start: it replaces the retired groupedOverridesView
        // feature, which already shipped stable.
        case .hideOverriddenVariables: .stable
        case .secretsProtection: .stable
        case .envImportExport: .stable
        case .mcpAuthManager: .stable
        case .agentDoctor: .alpha
        case .agentContextInspector: .alpha
        case .repoReadinessChecklist: .alpha
        case .mcpServerInventory: .alpha
        case .agentPRMonitor: .alpha
        case .backupBrowser: .alpha
        }
    }

    /// Active when the running channel is within the flag's maturity, unless
    /// overridden for local testing:
    /// `defaults write apps3k.CodingBuddy flag.<name> -bool YES|NO`
    var isEnabled: Bool {
        if let override = UserDefaults.standard.object(forKey: "flag.\(rawValue)") as? Bool {
            return override
        }
        return ReleaseChannel.current.rank <= maturity.rank
    }
}
