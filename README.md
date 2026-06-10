# CodingBuddy

[![Release](https://img.shields.io/github/v/release/apps3k-com/CodingBuddy?include_prereleases)](https://github.com/apps3k-com/CodingBuddy/releases)
[![CI](https://github.com/apps3k-com/CodingBuddy/actions/workflows/ci.yml/badge.svg)](https://github.com/apps3k-com/CodingBuddy/actions/workflows/ci.yml)

A tidy, native macOS app for managing the environment variables that otherwise live buried in your zsh dotfiles — no more hand-editing `~/.zshrc` in the terminal.

## Features

- **Browse & search** every variable from `~/.zshenv`, `~/.zprofile` and `~/.zshrc` in one native window
- **Safe editing** — byte-precise round-trips, automatic timestamped backups, atomic and symlink-safe writes that preserve file permissions
- **Read-only honesty** — complex lines (command substitution, multi-assignments) are displayed but never rewritten
- **Override detection** — sees through zsh load order (`.zshenv → .zprofile → .zshrc`, last assignment wins) and badges shadowed values
- **PATH editor** — edit `:`-separated values as a reorderable list
- **.env import/export** — move variables between projects and dotfiles
- **Secrets stay private** — token/password-like values are masked until you authenticate with Touch ID or your password
- **English & German**, light/dark/auto appearance
- Live reload when the dotfiles change outside the app

## Requirements

- macOS 26 or later
- Xcode 26+ (to build from source)

## Build & run

```bash
git clone https://github.com/apps3k-com/CodingBuddy.git
cd CodingBuddy
./scripts/setup.sh        # activates the repo's git hooks (contributors)
open CodingBuddy.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project CodingBuddy.xcodeproj -scheme CodingBuddy -configuration Release build
```

The app is intentionally **not sandboxed**: it reads and writes your zsh dotfiles directly. Every mutation is preceded by a backup in `~/Library/Application Support/CodingBuddy/Backups/`.

## Safety model (the short version)

CodingBuddy decomposes each assignment into `prefix + export + NAME = quoting + value + suffix` so that editable lines reproduce **byte-for-byte**. Anything it cannot reproduce exactly — `$(command substitution)`, `export A=1 B=2`, unclosed quotes — is shown read-only and left untouched on disk. New variables go into a clearly marked managed block:

```bash
# >>> CodingBuddy >>>
export MY_VAR="value"
# <<< CodingBuddy <<<
```

## Documentation

| | |
|---|---|
| 📘 [User Guide (EN)](https://github.com/apps3k-com/CodingBuddy/wiki/User-Guide-EN) | End-user documentation |
| 📘 [Benutzerhandbuch (DE)](https://github.com/apps3k-com/CodingBuddy/wiki/Benutzerhandbuch-DE) | Endbenutzer-Dokumentation |
| 🔧 [Architecture](https://github.com/apps3k-com/CodingBuddy/wiki/Architecture) | Technical deep-dive |
| 🚩 [Feature flags](docs/FEATURE_FLAGS.md) | Alpha/beta/stable channel concept |

## Contributing

Work happens on feature branches off `main` with [Conventional Commits](https://www.conventionalcommits.org/); releases are cut by [release-please](https://github.com/googleapis/release-please). See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow.
