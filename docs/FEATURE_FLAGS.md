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

### `defaultEditorPreference` — maturity: alpha

Settings preference for the external editor CodingBuddy uses when it owns an
open action for Markdown, JSON, YAML, shell, dotfile-style, and other
text-like repository files. The preference stores the selected macOS
application metadata in UserDefaults and falls back to Launch Services'
system default when no editor is selected or the selected app is unavailable.

v1 applies to CodingBuddy-owned repository file actions such as Agent Context
entries. It does not change Finder reveal actions, browser URLs, backup
restore flows, or any file writing behavior.

### `collapsibleSidebarSections` — maturity: alpha

Top-level sidebar destinations are grouped by user task: Focus, Environment,
Agent Tools, Health & Security, Repositories, and Maintenance. The groups use native
macOS expandable sections, and both collapsed groups and the selected
destination are stored in app preferences so the sidebar keeps its working
context across window recreation and relaunch.

v1 keeps all groups expanded for new users and preserves the current sidebar
selection even when its parent group is collapsed. Legacy group identifiers
are migrated to the closest task-oriented group.

### `packageMaintenance` — maturity: alpha

Adds **Maintenance → Software Updates** for a global Homebrew, npm, and pnpm
inventory. Providers discover one active executable each, keep successful
snapshots visible when another provider fails, and expose compatible or latest
updates through a confirmation plan and sequential native process execution.

v1 uses `Foundation.Process` with absolute executable paths and separated
arguments only. It never invokes a shell, `sudo`, background updates,
installation, removal, or pin management. Users can override each detected
executable in Settings. Release notes are best-effort and load only for the
selected package.

### `explainableGuidance` — maturity: alpha

Introduces the shared, deterministic explanation contract used as CodingBuddy
features migrate to plain-language guidance. A guidance section separates what
a finding means, why it matters, its likely consequence, one recommended next
step, and collapsed technical evidence. It also provides a curated developer
glossary for recurring terms such as CI, pull requests, MCP, OAuth, Git working
state, and package-management concepts.

The foundation does not scan additional files, call a network service, generate
AI advice, or execute an action by itself. Feature-specific mappings and action
routing remain owned by the feature that produced the finding, and unavailable
actions must explain why they cannot be run. Healthy or informational states
can explicitly say that no action is needed without presenting a disabled
control.

### `attentionCockpit` — maturity: alpha

Adds **Focus → Attention Queue**, a deterministic cross-repository ordering of
the pull requests already loaded by Agent PR Monitor. The queue shows one
recommended next item, calm urgency bands instead of an opaque score, a plain
reason for the ordering, and the existing detailed guidance and safe action.
The destination is visible only while both `agentPRMonitor` and
`explainableGuidance` are enabled.

v1 adds no second repository registry, network client, task database,
notification service, or background process. Repository-wide refresh problems
are represented once instead of repeated for every stale PR, while successful
snapshots from other repositories remain visible. Actions use Agent PR
Monitor's typed read-only routes for opening a PR, refreshing, or opening
Settings.

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

### `repoReadinessChecklist` — maturity: alpha

Read-only checklist for a selected repository folder before agentic coding
work starts. It runs deterministic local checks for agent governance, README
coverage, documented build/test commands, contribution workflow docs, GitHub
issue/PR templates, Swift feature-flag docs where relevant, setup scripts and
hooks, CI workflows, and lightweight `.git` in-progress markers.

v1 is advisory only: it never writes repository files, calls GitHub, shells out
to `git`, or validates whether commands actually pass. Warnings are prompts to
improve handoff quality, not merge blockers by themselves.

### `mcpServerInventory` — maturity: alpha

Read-only inventory of MCP server definitions across Codex, Claude Code, and
Cursor. It normalizes server name, source tool, repository/workspace name,
scope/project path, transport, safe command or URL summary, referenced
environment variable names, header keys, source file, and Codex variables that
are referenced but missing from
`~/.codex/mcp.env`.

v1 does not edit, install, or probe MCP servers and never displays secret
values from environment blocks, URL credentials, query strings, or token-like
command arguments.

### `agentPRMonitor` — maturity: alpha

Read-only monitor for open GitHub pull requests across a watched repository
list. It classifies each row as likely agent, likely human, or unknown, uses a
Keychain-stored fine-grained GitHub token configured in Settings → Security,
and shows the owning repository, linked closing issues, CI/check status, review
decision, unresolved review-thread findings, rate-limit state, and advisory
merge readiness. Repository setup loads repositories visible to the saved token
through GitHub's REST API, caps pagination for bounded UI work, supports adding
and removing multiple watched repositories, and keeps an `owner/name` manual
fallback for recovery when listing is unavailable.

v1 never comments, approves, resolves threads, merges pull requests, mutates
GitHub Projects, shells out to `gh`/`git`, or stores token values outside
Keychain. Refresh failures are scoped per repository where possible, so one
denied or rate-limited repository does not hide successful rows from other
watched repositories. REST fallback is limited to missing status/check data
when GraphQL does not return a status rollup.

### `pullRequestReviewDesk` — maturity: alpha

Enables the native GitHub pull request workbench for one focused review at a
time. The Review Desk fully loads summary, checks, approvals, top-level
conversation comments, and inline review threads before it enables actions.
Replies and thread resolution use focused controls; Ready for Review and merge
use fresh state-bound preflights and risk-based confirmation.

GitHub App Device Flow is the only write-capable authorization source. Existing
fine-grained personal access tokens remain read-only for migration and monitor
compatibility. The destination is visible only while `agentPRMonitor` is also
enabled.

### `backupBrowser` — maturity: alpha

Safety section for browsing CodingBuddy's managed backup directory. It lists
timestamped backups for zsh startup files, Codex `mcp.env`, Claude Code
settings files, and Cursor `mcp.json`; shows a redacted Current/Backup preview;
and restores supported targets through the same safe writer that creates a new
backup of the current file before replacing it.

v1 only restores backups whose filename can be mapped to a known
CodingBuddy-managed target. Unknown backup names remain preview-only because
the historical backup filename format does not store the full original path.
