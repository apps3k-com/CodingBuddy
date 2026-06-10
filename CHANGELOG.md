# Changelog

## [0.4.0](https://github.com/apps3k-com/EnvVarBuddy/compare/v0.3.0...v0.4.0) (2026-06-10)


### Features

* hide overridden variables instead of grouping them ([#18](https://github.com/apps3k-com/EnvVarBuddy/issues/18)) ([ac7a6d5](https://github.com/apps3k-com/EnvVarBuddy/commit/ac7a6d59b716afd3588320302ab790cdd0923ddc))


### Bug Fixes

* mark pure model and parser types nonisolated ([#15](https://github.com/apps3k-com/EnvVarBuddy/issues/15)) ([1d567ff](https://github.com/apps3k-com/EnvVarBuddy/commit/1d567ff727a0c5748fffef4346f81b361f2a9758))
* present settings as a sheet over the main window ([#19](https://github.com/apps3k-com/EnvVarBuddy/issues/19)) ([81b9225](https://github.com/apps3k-com/EnvVarBuddy/commit/81b9225647fe451470dce77d87f7e6c0e341544d))
* reset to the system appearance when switching back to Auto ([#17](https://github.com/apps3k-com/EnvVarBuddy/issues/17)) ([db86bfa](https://github.com/apps3k-com/EnvVarBuddy/commit/db86bfad4d88a30e1e57ff4b5e8950d191f4c69d))
* silence spurious MainActor warnings on isUnquotedSafe in Xcode ([#20](https://github.com/apps3k-com/EnvVarBuddy/issues/20)) ([0317510](https://github.com/apps3k-com/EnvVarBuddy/commit/0317510617f04c730d2bf4fb96bfdcd2200d2209))
* unify the settings sheet background ([#21](https://github.com/apps3k-com/EnvVarBuddy/issues/21)) ([b7913ec](https://github.com/apps3k-com/EnvVarBuddy/commit/b7913ec2f5202937958cd1c9c4093cacf02a7507))

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
