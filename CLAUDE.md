# CLAUDE.md — CodingBuddy

Native macOS app (SwiftUI) for managing environment variables in zsh dotfiles.
Deep documentation lives in the [wiki](https://github.com/apps3k-com/CodingBuddy/wiki) — this file stays slim.

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
- Every new feature sits behind a flag in `CodingBuddy/Services/FeatureFlags.swift` and is documented in `docs/FEATURE_FLAGS.md`.
- User-visible changes update the wiki sources under `docs/wiki/` (EN + DE) in the same PR.

### Project management (Plane) — source of truth
- All work is tracked in the Plane project **CodingBuddy** (identifier `COBUD`):
  https://app.plane.so/apps3k/projects/703acd2a-ef88-4165-8394-34b2cc48a6ab/issues
- No work without a work item: every change starts from (or first creates) a COBUD item.
  New ideas, findings and bugs become backlog/intake items instead of getting lost.
- **Every commit message and PR title references the work item(s) it contains or relates
  to** — `fix: keep selection (COBUD-12)` or `(COBUD-12, COBUD-13)`. Enforced by the
  commit-msg hook and CI; release-please commits (`chore(main): release …`) are exempt.
- Keep states current while working: `Todo` → `In Progress` (branch started) → `PR open`
  (PR created) → `In Review` (squash-merged, awaiting user verification) → `Done` (user
  confirmed) → `Deployed` (shipped in a release). Use `Re-opened` for bounce-backs.
- After opening a PR, set up a monitor and wait for the automated reviews (CodeRabbit,
  cubic). Handle **every finding individually**: verify it, then either fix it or reject
  it with a reasoned reply **in the review thread** — the reviewers learn from replies.
  A PR may only be merged once CI is green and every finding is fixed or answered.

## Build & test

```bash
xcodebuild -project CodingBuddy.xcodeproj -scheme CodingBuddy build
xcodebuild test -project CodingBuddy.xcodeproj -scheme CodingBuddy \
  -destination 'platform=macOS' -only-testing:CodingBuddyTests
./scripts/setup.sh   # once per clone: activates the git hooks
```

## Project conventions
- Xcode synchronized folders: create new files in the matching folder (`Models/`, `Services/`, `Stores/`, `Views/`) — no pbxproj editing needed.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: mark pure logic types explicitly `nonisolated`.
- The app is deliberately NOT sandboxed (it needs dotfile access). Do not add entitlements or settings that assume a sandbox.
- UI follows macOS conventions: checkboxes over switches, `Window` (single instance) over `WindowGroup`, native `Table`/`NavigationSplitView`.
