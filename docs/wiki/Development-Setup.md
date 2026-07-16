# Development Setup

## Requirements

- macOS 26+, Xcode 26+
- No package managers, no dependencies — clone and build.

## First run

```bash
git clone https://github.com/apps3k-com/CodingBuddy.git
cd CodingBuddy
./scripts/setup.sh          # activates git hooks (commit-msg, pre-push)
open CodingBuddy.xcodeproj
```

CLI build & test:

```bash
xcodebuild -project CodingBuddy.xcodeproj -scheme CodingBuddy build
xcodebuild test -project CodingBuddy.xcodeproj -scheme CodingBuddy \
  -destination 'platform=macOS' -only-testing:CodingBuddyTests
./scripts/check-docstring-coverage.sh
```

## Project layout

```
CodingBuddy/                 app target (synchronized folder — add files, no pbxproj editing)
  Models/ Services/ Stores/ Views/
CodingBuddyTests/            Swift Testing unit tests (parser, writer, codec)
Configs/Version.xcconfig     MARKETING_VERSION — managed by release-please, never edit
docs/wiki/                   wiki source of truth (synced on merge)
docs/FEATURE_FLAGS.md        feature-flag registry (enforced)
.githooks/ scripts/          hooks and check scripts
.github/workflows/           CI, enforcement, release-please, wiki sync
```

## Test policy

- Swift Testing (`import Testing`), suites annotated `@MainActor` where they call MainActor-isolated code.
- Tests run against **temp directories only** — `EnvStore`'s home directory and `ShellConfigWriter`'s backup directory are injectable. Never touch the real `$HOME`.

## Docstring coverage gate

The repository enforces at least 90% documentation coverage for eligible Swift declarations in the app target:

```bash
./scripts/test-docstring-coverage.sh            # deterministic checker fixtures
./scripts/check-docstring-coverage.sh          # readable report and missing locations
./scripts/check-docstring-coverage.sh --json   # stable single-line JSON for automation
```

The report's `documented / eligible` ratio is the enforced metric. `missing` identifies the remaining denominator, while `exclusions` explains non-eligible declarations and files by category and `excluded_paths` lists every excluded test or generated path. A `///` block counts only when at least one line contains non-whitespace documentation text. Generated source is excluded only when an exact `@generated` marker appears on its own line in a leading header comment before the first code token; similar prose, string content, and later comments remain eligible. Fixture tests cover these positive and negative cases along with multiline declarations, protocol requirements, attributes, enum cases, local declarations, SwiftUI `body`, and lexical tokens inside strings and comments. A nonzero exit means the ratio is below `minimum_percent`; add meaningful `///` comments at the listed source locations and rerun the command. Do not lower the threshold in CI.

## Debugging tips

- Debug builds run as the **alpha** channel — all feature flags are active.
- Force a flag: `defaults write apps3k.CodingBuddy flag.<name> -bool NO`.
- Backups land in `~/Library/Application Support/CodingBuddy/Backups/`.
