# Feature flags & release channels

CodingBuddy ships through three channels. Features are introduced behind a flag
in [`CodingBuddy/Services/FeatureFlags.swift`](../CodingBuddy/Services/FeatureFlags.swift)
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
defaults write apps3k.CodingBuddy flag.hideOverriddenVariables -bool YES
defaults delete apps3k.CodingBuddy flag.hideOverriddenVariables   # back to channel default
```

## Enforcement

`scripts/check-feature-flags.sh` (pre-push hook + CI) fails when a flag exists
in code without a `### \`flagName\`` section in this file, or vice versa.

## Registry

### `aiToolsCodex` — maturity: alpha

Codex section in the sidebar: edit the variables in `~/.codex/mcp.env`
(values masked, file kept at mode 600) and see which MCP servers in
`config.toml` reference which environment variables — including a warning for
referenced-but-undefined names.

### `aiToolsClaudeCode` — maturity: alpha

Claude Code section in the sidebar: edit the `env` blocks of
`~/.claude/settings.json` and `settings.local.json` (value-precise JSON
patching, masked secrets, automatic backups) and see the MCP servers from
`~/.claude.json` and the projects' `.mcp.json` files — read-only.

### `aiToolsCursor` — maturity: alpha

Cursor section in the sidebar: edit the per-server `env` values in
`~/.cursor/mcp.json` (value-precise JSON patching, masked secrets, automatic
backups); the server list itself is read-only.

### `aiToolsCraftAgent` — maturity: alpha

Craft Agents section in the sidebar: read-only discovery of `~/.craft-agent/`
(LLM connections, token files with expiry status, the encrypted credential
store described by size/date only) plus reversible resets to the Trash.

### `hideOverriddenVariables` — maturity: stable

Toolbar toggle that hides assignments shadowed by a later one (zsh load
order), so only the effective values stay visible; the `.env` export follows
the visible set. Replaces the retired `groupedOverridesView` feature and is
therefore stable from the start.

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

### `agentDoctor` — maturity: alpha

Read-only diagnostics for local agent setup. It checks missing tool
directories, missing managed zsh startup files, invalid JSON configuration
files, Codex MCP environment variables referenced by config but missing from
`~/.codex/mcp.env`, credential files with unsafe permissions, and expired or
incomplete MCP Auth entries.

v1 only reports findings: no network reachability checks, process restarts,
auto-fixes, or secret value display.

### `agentContextInspector` — maturity: alpha

Read-only inspector for a selected repository folder. It deterministically
checks a fixed allowlist of agent context files (`AGENTS.md`, `CLAUDE.md`,
`.cursor/rules`, `.mcp.json`, `.codex` project config, and obvious developer
documentation) and reports file-system metadata plus simple signals such as
missing governance files, both governance files being present, empty files,
large files, project-local MCP config, and Codex project config.

v1 does not edit files, recurse through the repository, or interpret policy
text semantically. It is a context inventory, not a natural-language rules
reviewer.

### `mcpServerInventory` — maturity: alpha

Read-only inventory of MCP server definitions across Codex, Claude Code, and
Cursor. It normalizes server name, source tool, scope/project path, transport,
safe command or URL summary, referenced environment variable names, header keys,
source file, and Codex variables that are referenced but missing from
`~/.codex/mcp.env`.

v1 does not edit, install, or probe MCP servers and never displays secret
values from environment blocks, URL credentials, query strings, or token-like
command arguments.
