# Changelog

## [0.3.0](https://github.com/apps3k-com/EnvVarBuddy/compare/v0.2.0...v0.3.0) (2026-06-10)


### Features

* manage MCP auth credentials (~/.mcp-auth) in the app ([#13](https://github.com/apps3k-com/EnvVarBuddy/issues/13)) ([af0245f](https://github.com/apps3k-com/EnvVarBuddy/commit/af0245f94f3f1429b216ca28c86b1b36908247dc))


### Bug Fixes

* address correctness review findings ([#11](https://github.com/apps3k-com/EnvVarBuddy/issues/11)) ([3172b93](https://github.com/apps3k-com/EnvVarBuddy/commit/3172b93398153bc4c3472eafedadb23e8226fe07))
* keep table selection when the variable list reloads ([#14](https://github.com/apps3k-com/EnvVarBuddy/issues/14)) ([64a6a1a](https://github.com/apps3k-com/EnvVarBuddy/commit/64a6a1ade67c48d5827bba7b14ac558a9d2d40a7))

## [0.2.0](https://github.com/apps3k-com/EnvVarBuddy/compare/v0.1.0...v0.2.0) (2026-06-09)


### Features

* add File menu import/export and language-aware Help menu ([#9](https://github.com/apps3k-com/EnvVarBuddy/issues/9)) ([b325f65](https://github.com/apps3k-com/EnvVarBuddy/commit/b325f65ea35743b7e60f33d5ac053752ccf94ef3))
* add grouped view for overridden variables ([#8](https://github.com/apps3k-com/EnvVarBuddy/issues/8)) ([3292a48](https://github.com/apps3k-com/EnvVarBuddy/commit/3292a483499c47757979685efb199ddaa4490b2b))
* localize the app (English base, German) and add settings ([#5](https://github.com/apps3k-com/EnvVarBuddy/issues/5)) ([96c3d52](https://github.com/apps3k-com/EnvVarBuddy/commit/96c3d5281fbf3a8b01e14a6c0d2259b05f788b18))
* mask secret values behind Touch ID / password authentication ([#7](https://github.com/apps3k-com/EnvVarBuddy/issues/7)) ([673e296](https://github.com/apps3k-com/EnvVarBuddy/commit/673e296118c49c6d141a42817d1ba4d45eed1f6f))

## 0.1.0 (2026-06-10)

Initial baseline.

### Features

- Browse and search environment variables from `~/.zshenv`, `~/.zprofile`, `~/.zshrc`
- Safe editing with byte-precise round-trips, automatic backups, atomic symlink-safe writes
- Read-only handling of complex lines (command substitution, multi-assignments)
- Override detection following zsh load order
- PATH-style segment editor
- `.env` import with preview and export of visible variables
