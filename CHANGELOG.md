# Changelog

## 0.1.0 (2026-06-10)

Initial baseline.

### Features

- Browse and search environment variables from `~/.zshenv`, `~/.zprofile`, `~/.zshrc`
- Safe editing with byte-precise round-trips, automatic backups, atomic symlink-safe writes
- Read-only handling of complex lines (command substitution, multi-assignments)
- Override detection following zsh load order
- PATH-style segment editor
- `.env` import with preview and export of visible variables
