---
title: "Store secret references and metadata, never secret values"
scope: "file"
path: ["**/*"]
severity_min: "critical"
buckets: ["security"]
enabled: true
---

@kody-sync

## Instructions
Persistence, logs, analytics, fixtures, and UI state may contain secret identifiers and metadata only, never resolved credentials.

Only report violations demonstrated by the diff and repository context; do not speculate.

## Examples

### Bad example
The change bypasses the required boundary without an equivalent safeguard.

### Good example
The change uses the canonical boundary and adds focused evidence for its failure behavior.
