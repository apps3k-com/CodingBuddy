# Contributing to CodingBuddy

## Branch workflow

- `main` is protected (org ruleset): changes land via pull request only.
- Work on **feature branches off `main`**: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`, `ci/<topic>`.
- PRs are **squash-merged**; the PR title must itself be a valid Conventional Commit, because it becomes the commit on `main` that release-please reads.

## Conventional Commits (enforced)

Every commit message must follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add grouped view for overridden variables
fix: preserve permissions when writing through symlinks
docs: update user guide for secrets masking
chore|ci|refactor|test|perf: ...
feat!: ... / BREAKING CHANGE: ...   → major bump
```

`feat` bumps the minor version, `fix` the patch version. The `commit-msg` hook rejects anything else — run `./scripts/setup.sh` once per clone to activate the hooks.

## Releases (release-please)

[release-please](https://github.com/googleapis/release-please) runs on every push to `main`. It maintains a release PR that collects the changelog and bumps:

- `CHANGELOG.md`
- `version.txt`
- `MARKETING_VERSION` in `CodingBuddy.xcodeproj/project.pbxproj`

Merging the release PR tags the release. **Never bump versions by hand.**

### Channels

| Channel | Branch | Versioning |
|---|---|---|
| `alpha` | any feature branch / local Debug build | not tagged |
| `beta` | `beta` | prerelease tags (`x.y.z-beta.n`) |
| `stable` | `main` | regular tags (`x.y.z`) |

See [docs/FEATURE_FLAGS.md](docs/FEATURE_FLAGS.md) for how features gate on channels.

## Definition of done (enforced by CI)

A PR that changes app code must:

1. **Build and pass tests** (`CodingBuddyTests`).
2. **Carry conventional commits** (hook + CI check on the PR title).
3. **Register feature flags**: every flag in `CodingBuddy/Services/FeatureFlags.swift` has a section in `docs/FEATURE_FLAGS.md` and vice versa (checked by `scripts/check-feature-flags.sh`).
4. **Update the documentation**: user-visible changes touch the wiki sources under `docs/wiki/` (both `User-Guide-EN.md` and `Benutzerhandbuch-DE.md`) in the same PR. The wiki is synced from `docs/wiki/` to the GitHub wiki automatically on merge. PRs without user-visible changes declare `Docs: none` in the PR description.
5. **Localize**: new user-facing strings exist in `Localizable.xcstrings` with a German translation.

## Code rules

See [CLAUDE.md](CLAUDE.md) — native Swift only, dotfile-safety invariants, Swift Testing, no real `$HOME` in tests.
