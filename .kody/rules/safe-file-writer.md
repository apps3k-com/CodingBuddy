---
title: "Use SafeFileWriter for all file mutations"
scope: "file"
path: ["CodingBuddy/Services/**/*.swift","CodingBuddy/Stores/**/*.swift"]
severity_min: "critical"
buckets: ["security"]
enabled: true
---

@kody-sync

## Instructions
- Route generated or edited files through SafeFileWriter so containment, atomic replacement, permissions, backups, and failure cleanup stay enforced.
- Reject direct Data.write, String.write, FileHandle mutation, or replacement APIs for user-managed configuration files unless the operation is inside SafeFileWriter.
- Preserve scanner reload behavior owned by the store after a successful write.

## False-positive exceptions
- BackupBrowserStore.restore already reloads after SafeFileWriter succeeds; callers must not add a second reload.

## Examples

### Bad example
A store writes the selected config path directly with String.write(to:atomically:).

### Good example
The store validates a draft and delegates the contained atomic replacement to SafeFileWriter.
