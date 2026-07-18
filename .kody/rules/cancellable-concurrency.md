---
title: "Keep expensive work cancellable and off MainActor"
scope: "file"
path: ["CodingBuddy/{Services,Stores}/**/*.swift"]
severity_min: "high"
buckets: ["performance"]
enabled: true
---

@kody-sync

## Instructions
- Run network, filesystem, parsing, and subprocess work outside MainActor and propagate structured cancellation.
- Publish observable UI state on MainActor and prevent cancelled work from restoring stale private data.
- Avoid detached tasks without explicit ownership and cleanup.

## Examples

### Bad example
A MainActor store synchronously scans the filesystem and an old task publishes after repository selection changes.

### Good example
The store owns a cancellable task, performs scanning off actor, checks cancellation, then publishes on MainActor.
