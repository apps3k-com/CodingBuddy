# User Guide (EN)

CodingBuddy is a native macOS app for managing the environment variables that live in your zsh dotfiles (`~/.zshenv`, `~/.zprofile`, `~/.zshrc`) — without opening a terminal.

## Browsing variables

- The **sidebar** groups destinations by task: **Focus**, **Environment**, **Agent Tools**, **Health & Security**, **Repositories**, and **Maintenance**. Environment contains *All Variables* plus one entry per dotfile. A numeric badge appears only after a source was loaded completely; missing or not-yet-scanned sources stay neutral, and an orange warning marks refused or incomplete data. Files that don't exist yet are dimmed; adding a variable to one creates it.
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

CodingBuddy never treats an existing unreadable or non-UTF-8 shell file as
missing. A single-file scope shows a safety refusal; **All Variables** retains
rows from verified files but labels the result **Incomplete data**. New, edit,
delete, import, and export actions remain disabled until **Retry** can load every
source safely. **Show in Finder** helps inspect the affected file without
putting its absolute path into the app's error text.

The **Maintenance → Backups** entry (alpha) lists those backups for zsh dotfiles and
supported agent config/env files (`~/.codex/mcp.env`, Claude Code settings,
Cursor `mcp.json`). Select a backup to compare a redacted **Backup** preview
with the current target. **Restore…** writes the selected backup through the
same safe writer, so the current file is backed up again before it is replaced.
Backups that cannot be mapped to a known CodingBuddy-managed target stay
preview-only. CodingBuddy also refuses preview or restore when a discovered
backup is replaced, becomes a symbolic link, is no longer a safe regular file,
or exceeds the 8 MiB preview limit. Discovery retains only stable no-follow
metadata; the selected file is opened and verified lazily for preview or restore,
so normal retention across many managed files does not consume one descriptor
per row. A parseable regular backup that fails ownership, permission or size
validation remains visible with a **Rejected** status and an exact explanation;
its preview and restore actions stay disabled, and **Show in Finder** remains
available for manual recovery. Directory discovery remains capped at 4,096 entries. When that bound is
exceeded, CodingBuddy shows a safety refusal with **Try Again** and **Show in
Finder** instead of presenting a misleading partial or empty list.
If a restore transaction cannot finish cleanly, the alert distinguishes whether
the backup was not applied, was applied but left recovery files, was applied but
still needs durability verification, or could not be confirmed. A persistent
recovery band keeps the outcome and any **Show Recovery Files in Finder** and
**Copy Recovery Path** actions visible after the alert closes and after you
navigate away and return. Restore stays
disabled until you explicitly choose **Mark Reviewed**, so retrying is never
suggested against an unknown target state.
Shell backup previews preserve names and harmless structure but mask every
assignment value, not only familiar credential names. JSON backup previews
preserve keys and container shape while masking every scalar value; malformed
JSON is shown as one opaque mask. If CodingBuddy cannot safely determine where
a multiline shell value ends, it hides the complete preview and labels that
safety decision explicitly instead of presenting an ambiguous mask. This
includes active zsh ANSI-C quotes (`$'…'`) and legacy `$[…]` arithmetic.

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

The first row is the recommendation. Each compact item cell keeps repository,
title, and PR number together so the table remains usable beside its native
inspector in narrow windows. Select any row to see **Why now**, the plain
explanation, the consequence, and the existing safe next action. A
repository-wide refresh problem appears once instead of being repeated for
every stale PR. If a watched repository fails before returning any PR rows, a
repository-level entry keeps that missing visibility actionable without
inventing a pull request. The partial-state banner remains neutral when only
repository status is available; valid PR snapshots from other watched
repositories remain in the queue when present.

v1 limits: the queue does not snooze work, send notifications, run in the
background, mutate GitHub, or rank Health, Security, and package signals yet.
Those sources will join the same deterministic queue after their guidance
contracts land.

## Secrets stay masked

Variables whose names look like credentials (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`, anything with `TOKEN`, `KEY`, `SECRET`, `PASSWORD`, `AUTH`, …) show `••••••••` instead of their value.

- Click the **lock button** in the toolbar (or just try to edit/copy a masked value) and authenticate with **Touch ID or your account password** to reveal them.
- The unlock expires automatically — configure the duration in *Settings → Security* (1/5/15 minutes or until CodingBuddy quits). The lock button re-masks immediately.
- Copying a value or line, editing, and `.env` export of masked variables all require authentication first.
- Authentication is bound to the exact visible row and view snapshot. If a file reloads or you change the scope, search, or effective-variable filter while the macOS prompt is open, CodingBuddy cancels the pending copy, edit, or export instead of applying it to changed data.
- **Lock All Revealed Secrets** clears only editors that currently own sensitive cleartext, whether it came from a backing store or was entered under a sensitive variable name. Once a draft becomes sensitive, renaming it to an ordinary name such as `PATH` does not remove that protection. Ordinary drafts remain open. A changed revealed-secret draft offers **Save and Lock**, **Discard and Lock**, or **Cancel**. Dirty revealed-secret editors show the same choices 30 seconds before automatic expiry. **Save and Lock** closes only after persistence succeeds; a refused or stale write leaves the editor open with its recovery message.

## MCP credentials (~/.mcp-auth)

The **Health & Security → MCP Auth** sidebar section manages the OAuth cache that `mcp-remote` keeps for remote MCP servers — the directory you previously had to wipe with `rm -rf ~/.mcp-auth`.

- Each entry is one server. CodingBuddy resolves the cryptic file hashes back to server URLs by matching them against your Claude configuration (`~/.claude.json`, Claude Desktop config); unresolved entries show their hash plus the OAuth scope as a hint.
- The **status column** shows whether the access token is still active (with its estimated expiry), expired, incomplete (a login that never finished), or **Reset only** because token artifacts exist but cannot be read safely.
- **Reset Entry…** moves just that server's files to the **Trash** after a confirmation that names the server and the consequence — surgical, reversible, and the next connection simply re-runs the OAuth flow. **Reset All…** uses a separate all-credentials confirmation for everything (the GUI equivalent of `rm -rf ~/.mcp-auth`, but undoable). CodingBuddy validates every component of the cache, private staging, and recovery paths without following symbolic links; only the exact immutable macOS compatibility aliases are accepted. Immediately before staging, it rescans and compares the complete descriptor-bound root and recursive artifact inventory with the confirmed view. At each final rename boundary it reopens the parent path, rechecks the exact leaf and complete bounded subtree, and for Reset All verifies that no unconfirmed root child appeared. It stages the exact entries in an owner-only transaction, rechecks every moved leaf and directory subtree, moves the transaction exclusively into private CodingBuddy staging, and validates them once more immediately before trashing the transaction as one unit. A detected addition, removal or replacement aborts before the Trash call and rolls exact staged entries back; if an exact object no longer exists, CodingBuddy retains explicit recovery state instead of claiming success. Recovery never overwrites a path recreated during the operation. A retained recovery blocks further resets, survives an app relaunch through an identity-bound private record, and remains available from the toolbar after the alert is dismissed; reload removes the action only after the exact recovery directory is resolved.
- **View Files…** (or double-click) opens the credential files with all token values masked. After authenticating with Touch ID or your password you can edit the raw JSON; invalid JSON is rejected on save. Saving is backup-first, atomic, symlink-preserving and permission-preserving. If another process changed the file after the editor loaded it, CodingBuddy refuses the stale save and offers to reload the current disk version. Dirty editors prevent app termination. The editor and list provide an app-wide **Lock All Revealed Secrets** action; dirty editors ask to save, discard or cancel. Thirty seconds before automatic relock, a persistent countdown offers save and lock, reauthentication, or discard and lock. User cancellation stays silent; a genuine system authentication failure remains visible beside the recovery action and returns keyboard and VoiceOver focus there without discarding the draft. At expiry CodingBuddy immediately clears unmasked content, returns keyboard and VoiceOver focus to Unlock, and announces the lock. The macOS **Credentials** menu mirrors View Files, global lock, retained recovery and Reset All so these actions remain available when the toolbar is hidden.
- When `~/.mcp-auth` is missing or empty, the empty state points you back to connecting an OAuth-enabled MCP server first. CodingBuddy lists cached credentials after `mcp-remote` creates them. Safely identified symlinks, special files, externally writable files, changing files, and oversized artifacts (over 1 MiB) remain visible as reset-only metadata; CodingBuddy never previews or edits through them. Reset moves the exact no-follow directory entry into the reversible transaction, so a symlink target or special-file content is never opened or touched. A replacement detected at the action boundary aborts without deleting the replacement. Cache and recovery enumeration is bounded: if discovery cannot prove that the credential inventory is complete, the view shows a safety warning with Retry and Show in Finder instead of claiming that no credentials exist, and reset actions remain disabled until complete coverage is restored.
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
- Expired or incomplete entries in `~/.mcp-auth`, plus a distinct warning when
  safety limits prevent Agent Doctor from proving that the scan was complete.

The compact table keeps severity, finding and tool visible. Select a finding to see a plain-language explanation of what was detected, why it matters, what could happen, and the safest next step. CodingBuddy recommends one action and routes it to the owning tool, MCP authentication view, or source file when that route already exists. If CodingBuddy cannot perform a recommendation, such as changing file permissions, the inspector explains the limitation instead of showing an inert button.

Technical evidence stays collapsed by default and contains only sanitized fields such as the diagnostic code, tool, source, and affected subject. It never includes credential values, OAuth URLs, or raw secret-bearing configuration.

v1 limits: Agent Doctor does not test network reachability, restart agent processes, apply auto-fixes, or show secret values.

### Agent Context

The **Repositories → Agent Context** entry (alpha) is a read-only inspector for one repository folder. It helps you see which instruction and setup files an agent would likely pick up before you start a coding session.

- Choose a repository folder; CodingBuddy remembers the last selected folder.
- A completed scan with no supported files says **No context files**. **No Results** is reserved for an active search that filters out every loaded row.
- Selecting or retrying a folder immediately clears rows from the previous
  repository and shows an inspection state. If the root is unavailable or any
  user-controlled path component is a symbolic link, the inspector shows an
  explicit security refusal with **Retry** and **Choose Another Folder…** rather
  than an empty result. No unsafe path is handed to Finder.
- The table checks a fixed allowlist: `AGENTS.md`, `CLAUDE.md`, `.cursor/rules`, `.mcp.json`, `.codex` project config and obvious developer documentation such as `README.md`, `CONTRIBUTING.md` and development setup docs.
- Signals highlight missing `AGENTS.md` or `CLAUDE.md`, both governance files being present, empty files, unusually large files and project-local MCP/Codex configuration.
- Use **Open** for native read-only follow-up on regular files. CodingBuddy rechecks the repository path and every component, rejects a repository selected through or later replaced by a symbolic link, copies bounded stable bytes from the verified file descriptor into a private `0400` snapshot inside an owner-only directory, and opens that snapshot with your configured text editor. The immutable macOS `/var`, `/tmp`, and `/etc` compatibility aliases remain supported after exact destination validation. A fallback message still identifies the file as a read-only verified snapshot; a Launch Services failure is reported separately from file validation. Success, fallback and failure are announced to VoiceOver. Repository directories and Finder reveal are deliberately not external action routes because AppKit cannot preserve descriptor-bound identity for an ordinary path. If an entry was replaced, redirected, too large for the bounded snapshot, or changed during the copy, the action is refused and the inspector reloads. CodingBuddy removes snapshots after ten minutes. Normal quit and the next launch remove expired validated snapshots, while a fresh snapshot remains available long enough for a cold-starting editor to complete the Launch Services handoff.

v1 limits: Agent Context is deterministic discovery only. It does not recurse through the repository, compare policy text semantically, decide which rule wins, or run natural-language analysis over instructions.

### Repo Readiness

The **Repositories → Repo Readiness** entry (alpha) is a read-only checklist for a repository folder before you hand work to a coding agent.

- Choose a repository folder; CodingBuddy remembers the last selected folder.
- The table checks agent governance, README coverage, documented build/test commands, contribution workflow docs, GitHub issue/PR templates, feature-flag docs for Swift app repos, setup scripts and hooks, CI workflows and lightweight `.git` in-progress markers.
- Each row is **Passed**, **Warning** or **Failed** and includes a short remediation hint. Warnings mean the app found a partial or ambiguous signal.
- Select a row to understand the check in plain language. Passed checks explicitly say that no action is needed; warnings and failures recommend revealing the repository so you can inspect or add the relevant file without CodingBuddy changing it.
- The checklist never edits files, calls GitHub, shells out to `git` or validates that commands actually pass.

v1 limits: Repo Readiness is deterministic and advisory. It does not inspect remote Project state, create missing templates or decide whether a repository is safe to merge.

### MCP Inventory

The **MCP Inventory** entry (alpha) is a read-only table of MCP servers discovered across Codex, Claude Code and Cursor.

- The compact table shows server, source tool, repository or workspace and configuration health. Select a row to inspect scope, transport, safe command or URL summary, referenced environment variable names, header keys and source file.
- Search filters by server name, tool, repository or workspace name, scope, command or URL summary, and environment variable name.
- Codex servers that reference variables missing from `~/.codex/mcp.env` are highlighted. Use **Open Tool** to jump from a selected Codex, Claude Code or Cursor row to the existing tool editor.
- The inspector explains one server state at a time. Missing variables recommend opening the owning tool, an unknown transport is called out as a configuration warning, and a configured row clearly states that no action is needed based on the local file evidence.
- Secret values are never shown: URL user info, query strings, fragments, token-like command arguments and header arguments are redacted. Header names remain visible. `Accept` retains only `application/json`, `text/event-stream`, or `*/*`; `Content-Type` retains only `application/json`. Every other header value is masked.
- Same-named Claude Code definitions in `.claude.json` and a project `.mcp.json` remain separate occurrences. This preserves the evidence needed to detect shadowing and conflicting definitions instead of silently hiding one source.

v1 limits: MCP Inventory does not edit, install, network-test, or authenticate with servers. **Configured** means that the scan recognized the local definition and did not prove a missing variable; it does not prove that the definition is complete, the server is reachable, or authentication will succeed. Claude Code and Cursor rows show configured `env` and header keys only; they do not infer missing variables from command text.

### Capability Hygiene

With the alpha **Capability Hygiene** flag enabled, **Health & Security →
Capabilities** broadens MCP Inventory into one read-only view of configured MCP
servers, standalone skills, and plugins proven installed by a supported
authoritative registry. v1 currently reads Claude Code's installed-plugin
registry; Codex `plugins.*` configuration overrides do not prove installation.

- The **Findings** view starts with exact duplicates, deterministic shadowing,
  and clearly advisory possible overlaps. **Inventory** keeps every discovered occurrence
  visible, including the source, consumer, effective scope, repository context,
  registration and tri-state activation evidence, declared permission names, HTTP header names,
  and secret-reference names.
- Exact duplicates require the same kind and exact runtime identity plus a
  complete versioned canonical behavior fingerprint. Public definitions use a
  versioned hash. Secret-bearing definitions use a keyed equality token that is
  valid only during the current scan; CodingBuddy does not retain a reusable
  secret hash. Unsupported or unknown behavior makes exact matching unavailable.
- Shadowing appears only when a typed provider rule identifies a winner and
  loser for an explicit repository or working-directory evaluation context.
  Their declaration scopes may differ. **Possible overlap** uses conservative,
  provider-aware tokens from names only; descriptions and natural-language
  analysis do not contribute.
- Coverage details list partial, refused, and unsupported sources and their
  value-free reasons. Files or trees that change during inspection, malformed
  schemas, scanner byte/entry/depth/project limits, and possible-overlap analysis
  caps all leave coverage incomplete. Verified rows remain visible, and an
  incomplete scan never becomes an empty all-clear state.
- Coverage details group matching reasons into collapsible sections with counts,
  so a large failure set is not rendered up front as one unstructured list.
- Only explicitly enabled occurrences participate in relation findings.
  Disabled or context-dependent entries remain visible as **No** or **Unknown**.
  Codex's `enabled` field and Claude's user plugin `enabledPlugins` setting are
  explicit evidence. Claude and Cursor MCP definitions remain **Unknown** because
  static configuration does not prove provider policy, approval, or UI
  disablement. If Claude's exclusive system `managed-mcp.json` exists,
  CodingBuddy marks the managed policy incomplete; v1 emits no Claude MCP
  precedence claim without effective activation evidence.
- Select a finding to inspect its relation evidence, including the similarity
  signal or the provider rule, evaluation context, winner, and shadowed
  occurrence. Select an inventory row to inspect repository usage, registration
  and tri-state activation evidence, permission and secret-reference names, and HTTP header names.
- The only actions are **Refresh** and **Copy Source Paths**. Capability Hygiene
  never opens source files, deletes, disables, installs, updates, executes, or
  rewrites a capability.
- Secret values are never displayed or stored in findings. The inventory shows
  only safe names such as referenced environment variables, header keys, or
  declared permission identifiers. Runtime reachability, effective OAuth scopes,
  trust, and whether a capability is actually used remain unknown unless a local
  source proves them.

v1 limits: Capability Hygiene does not launch servers, probe remote tools,
calculate universal token savings, infer that a capability is unused, or assign
a runtime-health or security score. Permission and scope interpretation remain
owned by the MCP Risk Auditor and Token/Scope Map roadmap.

### Agent PR Monitor

The **Repositories → Agent PR Monitor** entry (alpha) is a read-only table for open GitHub pull requests across a watched repository list. Each row is classified as likely agent, likely human or unknown.

- Add or replace the fine-grained read-only GitHub token in **Settings → Security**; CodingBuddy stores it in Keychain, not in UserDefaults or files. If no token is saved or GitHub rejects it, the monitor sends you back to Settings.
- Add or remove watched repositories from the searchable picker; search matches owner, repository name, full `owner/name` and visible descriptions. The manual `owner/name` fallback remains available when repository listing is unavailable.
- The compact table shows PR title, repository, advisory readiness and last update time. Select a row to inspect author/source classification, branches, linked closing issues, CI status, review status and unresolved findings.
- With explainable guidance enabled, the selected PR first states what its current readiness means, why it matters, and what to do next. Green and genuinely waiting states say that no action is needed now; failed checks, requested changes, unresolved findings and drafts recommend opening the PR.
- A snapshot refresh in progress or a stale repository snapshot takes priority over the old readiness result. Authorization problems lead to Settings, ordinary refresh failures recommend a refresh, and active refreshes or rate limits explain that waiting is the useful next step instead of creating false urgency.
- GitHub review and legacy-status collections are read with bounded pagination. If GitHub reports more entries than CodingBuddy can safely fetch, review and CI stay **unknown/pending** rather than being presented as approved or green.
- Use **Refresh** to reload manually and **Open PR** to continue in the browser. The monitor never comments, approves, resolves threads or merges PRs.
- Rate limits, missing permissions, denied repositories and offline errors are shown as UI-safe states while the last successful snapshot stays visible where possible. Repository-specific failures are scoped, so successful repositories remain visible when another watched repository fails. A failure with no cached PR rows remains visible as one repository-level entry in the Attention Queue.
- Cached Review Desk rows name their stale repository, show the safe failure reason, and retain the last successful refresh time so stale and current rows are distinguishable.

v1 limits: Agent PR Monitor reads GitHub.com only, does not update GitHub Projects and does not run in the background after CodingBuddy quits.

### Pull Request Review Desk

The **Repositories → Review Desk** entry (alpha) turns one monitored pull
request into a focused workbench. Select a pull request, then use **Summary**,
**Conversation**, and **Checks** in the inspector. Conversation puts unresolved
inline threads first; resolved and outdated threads stay available without
dominating the current work.

Use **Settings → Security → Sign in with GitHub** before changing a pull
request. Browser sign-in connects the CodingBuddy GitHub App and stores the
result in Keychain. Copy the one-time code, then choose **Open GitHub**; the app
keeps accessibility focus on the code instead of moving it into the browser.
An existing fine-grained token remains useful for read-only
monitoring when it includes `Administration: read`, but it cannot reply,
resolve, mark ready, or merge.

- Reply sends one scoped inline-thread reply without an extra confirmation.
- Resolve acts only on the selected unresolved thread and reloads GitHub state.
- Ready for Review asks for confirmation and checks the pull request again.
- Merge shows a strict confirmation, then repeats every eligibility check and
  binds the request to the current head commit. It is available only when
  GitHub itself enforces approving reviews, strict required checks, resolved
  conversations and admin protection without bypass allowances. A locally green
  pull request without that complete server proof remains unavailable. The menu
  shows only merge methods currently enabled by the repository.

Actions remain disabled while refresh is running or when GitHub data is
partial, stale, paginated incompletely, unknown, or changed after confirmation.
CodingBuddy does not assume a failed network response means a write failed; it
reloads first and reports an ambiguous result until GitHub state is known. Use
**Verify Again** to prove the exact transition from a complete snapshot, or
**I Checked on GitHub** only after manually confirming the result there. Normal
refresh and target changes stay blocked while the write outcome is unresolved.
For replies, only GitHub's exact returned comment ID proves success; matching
text posted concurrently by someone else remains ambiguous.

### Codex

The **Codex** sidebar entry (alpha) manages OpenAI Codex's environment file:

- **`~/.codex/mcp.env`** — the variables Codex loads (e.g. bearer tokens for MCP servers). Edit, add and delete entries like dotfile variables; secret-looking values are masked, comments in the file are preserved, and the file keeps its restrictive `600` permissions. Backups are written like for dotfiles.
- **MCP servers** — a read-only overview from `~/.codex/config.toml`: which server references which environment variable (`bearer_token_env_var`, `env_vars`).
- **Missing-variable warning** — when a server references a variable that `mcp.env` does not define, CodingBuddy shows a warning with a one-click **Define…** shortcut. That answers the classic "where does Codex read this token from?" question.

### Claude Code

The **Claude Code** entry (alpha) manages Claude Code's configuration:

- **`env` blocks** from `~/.claude/settings.json` and `settings.local.json` — edit, add and delete variables. CodingBuddy patches only the affected value (the rest of the file stays byte-for-byte, no reordering), writes a backup first, and refuses the write if Claude Code changed the file in the meantime.
- **MCP servers** — a read-only overview from `~/.claude.json` (user scope and existing projects) and the projects' `.mcp.json` files, with their referenced env/header keys. CodingBuddy loads this overview only when you open Claude Code; oversized files, symbolic links, special files, and unsafe project roots are explicitly refused and classified as **Access blocked**.
- Opening the entry shows an explicit loading state. Leaving the entry cancels its presentation request; an older or late scan cannot replace a newer result.
- An unsafe source is never reported as missing or silently skipped. A fully refused load shows **Access blocked**, the source-specific reason, **Retry**, and **Show in Finder** without exposing configuration contents. A partial load keeps verified sources visible, identifies every refused source, and disables changes only for affected settings files.
- Reads are bounded by per-file, project-count, and aggregate project-file limits. Invalid UTF-8, malformed or unsupported JSON, symbolic links, special files, unsafe path components, and files that change during inspection fail closed.

### Cursor

The **Cursor** entry (alpha) manages `~/.cursor/mcp.json`: the per-server `env` values are editable (masked, value-precise patching with backups and external-change protection); the server list itself is read-only.

Cursor configuration has three explicit states: safely missing, fully loaded, or
refused. CodingBuddy reads at most 4 MiB through a descriptor-bound, no-follow
snapshot and refuses unsafe paths, unreadable or non-regular files, oversized
files, invalid UTF-8, malformed JSON, and unsupported JSON structures. A refusal
never appears as a valid empty configuration or a zero-variable result. Instead,
the view shows **Access blocked**, the specific reason, **Retry**, and **Show in
Finder**. For an unsafe path, Finder receives only the safe parent location.

Add, edit, and delete operations are gated in both the view and store until the
configuration is fully loaded. A refused reload clears previously loaded rows
and dismisses editors or deletion confirmations whose source data is no longer
current. CodingBuddy also closes the action when Cursor replaces a server
definition while it is open; even a replacement with the same server name is
rejected before a secret can be written to changed command, URL, environment,
header, or other server settings.

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

Commands use the native POSIX process API with an absolute executable path and separate arguments. Each invocation receives its own process group, so timeout or **Stop** first requests termination and then force-stops resistant descendants after a short grace period. CodingBuddy never runs a login shell, `sudo`, or a freely assembled command string. A failed provider does not hide successful provider results; the issue strip says which manager failed and that results from other managers remain visible.

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
