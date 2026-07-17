---
title: "Use native capabilities and complete localization"
scope: "file"
path: ["**/*"]
severity_min: "high"
buckets: ["compatibility"]
enabled: true
---

@kody-sync

## Instructions
Prefer supported Apple APIs and repository abstractions. User-visible strings, labels, errors, and feature states must use the canonical localization catalog.

Only report violations demonstrated by the diff and repository context; do not speculate.

## Examples

### Bad example
The change bypasses the required boundary without an equivalent safeguard.

### Good example
The change uses the canonical boundary and adds focused evidence for its failure behavior.
