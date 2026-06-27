# Changelog

## [0.7.0](https://github.com/apps3k-com/CodingBuddy/compare/v0.6.0...v0.7.0) (2026-06-23)


### Features

* **github:** add structured issue forms for the five org issue types ([1444ebd](https://github.com/apps3k-com/CodingBuddy/commit/1444ebd720f09414cda9e7050b550f4571c90a58))
* **issue-forms:** structured issue forms + module/product sync (workflow-template[#20](https://github.com/apps3k-com/CodingBuddy/issues/20)) ([52b612e](https://github.com/apps3k-com/CodingBuddy/commit/52b612e0bf5fe42687c75a1a01c9b976e5ea9525))
* **issue-forms:** structured issue forms + module/product sync (workflow-template[#20](https://github.com/apps3k-com/CodingBuddy/issues/20)) ([bd7a635](https://github.com/apps3k-com/CodingBuddy/commit/bd7a6350d65ee9be5147dff7295cb4ee64ad93c9))
* **projects:** add Epic↔sub-issue sync + finalize issue-form automation ([b8fe8ed](https://github.com/apps3k-com/CodingBuddy/commit/b8fe8ed300826a640d1f330d4311aa04f27f3dad))


### Bug Fixes

* **automation:** harden issue-form + epic-sync per CodeRabbit review ([b0e4884](https://github.com/apps3k-com/CodingBuddy/commit/b0e48845257daf12a26b65ac672c1729b4dbc63a))
* **automation:** paginate label allowlist, surface label failures, name optional ([bf0c50f](https://github.com/apps3k-com/CodingBuddy/commit/bf0c50f046bda8a97175cb7eb08d1bf098209dcd))

## [0.6.0](https://github.com/apps3k-com/CodingBuddy/compare/v0.5.0...v0.6.0) (2026-06-10)


### Features

* add Claude Code section with env editing and MCP overview (COBUD-8) ([#31](https://github.com/apps3k-com/CodingBuddy/issues/31)) ([e31e796](https://github.com/apps3k-com/CodingBuddy/commit/e31e7966d94a8659098038e5839f87aa8791aa76))
* add Craft Agents section with discovery, expiry and resets (COBUD-10) ([#33](https://github.com/apps3k-com/CodingBuddy/issues/33)) ([292dc97](https://github.com/apps3k-com/CodingBuddy/commit/292dc9790e812edacf2b11fc3c7869994bf127e4))
* add Cursor section with mcp.json env editing (COBUD-9) ([#32](https://github.com/apps3k-com/CodingBuddy/issues/32)) ([35d2bbd](https://github.com/apps3k-com/CodingBuddy/commit/35d2bbd4b939a77de7f23c05fcfe511de439f519))
* add structure-preserving JSONPatcher service (COBUD-7) ([15e0381](https://github.com/apps3k-com/CodingBuddy/commit/15e038145a012058cb12eff8fd34eb47a243a7a6))

## [0.5.0](https://github.com/apps3k-com/CodingBuddy/compare/v0.4.0...v0.5.0) (2026-06-10)


### Features

* rename app to CodingBuddy (COBUD-4) ([#24](https://github.com/apps3k-com/CodingBuddy/issues/24)) ([860b730](https://github.com/apps3k-com/CodingBuddy/commit/860b730539b0dd1285969a727fa37b743338fbe5))

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
