---
title: "Fail closed when security configuration is unavailable"
scope: "file"
path: ["**/*"]
severity_min: "critical"
buckets: ["security"]
enabled: true
---

@kody-sync

## Instructions
Missing, malformed, or unreadable security configuration must disable the operation with an actionable error, never permissive defaults.

Only report violations demonstrated by the diff and repository context; do not speculate.

## Examples

### Bad example
The change bypasses the required boundary without an equivalent safeguard.

### Good example
The change uses the canonical boundary and adds focused evidence for its failure behavior.
