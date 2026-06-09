# CLAUDE.md — EnvVarBuddy

Native macOS app (SwiftUI) for managing environment variables in zsh dotfiles.
Deep documentation lives in the [wiki](https://github.com/apps3k-com/EnvVarBuddy/wiki) — this file stays slim.

## Iron rules

### Native Swift only — no exceptions
- Swift, SwiftUI, AppKit and Apple system frameworks (Foundation, LocalAuthentication, …) only.
- NO third-party dependencies — no SPM packages, no CocoaPods, no vendored binaries — unless the maintainer explicitly approves one in writing.
- No embedded scripts or runtimes (Node, Python, shell wrappers) as a substitute for native code.

### Dotfile safety (core invariant)
- Editable lines must round-trip byte-for-byte: `ParsedAssignment.rendered == sourceLine`.
- Anything ambiguous (command substitution, multi-assignments, unclosed quotes, trailing code) is read-only and is never rewritten from parts.
- Every write: backup first, then atomic, symlink-safe, permission-preserving.
- The writer re-validates the target line against the on-disk state (`sourceLine`) before mutating — never write blindly by line index.

### Tests
- Swift Testing (`import Testing`); no new XCTest code.
- Tests NEVER touch real dotfiles or `$HOME` — temp directories only (the store's base directory is injectable).
- Parser/writer changes without new or adjusted tests do not get merged.

### Localization
- Source language is English. Every user-facing string goes through the String Catalog (`Localizable.xcstrings`) and ships with a German translation.
- No hard-coded user-facing strings outside the catalog.

### Workflow
- Feature branches off `main`; Conventional Commits (enforced by hooks/CI); squash-merge PRs.
- Every new feature sits behind a flag in `EnvVarBuddy/Services/FeatureFlags.swift` and is documented in `docs/FEATURE_FLAGS.md`.
- User-visible changes update the wiki sources under `docs/wiki/` (EN + DE) in the same PR.

## Build & test

```bash
xcodebuild -project EnvVarBuddy.xcodeproj -scheme EnvVarBuddy build
xcodebuild test -project EnvVarBuddy.xcodeproj -scheme EnvVarBuddy \
  -destination 'platform=macOS' -only-testing:EnvVarBuddyTests
./scripts/setup.sh   # once per clone: activates the git hooks
```

## Project conventions
- Xcode synchronized folders: create new files in the matching folder (`Models/`, `Services/`, `Stores/`, `Views/`) — no pbxproj editing needed.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: mark pure logic types explicitly `nonisolated`.
- The app is deliberately NOT sandboxed (it needs dotfile access). Do not add entitlements or settings that assume a sandbox.
- UI follows macOS conventions: checkboxes over switches, `Window` (single instance) over `WindowGroup`, native `Table`/`NavigationSplitView`.
