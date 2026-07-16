# Runbooks / Operations

## Restore a dotfile from backup

Preferred path:

1. Open **Maintenance → Backups** in CodingBuddy.
2. Select the backup.
3. Review the Current/Backup preview.
4. Choose **Restore…**. CodingBuddy backs up the current target before writing
   the selected backup through its safe writer.

Manual fallback:

```bash
ls -t ~/Library/Application\ Support/CodingBuddy/Backups/zshrc-*
cp ~/Library/Application\ Support/CodingBuddy/Backups/zshrc-<timestamp> ~/.zshrc
```

Backups are plain copies of the pre-write state; the newest 20 per file are
kept. The UI restore only enables backups whose filename maps to a known
CodingBuddy-managed target, because older backup filenames do not store full
original paths.

## Recover an interrupted MCP credential reset

If MCP Auth reports that the credential or recovery area could not be scanned
safely, use **Show in Finder** before attempting a reset. CodingBuddy bounds
both cache and private-staging discovery to 32 top-level entries and deliberately
disables reset when that limit, ownership, permissions, or path identity cannot
be verified. Remove only entries you have identified; then choose **Try Again**.
An empty result is not assumed while this safety warning is present.

1. Stop clients that may refresh `~/.mcp-auth` while recovery is in progress.
2. Restore the affected item from the macOS Trash first; a normal successful
   reset is deliberately reversible there.
3. If CodingBuddy reports that automatic rollback failed, use **Show Recovery
   Files in Finder** or **Copy Recovery Path** in the alert or the persistent
   recovery toolbar menu. The retained owner-only directory is named
   `.codingbuddy-reset-<UUID>` and may be inside `~/.mcp-auth/`, CodingBuddy's
   private `MCPAuthResetStaging` application-support directory, or the actual
   macOS Trash location returned after a completed path move. CodingBuddy keeps
   the transaction descriptor open and publishes a moved path only after its
   identity, ownership, type, and mode still match. For an external location it
   also stores that exact identity in the owner-only
   `~/Library/Application Support/CodingBuddy/MCPAuthRecovery.json` record, so
   the recovery action survives an app relaunch without scanning the Trash. A
   stale, malformed or path-reused record remains blocked for manual inspection.
   The directory contains the exact items that remain staged. Further resets
   stay disabled while it exists.
4. Move only entries missing from their original location back out of the
   transaction. Staged names have a numeric ordering prefix; remove that prefix
   when restoring the original file or directory name. Never overwrite a path
   that was recreated while the reset was running.
5. Verify that the expected server entry is present, then delete the retained
   transaction folder only after authentication works. Choose **Check Recovery
   Status** or reload MCP Auth; the recovery action disappears only after
   CodingBuddy confirms the directory is gone.

## Resolve a safe-writer recovery artifact

CodingBuddy normally removes its random `.codingbuddy-recovery-*` quarantine
immediately after a second inode/type check. If another process replaces that
quarantine during cleanup, CodingBuddy preserves the observed file and reports
that the write needs recovery instead of deleting an unrelated entry.

1. Stop the process that was editing the same target or backup directory.
2. Check whether the alert reports that the target was already committed before
   cleanup stopped; reload the owning CodingBuddy view before editing again.
3. Inspect the reported recovery path and its neighbouring target manually.
   Never overwrite or delete either path until you have identified which content
   belongs to the external writer.
4. After resolving the conflict, retry the original operation. A normal write
   leaves no recovery copy, and timestamped backup retention remains 20 per file.

## Reset app settings

```bash
defaults delete apps3k.CodingBuddy
```

## Force a feature flag locally

```bash
defaults write apps3k.CodingBuddy flag.<name> -bool YES   # or NO
defaults delete apps3k.CodingBuddy flag.<name>            # back to channel default
```

## Wiki out of sync

The wiki is overwritten from `docs/wiki/` on every merge to `main`. If someone edited the wiki directly and the edit was lost: recover it from the wiki's git history (`git clone https://github.com/apps3k-com/CodingBuddy.wiki.git`) and re-apply it as a PR against `docs/wiki/`.

## Release PR not appearing

1. Check the `release-please` action run on the last push to `main`.
2. Verify the commits since the last tag are Conventional (`git log --oneline $(git describe --tags --abbrev=0)..`).
3. release-please ignores `docs:`/`chore:`/`ci:` commits for version bumps — a release PR only appears for `feat:`/`fix:` (or breaking) commits.

## CI is red on `macos-26` runner availability

If GitHub's hosted `macos-26` image is unavailable, switch `runs-on` in `.github/workflows/ci.yml` to the newest available macOS image and pin Xcode 26 via `xcode-select`.
