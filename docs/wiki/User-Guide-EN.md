# User Guide (EN)

CodingBuddy is a native macOS app for managing the environment variables that live in your zsh dotfiles (`~/.zshenv`, `~/.zprofile`, `~/.zshrc`) — without opening a terminal.

## Browsing variables

- The **sidebar** shows *All variables* plus one entry per dotfile with a count badge. Files that don't exist yet are dimmed; adding a variable to one creates it.
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

## Import & export

- **Import from .env…** (File menu or toolbar, ⇧⌘I) reads a dotenv file, shows a preview where you pick the entries (duplicates are flagged), and appends them to the managed block of a file of your choice.
- **Export visible as .env…** (File menu or toolbar, ⇧⌘E) writes the variables currently shown in the table to a `.env` file.

## Help menu

**Help → CodingBuddy Help** (⌘?) opens this documentation in your app language — the German Benutzerhandbuch when the app runs in German, this guide otherwise. **Help → Documentation (Wiki)** opens the full wiki.

## Secrets stay masked

Variables whose names look like credentials (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`, anything with `TOKEN`, `KEY`, `SECRET`, `PASSWORD`, `AUTH`, …) show `••••••••` instead of their value.

- Click the **lock button** in the toolbar (or just try to edit/copy a masked value) and authenticate with **Touch ID or your account password** to reveal them.
- The unlock expires automatically — configure the duration in *Settings → Security* (1/5/15 minutes or until quit). The lock button re-masks immediately.
- Copying a value or line, editing, and `.env` export of masked variables all require authentication first.

## MCP credentials (~/.mcp-auth)

The **Credentials → MCP Auth** sidebar section manages the OAuth cache that `mcp-remote` keeps for remote MCP servers — the directory you previously had to wipe with `rm -rf ~/.mcp-auth`.

- Each entry is one server. CodingBuddy resolves the cryptic file hashes back to server URLs by matching them against your Claude configuration (`~/.claude.json`, Claude Desktop config); unresolved entries show their hash plus the OAuth scope as a hint.
- The **status column** shows whether the access token is still active (with its estimated expiry), expired, or the entry is incomplete (a login that never finished).
- **Reset Entry…** moves just that server's files to the **Trash** — surgical, reversible, and the next connection simply re-runs the OAuth flow. **Reset All…** does the same for everything (the GUI equivalent of `rm -rf ~/.mcp-auth`, but undoable).
- **View Files…** (or double-click) opens the credential files with all token values masked. After authenticating with Touch ID or your password you can edit the raw JSON; invalid JSON is rejected on save.
- No app restart is needed: the view live-reloads when `mcp-remote` rewrites the files.

## AI tools

### Agent Doctor

The **Agent Doctor** entry (alpha) is a read-only health check for local agent setup. It flags:

- Missing tool directories.
- Invalid JSON configuration files.
- Codex MCP environment variables referenced by config but missing from `~/.codex/mcp.env`.
- Credential files whose permissions are too open.
- Expired or incomplete entries in `~/.mcp-auth`.

v1 limits: Agent Doctor does not test network reachability, restart agent processes, apply auto-fixes, or show secret values.

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
- **Token files** under `secrets/` with their expiry status; each can be reset individually (moved to the Trash — the next connection triggers a fresh login).
- **The encrypted credential store** (`credentials.enc`): CodingBuddy shows size and age but never opens it; a reset moves it to the Trash, after which every Craft connector asks to log in again.

## Settings

Open **CodingBuddy → Settings…** (⌘,). The settings appear as a panel attached to the main window; close them with **Done** before continuing to work in the app.

- **Language** — System, English or Deutsch. Takes effect after relaunching the app.
- **Appearance** — Auto (follow the system), Light or Dark.
- **Security** — how long secrets stay revealed after authenticating.

## Live reload

CodingBuddy watches your dotfiles. Edits made in a terminal or editor show up in the app within a fraction of a second.

## Troubleshooting

| Symptom | Explanation |
|---|---|
| A variable doesn't show up | Only `~/.zshenv`, `~/.zprofile`, `~/.zshrc` are read — not `.bashrc` or files sourced from elsewhere. |
| A row has a lock icon | The line is too complex to rewrite safely. Edit it in a text editor. |
| "The file was changed externally" | Something else modified the dotfile while you edited. The app reloaded — just redo the edit. |
| Restore an old state | Copy the backup from `~/Library/Application Support/CodingBuddy/Backups/` over the dotfile. |
