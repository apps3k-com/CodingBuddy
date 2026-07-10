# User Guide (EN)

CodingBuddy is a native macOS app for managing the environment variables that live in your zsh dotfiles (`~/.zshenv`, `~/.zprofile`, `~/.zshrc`) — without opening a terminal.

## Browsing variables

- The **sidebar** groups destinations by task: **Focus**, **Environment**, **Agent Tools**, **Health & Security**, **Repositories**, and **Maintenance**. Environment contains *All Variables* plus one entry per dotfile with a count badge. Files that don't exist yet are dimmed; adding a variable to one creates it.
- Top-level sidebar groups can be collapsed and expanded. CodingBuddy remembers both the collapsed groups and the last selected destination.
- The **table** lists name, value and source file. Use the search field (⌘F) to filter by name or value.
- A 🔒 **lock icon** marks complex lines (command substitution like `$(date)`, multi-assignments like `export A=1 B=2`). CodingBuddy shows them honestly but never rewrites them — edit those in your editor of choice.
- An orange **overridden** badge means a later assignment wins: zsh loads `.zshenv → .zprofile → .zshrc`, and within a file the last assignment of a name takes effect.
- The **Hide overridden** toolbar toggle (eye icon) hides the shadowed assignments so only the values that actually take effect remain visible — the list keeps its file/line order. The *.env export* exports what you see, so it then contains only the effective assignments.

## Editing

- **Double-click** a row (or right-click → *Edit…*) to change name or value. Validation runs live; values are written verbatim — `$VARIABLES` stay unexpanded.
- **＋** in the toolbar adds a new variable. New variables are written into a clearly marked block at the end of the chosen file:

  ```bash
  # >>> CodingBuddy >>>
  export MY_VAR="value"
  # <<< CodingBuddy <<<
  ```

  Blocks created before the rename (`# >>> EnvVarBuddy >>>`) are still recognized and reused.

- **Values with `:`** (like `PATH`) offer *Edit as list*: reorder, add and remove segments by drag & drop.
- **Delete** (right-click → *Delete…*) removes the line after confirmation.

## Safety net

Before every change CodingBuddy writes a timestamped backup to
`~/Library/Application Support/CodingBuddy/Backups/` (the last 20 per file are kept). Writes are atomic, follow symlinks (dotfile managers stay intact) and preserve file permissions. If a file changed outside the app mid-edit, the write is refused and the view reloads.

The **Maintenance → Backups** entry (alpha) lists those backups for zsh dotfiles and
supported agent config/env files (`~/.codex/mcp.env`, Claude Code settings,
Cursor `mcp.json`). Select a backup to compare a redacted **Backup** preview
with the current target. **Restore…** writes the selected backup through the
same safe writer, so the current file is backed up again before it is replaced.
Backups that cannot be mapped to a known CodingBuddy-managed target stay
preview-only.

## Import & export

- **Import from .env…** (File menu or toolbar, ⇧⌘I) reads a dotenv file, shows a preview where you pick the entries (duplicates are flagged), and appends them to the managed block of a file of your choice. The import button names the selected count, such as **Import 1 Variable** or **Import 2 Variables**.
- **Export visible as .env…** (File menu or toolbar, ⇧⌘E) writes the variables currently shown in the table to a `.env` file.

## Help menu

**Help → CodingBuddy Help** (⌘?) opens this documentation in your app language — the German Benutzerhandbuch when the app runs in German, this guide otherwise. **Help → Documentation (Wiki)** opens the full wiki.

## Focus and Attention Queue

The **Focus → Attention Queue** entry (alpha) turns the pull requests already
loaded by Agent PR Monitor into one cross-repository next-action list. It does
not create another repository list or fetch GitHub independently.

- **Act now** contains confirmed blockers such as failed CI, requested changes,
  unresolved current review findings, or missing GitHub visibility.
- **Next** contains bounded follow-up without a confirmed immediate blocker,
  such as a draft or a repository snapshot that should be refreshed.
- **Waiting** means another process or person must finish first. Running CI,
  pending review, an active refresh, and GitHub rate limiting do not create
  false urgency.
- **Ready** stays visible for completion or merge follow-up but never outranks
  actionable work.

The first row is the recommendation. Select any row to see **Why now**, the
plain explanation, the consequence, and the existing safe next action. A
repository-wide refresh problem appears once instead of being repeated for
every stale PR. Valid snapshots from other watched repositories remain in the
queue.

v1 limits: the queue does not snooze work, send notifications, run in the
background, mutate GitHub, or rank Health, Security, and package signals yet.
Those sources will join the same deterministic queue after their guidance
contracts land.

## Secrets stay masked

Variables whose names look like credentials (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`, anything with `TOKEN`, `KEY`, `SECRET`, `PASSWORD`, `AUTH`, …) show `••••••••` instead of their value.

- Click the **lock button** in the toolbar (or just try to edit/copy a masked value) and authenticate with **Touch ID or your account password** to reveal them.
- The unlock expires automatically — configure the duration in *Settings → Security* (1/5/15 minutes or until CodingBuddy quits). The lock button re-masks immediately.
- Copying a value or line, editing, and `.env` export of masked variables all require authentication first.

## MCP credentials (~/.mcp-auth)

The **Health & Security → MCP Auth** sidebar section manages the OAuth cache that `mcp-remote` keeps for remote MCP servers — the directory you previously had to wipe with `rm -rf ~/.mcp-auth`.

- Each entry is one server. CodingBuddy resolves the cryptic file hashes back to server URLs by matching them against your Claude configuration (`~/.claude.json`, Claude Desktop config); unresolved entries show their hash plus the OAuth scope as a hint.
- The **status column** shows whether the access token is still active (with its estimated expiry), expired, or the entry is incomplete (a login that never finished).
- **Reset Entry…** moves just that server's files to the **Trash** after a confirmation that names the server and the consequence — surgical, reversible, and the next connection simply re-runs the OAuth flow. **Reset All…** uses a separate all-credentials confirmation for everything (the GUI equivalent of `rm -rf ~/.mcp-auth`, but undoable).
- **View Files…** (or double-click) opens the credential files with all token values masked. After authenticating with Touch ID or your password you can edit the raw JSON; invalid JSON is rejected on save.
- When `~/.mcp-auth` is missing or empty, the empty state points you back to connecting an OAuth-enabled MCP server first. CodingBuddy lists cached credentials after `mcp-remote` creates them.
- No app restart is needed: the view live-reloads when `mcp-remote` rewrites the files.

## AI tools

### Explainable guidance foundation

CodingBuddy is introducing a shared explanation pattern for technical findings.
As each alpha area adopts it, its inspector will separate **What this means**,
**Why it matters**, **Recommended next step**, and collapsed **Technical
details**. Repeated developer terms link to a short built-in glossary instead
of assuming prior Git, CI, MCP, OAuth, or package-manager knowledge.

The guidance is curated and deterministic. It does not send findings to an AI
service, invent actions, or bypass an area's existing confirmation and safety
flow. When CodingBuddy cannot perform a recommended action, it explains why
instead of presenting an inert control. A healthy state can say that no action
is needed without making it look blocked.

### Agent Doctor

The **Agent Doctor** entry (alpha) is a read-only health check for local agent setup. It flags:

- Missing tool directories.
- Missing managed zsh startup files (`~/.zshenv`, `~/.zprofile`, `~/.zshrc`).
- Invalid JSON configuration files.
- Codex MCP environment variables referenced by config but missing from `~/.codex/mcp.env`.
- Credential files whose permissions are too open.
- Expired or incomplete entries in `~/.mcp-auth`.

The compact table keeps severity, finding and tool visible. Select a finding to inspect its full source and explanation, then use **Open Tool** or **Open Source** for direct follow-up.

v1 limits: Agent Doctor does not test network reachability, restart agent processes, apply auto-fixes, or show secret values.

### Agent Context

The **Repositories → Agent Context** entry (alpha) is a read-only inspector for one repository folder. It helps you see which instruction and setup files an agent would likely pick up before you start a coding session.

- Choose a repository folder; CodingBuddy remembers the last selected folder.
- The table checks a fixed allowlist: `AGENTS.md`, `CLAUDE.md`, `.cursor/rules`, `.mcp.json`, `.codex` project config and obvious developer documentation such as `README.md`, `CONTRIBUTING.md` and development setup docs.
- Signals highlight missing `AGENTS.md` or `CLAUDE.md`, both governance files being present, empty files, unusually large files and project-local MCP/Codex configuration.
- Use **Open** or **Reveal in Finder** for native follow-up. **Open** uses your configured default editor for text-like files; the inspector never edits these files.

v1 limits: Agent Context is deterministic discovery only. It does not recurse through the repository, compare policy text semantically, decide which rule wins, or run natural-language analysis over instructions.

### Repo Readiness

The **Repositories → Repo Readiness** entry (alpha) is a read-only checklist for a repository folder before you hand work to a coding agent.

- Choose a repository folder; CodingBuddy remembers the last selected folder.
- The table checks agent governance, README coverage, documented build/test commands, contribution workflow docs, GitHub issue/PR templates, feature-flag docs for Swift app repos, setup scripts and hooks, CI workflows and lightweight `.git` in-progress markers.
- Each row is **Passed**, **Warning** or **Failed** and includes a short remediation hint. Warnings mean the app found a partial or ambiguous signal.
- The checklist never edits files, calls GitHub, shells out to `git` or validates that commands actually pass.

v1 limits: Repo Readiness is deterministic and advisory. It does not inspect remote Project state, create missing templates or decide whether a repository is safe to merge.

### MCP Inventory

The **MCP Inventory** entry (alpha) is a read-only table of MCP servers discovered across Codex, Claude Code and Cursor.

- The compact table shows server, source tool, repository or workspace and configuration health. Select a row to inspect scope, transport, safe command or URL summary, referenced environment variable names, header keys and source file.
- Search filters by server name, tool, repository or workspace name, scope, command or URL summary, and environment variable name.
- Codex servers that reference variables missing from `~/.codex/mcp.env` are highlighted. Use **Open Tool** to jump from a selected Codex, Claude Code or Cursor row to the existing tool editor.
- Secret values are never shown: URL user info, query strings, fragments and token-like command arguments are redacted.

v1 limits: MCP Inventory does not edit, install, or network-test servers. Claude Code and Cursor rows show configured `env` and header keys only; they do not infer missing variables from command text.

### Agent PR Monitor

The **Repositories → Agent PR Monitor** entry (alpha) is a read-only table for open GitHub pull requests across a watched repository list. Each row is classified as likely agent, likely human or unknown.

- Add or replace the fine-grained read-only GitHub token in **Settings → Security**; CodingBuddy stores it in Keychain, not in UserDefaults or files. If no token is saved or GitHub rejects it, the monitor sends you back to Settings.
- Add or remove watched repositories from the searchable picker; search matches owner, repository name, full `owner/name` and visible descriptions. The manual `owner/name` fallback remains available when repository listing is unavailable.
- The compact table shows PR title, repository, advisory readiness and last update time. Select a row to inspect author/source classification, branches, linked closing issues, CI status, review status and unresolved findings.
- With explainable guidance enabled, the selected PR first states what its current readiness means, why it matters, and what to do next. Green and genuinely waiting states say that no action is needed now; failed checks, requested changes, unresolved findings and drafts recommend opening the PR.
- A snapshot refresh in progress or a stale repository snapshot takes priority over the old readiness result. Authorization problems lead to Settings, ordinary refresh failures recommend a refresh, and active refreshes or rate limits explain that waiting is the useful next step instead of creating false urgency.
- Use **Refresh** to reload manually and **Open PR** to continue in the browser. The monitor never comments, approves, resolves threads or merges PRs.
- Rate limits, missing permissions, denied repositories and offline errors are shown as UI-safe states while the last successful snapshot stays visible where possible. Repository-specific failures are scoped, so successful repositories remain visible when another watched repository fails.

v1 limits: Agent PR Monitor reads GitHub.com only, does not update GitHub Projects and does not run in the background after CodingBuddy quits.

### Codex

The **Codex** sidebar entry (alpha) manages OpenAI Codex's environment file:

- **`~/.codex/mcp.env`** — the variables Codex loads (e.g. bearer tokens for MCP servers). Edit, add and delete entries like dotfile variables; secret-looking values are masked, comments in the file are preserved, and the file keeps its restrictive `600` permissions. Backups are written like for dotfiles.
- **MCP servers** — a read-only overview from `~/.codex/config.toml`: which server references which environment variable (`bearer_token_env_var`, `env_vars`).
- **Missing-variable warning** — when a server references a variable that `mcp.env` does not define, CodingBuddy shows a warning with a one-click **Define…** shortcut. That answers the classic "where does Codex read this token from?" question.

### Claude Code

The **Claude Code** entry (alpha) manages Claude Code's configuration:

- **`env` blocks** from `~/.claude/settings.json` and `settings.local.json` — edit, add and delete variables. CodingBuddy patches only the affected value (the rest of the file stays byte-for-byte, no reordering), writes a backup first, and refuses the write if Claude Code changed the file in the meantime.
- **MCP servers** — a read-only overview from `~/.claude.json` (user scope and existing projects) and the projects' `.mcp.json` files, with their referenced env/header keys.

### Cursor

The **Cursor** entry (alpha) manages `~/.cursor/mcp.json`: the per-server `env` values are editable (masked, value-precise patching with backups and external-change protection); the server list itself is read-only.

### Craft Agents

The **Craft Agents** entry (alpha) shows what the Craft Agents app stores in `~/.craft-agent/` — strictly read-only:

- **LLM connections** from `config.json`.
- **Token files** under `secrets/` with their expiry status; each can be reset individually after a confirmation that names the file and explains that the next connection triggers a fresh login.
- **The encrypted credential store** (`credentials.enc`): CodingBuddy shows size and age but never opens it; its reset confirmation is separate from token-file resets and explains that every Craft connector asks to log in again.
- When the folder exists but has no credential data yet, the empty state points you back to setting up Craft Agents or connecting a Craft connector. CodingBuddy waits for Craft to create the files.

## Workstation maintenance

The **Maintenance → Software Updates** entry (alpha) inventories global packages from one active Homebrew, npm and pnpm installation each.

- The table shows package name, manager, installed version, available version and status. Filter it to updates, direct installations or all packages; search matches package and manager names.
- **Compatible** uses npm/pnpm's wanted version. **Latest** explicitly includes newer major versions. Homebrew uses its reported current formula or cask version.
- Select one or more updateable rows and choose **Update Selected**. CodingBuddy shows every package and exact version transition before any command starts.
- Confirmed updates run sequentially with a visible per-package log. **Stop** cancels the current command and marks work that has not started; completed updates are not rolled back. CodingBuddy scans again after the run.
- Pinned formulas, self-updating casks and non-writable installations explain why CodingBuddy will not update them directly.
- With explainable guidance enabled, the visible status follows the selected target policy. Selecting one package distinguishes a routine compatible update from an explicit major update, explains direct versus dependency installations, and recommends one next step. **Review update** still opens the existing version preview and confirmation; it never starts an update directly from the explanation.
- Selecting one package loads version notes lazily. CodingBuddy prefers a matching GitHub Release and otherwise links to the repository, homepage or changelog source. No available release notes is a normal state.
- If automatic executable discovery chooses the wrong installation, set an explicit Homebrew, npm or pnpm path under **Settings → Maintenance**.

Commands use `Foundation.Process` with an absolute executable path and separate arguments. CodingBuddy never runs a login shell, `sudo`, or a freely assembled command string. A failed provider does not hide successful provider results; the issue strip says which manager failed and that results from other managers remain visible.

v1 limits: global packages only; one active installation per provider; no project dependencies, installation, removal, pin management, privilege escalation or automatic background updates. Bun, Yarn, pipx, uv, Cargo and editor extensions are not yet supported.

## Settings

Open **CodingBuddy → Settings…** (⌘,). The settings appear as a panel attached to the main window; close them with **Done** before continuing to work in the app.

- **Language** — System, English or Deutsch. Takes effect after relaunching the app.
- **Appearance** — Auto (follow the system), Light or Dark.
- **Default editor** — choose the macOS app CodingBuddy should use when it opens Markdown, JSON, YAML and other text-like repository files, or reset to the system default.
- **Security** — how long secrets stay revealed after authenticating, plus the GitHub token used by Agent PR Monitor.
- **Maintenance** — optional executable overrides for Homebrew, npm and pnpm; empty fields use automatic discovery.

## Live reload

CodingBuddy watches your dotfiles. Edits made in a terminal or editor show up in the app within a fraction of a second.

## Troubleshooting

| Symptom | Explanation |
|---|---|
| A variable doesn't show up | Only `~/.zshenv`, `~/.zprofile`, `~/.zshrc` are read — not `.bashrc` or files sourced from elsewhere. |
| A row has a lock icon | The line is too complex to rewrite safely. Edit it in a text editor. |
| "The file was changed externally" | Something else modified the dotfile while you edited. The app reloaded — just redo the edit. |
| Restore an old state | Use **Maintenance → Backups**, select a supported backup, preview it, then choose **Restore…**. Unknown backup names can still be inspected but are preview-only. |
