---
title: "Use native capabilities and complete localization"
scope: "pull-request"
path: ["CodingBuddy/**/*.swift","CodingBuddy/Localizable.xcstrings","docs/FEATURE_FLAGS.md"]
severity_min: "high"
buckets: ["compatibility"]
enabled: true
---

@kody-sync

## Instructions
- Prefer supported Apple APIs and repository abstractions over custom platform emulation.
- Keep user-visible phrases, accessibility labels, domain errors, and feature states in the String Catalog with English and German coverage.
- Document new feature flags and keep default behavior explicit.

## False-positive exceptions
- SwiftUI Text string literals use LocalizedStringKey and are catalog-backed; do not demand manual String(localized:) wrapping.
- Foundation and filesystem localizedDescription is acceptable. Domain errors must conform to LocalizedError with catalog-backed messages instead of per-store string guards.
- The standalone product name CodingBuddy intentionally uses the String overload and is not localized; phrases containing the name remain localized.

## Examples

### Bad example
A domain error exposes an internal raw string and a new feature flag has no documentation.

### Good example
The domain error implements LocalizedError through catalog keys and the default-off flag is documented and tested.
