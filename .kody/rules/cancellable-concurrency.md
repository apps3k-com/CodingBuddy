---
title: "Keep expensive work cancellable and off MainActor"
scope: "file"
path: ["**/*"]
severity_min: "high"
buckets: ["performance"]
enabled: true
---

@kody-sync

## Instructions
Network, filesystem, parsing, and subprocess work must run outside MainActor, propagate cancellation, and publish UI state on MainActor.

Only report violations demonstrated by the diff and repository context; do not speculate.

## Examples

### Bad example
The change bypasses the required boundary without an equivalent safeguard.

### Good example
The change uses the canonical boundary and adds focused evidence for its failure behavior.
