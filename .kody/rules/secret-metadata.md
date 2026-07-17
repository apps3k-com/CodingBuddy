---
title: "Store secret references and metadata, never secret values"
scope: "file"
path: ["CodingBuddy/{Models,Services,Stores,Views}/**/*.swift"]
severity_min: "critical"
buckets: ["security"]
enabled: true
---

@kody-sync

## Instructions
- Keep resolved tokens, passwords, private keys, and secret values out of persistence, logs, analytics, fixtures, and UI state.
- Represent secrets through references plus the minimum redacted metadata required for UX.
- Apply redaction before errors or snapshots cross a service boundary.

## Examples

### Bad example
A diagnostic model stores the resolved GitHub token to make retry easier.

### Good example
The model stores provider, reference, and redacted status while retrieval remains inside the credential boundary.
