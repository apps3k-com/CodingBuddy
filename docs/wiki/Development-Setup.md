# Development Setup

## Requirements

- macOS 26+, Xcode 26+
- No package managers, no dependencies — clone and build.

## First run

```bash
git clone https://github.com/apps3k-com/CodingBuddy.git
cd CodingBuddy
./scripts/setup.sh          # activates git hooks (commit-msg, pre-push)
open EnvVarBuddy.xcodeproj
```

CLI build & test:

```bash
xcodebuild -project EnvVarBuddy.xcodeproj -scheme EnvVarBuddy build
xcodebuild test -project EnvVarBuddy.xcodeproj -scheme EnvVarBuddy \
  -destination 'platform=macOS' -only-testing:EnvVarBuddyTests
```

## Project layout

```
EnvVarBuddy/                 app target (synchronized folder — add files, no pbxproj editing)
  Models/ Services/ Stores/ Views/
EnvVarBuddyTests/            Swift Testing unit tests (parser, writer, codec)
Configs/Version.xcconfig     MARKETING_VERSION — managed by release-please, never edit
docs/wiki/                   wiki source of truth (synced on merge)
docs/FEATURE_FLAGS.md        feature-flag registry (enforced)
.githooks/ scripts/          hooks and check scripts
.github/workflows/           CI, enforcement, release-please, wiki sync
```

## Test policy

- Swift Testing (`import Testing`), suites annotated `@MainActor` where they call MainActor-isolated code.
- Tests run against **temp directories only** — `EnvStore`'s home directory and `ShellConfigWriter`'s backup directory are injectable. Never touch the real `$HOME`.

## Debugging tips

- Debug builds run as the **alpha** channel — all feature flags are active.
- Force a flag: `defaults write apps3k.EnvVarBuddy flag.<name> -bool NO`.
- Backups land in `~/Library/Application Support/EnvVarBuddy/Backups/`.
