---
title: "Fail closed when security configuration is unavailable"
scope: "file"
path: ["CodingBuddy/{Services,Stores}/**/*.swift"]
severity_min: "critical"
buckets: ["security"]
enabled: true
---

@kody-sync

## Instructions
- Treat missing, malformed, unreadable, or ambiguous security configuration as unavailable and block the affected mutation.
- Return actionable typed guidance without exposing raw secret material.
- Cancel stale scans and clear private state when repository or credential context changes.

## Examples

### Bad example
A parser error falls back to an empty allow-list that the caller interprets as unrestricted.

### Good example
The feature reports an unavailable state and refuses the write until configuration is valid.
