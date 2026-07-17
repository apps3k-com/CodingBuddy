---
title: "Use SafeFileWriter for all file mutations"
scope: "file"
path: ["**/*"]
severity_min: "critical"
buckets: ["security"]
enabled: true
---

@kody-sync

## Instructions
Generated or edited files must use SafeFileWriter so containment, atomic replacement, permissions, and failure cleanup remain enforced.

Only report violations demonstrated by the diff and repository context; do not speculate.

## Examples

### Bad example
The change bypasses the required boundary without an equivalent safeguard.

### Good example
The change uses the canonical boundary and adds focused evidence for its failure behavior.
