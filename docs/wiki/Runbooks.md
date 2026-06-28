# Runbooks / Operations

## Restore a dotfile from backup

Preferred path:

1. Open **Safety → Backups** in CodingBuddy.
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
