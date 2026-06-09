# Conventions

The authoritative short versions live in the repo: [CLAUDE.md](https://github.com/apps3k-com/EnvVarBuddy/blob/main/CLAUDE.md) (agent rules) and [CONTRIBUTING.md](https://github.com/apps3k-com/EnvVarBuddy/blob/main/CONTRIBUTING.md) (workflow). This page is the human-readable summary.

## Code

- **Native Swift only**: Swift, SwiftUI, AppKit, Apple system frameworks. Third-party dependencies require explicit maintainer approval — the default answer is no.
- macOS idioms: checkboxes (not switches), single `Window` scene, native `Table`/`NavigationSplitView`, menu bar integration.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; pure logic types are `nonisolated`.
- Every user-facing string goes through the String Catalog (English source, German translation).

## Safety invariants (non-negotiable)

- Editable lines round-trip byte-for-byte (`rendered == sourceLine`).
- Ambiguous lines are read-only — never rewritten, never deleted by the app.
- Every write: re-validate against disk → backup → atomic, symlink-safe, permission-preserving.

## Git & releases

- Feature branches off `main` (`feat/…`, `fix/…`, `docs/…`, `ci/…`); squash-merge PRs; PR title = Conventional Commit.
- Conventional Commits enforced by the `commit-msg` hook and CI.
- Versions are bumped by release-please only — never by hand.
- Every feature ships behind a flag registered in `FeatureFlags.swift` **and** `docs/FEATURE_FLAGS.md` (CI-enforced).
- User-visible changes update `docs/wiki/` (EN + DE) in the same PR (CI-enforced; infrastructure-only PRs declare `Docs: none`).

## Tests

- Swift Testing; parser/writer changes require test changes.
- No test ever touches real dotfiles or `$HOME`.
