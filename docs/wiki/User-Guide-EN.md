# User Guide (EN)

EnvVarBuddy is a native macOS app for managing the environment variables that live in your zsh dotfiles (`~/.zshenv`, `~/.zprofile`, `~/.zshrc`) — without opening a terminal.

## Browsing variables

- The **sidebar** shows *All variables* plus one entry per dotfile with a count badge. Files that don't exist yet are dimmed; adding a variable to one creates it.
- The **table** lists name, value and source file. Use the search field (⌘F) to filter by name or value.
- A 🔒 **lock icon** marks complex lines (command substitution like `$(date)`, multi-assignments like `export A=1 B=2`). EnvVarBuddy shows them honestly but never rewrites them — edit those in your editor of choice.
- An orange **overridden** badge means a later assignment wins: zsh loads `.zshenv → .zprofile → .zshrc`, and within a file the last assignment of a name takes effect.
- The **Group overridden** toolbar toggle collapses duplicates: the effective assignment becomes the parent row and shadowed assignments expand beneath it.

## Editing

- **Double-click** a row (or right-click → *Edit…*) to change name or value. Validation runs live; values are written verbatim — `$VARIABLES` stay unexpanded.
- **＋** in the toolbar adds a new variable. New variables are written into a clearly marked block at the end of the chosen file:

  ```bash
  # >>> EnvVarBuddy >>>
  export MY_VAR="value"
  # <<< EnvVarBuddy <<<
  ```

- **Values with `:`** (like `PATH`) offer *Edit as list*: reorder, add and remove segments by drag & drop.
- **Delete** (right-click → *Delete…*) removes the line after confirmation.

## Safety net

Before every change EnvVarBuddy writes a timestamped backup to
`~/Library/Application Support/EnvVarBuddy/Backups/` (the last 20 per file are kept). Writes are atomic, follow symlinks (dotfile managers stay intact) and preserve file permissions. If a file changed outside the app mid-edit, the write is refused and the view reloads.

## Import & export

- **Import from .env…** (File menu or toolbar, ⇧⌘I) reads a dotenv file, shows a preview where you pick the entries (duplicates are flagged), and appends them to the managed block of a file of your choice.
- **Export visible as .env…** (File menu or toolbar, ⇧⌘E) writes the variables currently shown in the table to a `.env` file.

## Help menu

**Help → EnvVarBuddy Help** (⌘?) opens this documentation in your app language — the German Benutzerhandbuch when the app runs in German, this guide otherwise. **Help → Documentation (Wiki)** opens the full wiki.

## Secrets stay masked

Variables whose names look like credentials (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`, anything with `TOKEN`, `KEY`, `SECRET`, `PASSWORD`, `AUTH`, …) show `••••••••` instead of their value.

- Click the **lock button** in the toolbar (or just try to edit/copy a masked value) and authenticate with **Touch ID or your account password** to reveal them.
- The unlock expires automatically — configure the duration in *Settings → Security* (1/5/15 minutes or until quit). The lock button re-masks immediately.
- Copying a value or line, editing, and `.env` export of masked variables all require authentication first.

## MCP credentials (~/.mcp-auth)

The **Credentials → MCP Auth** sidebar section manages the OAuth cache that `mcp-remote` keeps for remote MCP servers — the directory you previously had to wipe with `rm -rf ~/.mcp-auth`.

- Each entry is one server. EnvVarBuddy resolves the cryptic file hashes back to server URLs by matching them against your Claude configuration (`~/.claude.json`, Claude Desktop config); unresolved entries show their hash plus the OAuth scope as a hint.
- The **status column** shows whether the access token is still active (with its estimated expiry), expired, or the entry is incomplete (a login that never finished).
- **Reset Entry…** moves just that server's files to the **Trash** — surgical, reversible, and the next connection simply re-runs the OAuth flow. **Reset All…** does the same for everything (the GUI equivalent of `rm -rf ~/.mcp-auth`, but undoable).
- **View Files…** (or double-click) opens the credential files with all token values masked. After authenticating with Touch ID or your password you can edit the raw JSON; invalid JSON is rejected on save.
- No app restart is needed: the view live-reloads when `mcp-remote` rewrites the files.

## Settings

Open **EnvVarBuddy → Settings…** (⌘,):

- **Language** — System, English or Deutsch. Takes effect after relaunching the app.
- **Appearance** — Auto (follow the system), Light or Dark.
- **Security** — how long secrets stay revealed after authenticating.

## Live reload

EnvVarBuddy watches your dotfiles. Edits made in a terminal or editor show up in the app within a fraction of a second.

## Troubleshooting

| Symptom | Explanation |
|---|---|
| A variable doesn't show up | Only `~/.zshenv`, `~/.zprofile`, `~/.zshrc` are read — not `.bashrc` or files sourced from elsewhere. |
| A row has a lock icon | The line is too complex to rewrite safely. Edit it in a text editor. |
| "The file was changed externally" | Something else modified the dotfile while you edited. The app reloaded — just redo the edit. |
| Restore an old state | Copy the backup from `~/Library/Application Support/EnvVarBuddy/Backups/` over the dotfile. |
