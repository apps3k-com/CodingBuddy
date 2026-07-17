# Conventions

The authoritative short versions live in the repo: [CLAUDE.md](https://github.com/apps3k-com/CodingBuddy/blob/main/CLAUDE.md) (agent rules) and [CONTRIBUTING.md](https://github.com/apps3k-com/CodingBuddy/blob/main/CONTRIBUTING.md) (workflow). This page is the human-readable summary.

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

## Documentation quality

- Eligible app declarations require `///` documentation; repository coverage must remain at or above 90%.
- Run `./scripts/check-docstring-coverage.sh` locally. Add `--json` for machine-readable totals, exclusions, excluded paths, coverage, threshold, and pass/fail state.
- Run `./scripts/test-docstring-coverage.sh` after changing the checker. CI executes these deterministic lexer and policy fixtures before enforcing the repository threshold.
- The denominator covers the app module's types, enum cases, functions, initializers, subscripts, type aliases, associated types, operators, and properties.
- Empty or whitespace-only `///` blocks are missing documentation; at least one line must contain meaningful text.
- Tests, generated source with an exact `@generated` marker on its own line in leading header comments before code, local declarations, private implementation details, overrides that inherit their contract, and SwiftUI's standard `body` property are excluded. Generator-like prose, strings, and comments after code do not exclude files. The checker reports every exclusion category and excluded file path so the metric cannot silently shrink.
- Braces and comment markers inside normal, raw, or multiline Swift strings and nested block comments are ignored for scope tracking.
