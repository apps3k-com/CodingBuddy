//
//  FeatureFlags.swift
//  EnvVarBuddy
//

import Foundation

/// Release channel of the running build.
///
/// The channel is derived from the marketing version that release-please
/// stamps into the build: `x.y.z-beta.n` → beta, plain `x.y.z` → stable.
/// Debug builds are always alpha. No extra Info.plist keys needed.
nonisolated enum ReleaseChannel: String, Sendable {
    case alpha
    case beta
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
    case hideOverriddenVariables
    case secretsProtection
    case envImportExport
    case mcpAuthManager

    /// The most stable channel in which the feature is active. `.alpha` means
    /// alpha builds only, `.beta` means alpha + beta, `.stable` means everyone.
    var maturity: ReleaseChannel {
        switch self {
        // Stable from the start: it replaces the retired groupedOverridesView
        // feature, which already shipped stable.
        case .hideOverriddenVariables: .stable
        case .secretsProtection: .stable
        case .envImportExport: .stable
        case .mcpAuthManager: .stable
        }
    }

    /// Active when the running channel is within the flag's maturity, unless
    /// overridden for local testing:
    /// `defaults write apps3k.EnvVarBuddy flag.<name> -bool YES|NO`
    var isEnabled: Bool {
        if let override = UserDefaults.standard.object(forKey: "flag.\(rawValue)") as? Bool {
            return override
        }
        return ReleaseChannel.current.rank <= maturity.rank
    }
}
