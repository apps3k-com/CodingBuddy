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

## Project tracking

All work starts as a GitHub issue in the org Project. Use native sub-issues for work that belongs under an Epic. The PR body must link the issue with a GitHub closing keyword such as `Closes #12`; this is what CI enforces and what lets GitHub close the issue and advance the Project status on merge. Individual commits may include `(#12)`, but issue linking is intentionally checked at PR level.

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
3. **Link its GitHub issue** with a closing keyword in the PR body, e.g. `Closes #12`.
4. **Register feature flags**: every flag in `CodingBuddy/Services/FeatureFlags.swift` has a section in `docs/FEATURE_FLAGS.md` and vice versa (checked by `scripts/check-feature-flags.sh`).
5. **Update the documentation**: user-visible changes touch the wiki sources under `docs/wiki/` (both `User-Guide-EN.md` and `Benutzerhandbuch-DE.md`) in the same PR. The wiki is synced from `docs/wiki/` to the GitHub wiki automatically on merge. PRs without user-visible changes declare `Docs: none` in the PR description.
6. **Localize**: new user-facing strings exist in `Localizable.xcstrings` with a German translation.
7. **Maintain Swift documentation coverage**: at least 90% of eligible app declarations have an adjacent `///` doc comment (checked by `scripts/check-docstring-coverage.sh`).

## Code rules

See [CLAUDE.md](CLAUDE.md) — native Swift only, dotfile-safety invariants, Swift Testing, no real `$HOME` in tests.

## Swift docstring coverage

Run the same deterministic check used by CI:

```bash
./scripts/test-docstring-coverage.sh
./scripts/check-docstring-coverage.sh
./scripts/check-docstring-coverage.sh --json
```

The denominator is the app target's module-level and member declarations: types, enum cases, functions, initializers, subscripts, type aliases, associated types, operators, and stored or computed properties. A declaration is documented when a contiguous `///` comment with at least one non-whitespace character precedes it; declaration attributes may appear between the comment and declaration. Empty or whitespace-only `///` blocks do not count.

The gate deliberately excludes test files, generated files carrying an exact `@generated` marker on its own line in leading header comments before the first code token, local declarations, `private`/`fileprivate` implementation details, inherited `override` declarations, and SwiftUI's conventional `var body: some View`. Generated wording in prose, strings, or comments after code does not exclude a file. These exclusions avoid rewarding repetitive comments that do not explain CodingBuddy's maintained module contract. The checker lexes normal, raw, and multiline Swift strings plus nested block comments before tracking declaration scopes, so braces and comment markers in literal content cannot change the metric. `test-docstring-coverage.sh` verifies this behavior and the exclusion policy with deterministic fixtures before CI measures the repository.

All exclusion and coverage counts are present in the JSON output, and both JSON and human output list every excluded test or generated path. The command exits nonzero when coverage is below 90%; use `--minimum N` or `DOCSTRING_MINIMUM=N` only for local diagnostics, not to weaken CI. `--source-root` exists solely to run isolated checker fixtures.
