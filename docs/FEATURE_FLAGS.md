# Feature flags & release channels

EnvVarBuddy ships through three channels. Features are introduced behind a flag
in [`EnvVarBuddy/Services/FeatureFlags.swift`](../EnvVarBuddy/Services/FeatureFlags.swift)
and promoted as they mature.

## Channels

| Channel | Build | Versioning | Who |
|---|---|---|---|
| **alpha** | local Debug builds, feature branches | not tagged | developers |
| **beta** | release-please prereleases from the `beta` branch | `x.y.z-beta.n` | early testers |
| **stable** | release-please releases from `main` | `x.y.z` | everyone |

The running channel is derived from the build: Debug ⇒ `alpha`; a marketing
version containing `-beta` ⇒ `beta`; otherwise `stable`. No manual configuration.

## Flag lifecycle

1. **Introduce** — new feature lands behind a flag with `maturity: .alpha`.
   Only visible in Debug builds.
2. **Promote to beta** — set `maturity: .beta`; ship via a `beta` prerelease.
3. **Promote to stable** — set `maturity: .stable`; ship via a `main` release.
4. **Retire** — once a flag has been stable for a release cycle, remove the
   flag and its gating code (and delete its section here).

A flag is enabled when `ReleaseChannel.current.rank <= maturity.rank` — alpha
builds see everything, stable builds only mature features.

## Local overrides

Any flag can be forced on or off for testing:

```bash
defaults write apps3k.EnvVarBuddy flag.groupedOverridesView -bool YES
defaults delete apps3k.EnvVarBuddy flag.groupedOverridesView   # back to channel default
```

## Enforcement

`scripts/check-feature-flags.sh` (pre-push hook + CI) fails when a flag exists
in code without a `### \`flagName\`` section in this file, or vice versa.

## Registry

### `groupedOverridesView` — maturity: stable

Grouped display of overridden variables: the effective assignment is shown as
the parent row, shadowed assignments expand beneath it.

### `secretsProtection` — maturity: stable

Masks token/password-like values and requires Touch ID / password
authentication before revealing or copying them. Treated as a kill-switch
flag: it defaults to ON in every channel and only exists so a critical
regression could be disabled via local override.

### `envImportExport` — maturity: stable

Import variables from `.env` files (with preview) and export the visible
variables as `.env`.

### `mcpAuthManager` — maturity: stable

Manages the `~/.mcp-auth` credential cache of `mcp-remote`-connected MCP
servers: lists entries with server resolution (md5 of configured URLs) and
token status, resets single servers or everything to the Trash, and edits the
raw credential JSON after Touch ID / password authentication.
