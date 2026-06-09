# Architecture Decision Records

One entry per significant decision. Template: **Context · Decision · Consequences · Date · Status**.

---

## ADR-001: No App Sandbox

- **Context:** The app's purpose is reading and writing zsh dotfiles in `$HOME`; the App Sandbox forbids that. Security-scoped bookmarks would force users through open panels for their own dotfiles.
- **Decision:** Ship unsandboxed with hardened runtime enabled. No App Store distribution planned.
- **Consequences:** Direct dotfile access, simple UX; not App-Store-eligible. Safety is provided at the application layer (backups, atomic writes, read-only policy).
- **Date:** 2026-06-09 · **Status:** accepted

## ADR-002: Byte-precise round-trip, read-only fallback

- **Context:** Rewriting shell config lines risks corrupting user dotfiles; escaping/unescaping cycles are a classic source of subtle breakage.
- **Decision:** Decompose lines so editable ones reproduce byte-for-byte; store raw (unescaped) value text; mark everything ambiguous read-only instead of trying to be clever.
- **Consequences:** Some lines can't be edited in-app (honest limitation); zero normalization surprises; the invariant is testable (`rendered == sourceLine`).
- **Date:** 2026-06-09 · **Status:** accepted

## ADR-003: Version lives in `Configs/Version.xcconfig`

- **Context:** release-please needs a stable text location to bump the version. Xcode rewrites `project.pbxproj` and drops custom comments, which would destroy `x-release-please-version` markers.
- **Decision:** `MARKETING_VERSION` moves to an xcconfig attached as base configuration; release-please's generic updater bumps it there.
- **Consequences:** Version bumps survive Xcode project edits; one extra file; pbxproj contains no version.
- **Date:** 2026-06-10 · **Status:** accepted

## ADR-004: Wiki source of truth in `docs/wiki/`

- **Context:** Docs must be enforceable in PRs (CI can't check the wiki repo) and reviewable alongside code.
- **Decision:** Wiki pages live in the main repo under `docs/wiki/` and are force-synced to the GitHub wiki on merge. Direct wiki edits are overwritten.
- **Consequences:** Docs changes are part of code review and CI enforcement; the wiki is read-only in practice.
- **Date:** 2026-06-10 · **Status:** accepted

## ADR-005: Release channels derived from the version string

- **Context:** Alpha/beta/stable channels need a build-time signal. Custom Info.plist keys with `GENERATE_INFOPLIST_FILE` are awkward.
- **Decision:** Debug ⇒ alpha; marketing version containing `-beta` ⇒ beta; otherwise stable. Channels thus follow release-please prerelease versioning automatically.
- **Consequences:** Zero configuration; channel and version can never disagree; renaming channels requires a code change.
- **Date:** 2026-06-10 · **Status:** accepted
