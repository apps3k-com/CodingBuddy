# Pull Request Review Desk

## Status

Issue #109 introduces the Review Desk behind the alpha
`pullRequestReviewDesk` feature flag. It extends the read-only Agent PR Monitor
with focused, explicitly authorized actions for one pull request at a time.

## Product Boundary

The Review Desk is a native workbench, not a GitHub dashboard or full diff
viewer. Its left side selects one pull request from the already configured
repository set. Its inspector provides three views:

- **Summary** for head/base identity, draft state, approvals, merge state, and
  the current action gate.
- **Conversation** for top-level comments and fully loaded inline review
  threads, with unresolved threads first and resolved/outdated threads grouped
  separately.
- **Checks** for every current-head check run and legacy status context.

v1 supports replying to an inline review thread, resolving a thread, marking a
draft ready for review, and merging an eligible pull request. It deliberately
does not approve reviews, edit arbitrary comments, batch-process pull requests,
update branches, display the full diff, or perform autonomous writes.

## Authorization

GitHub App Device Flow is the primary sign-in mechanism for this native macOS
app. The public client ID is injected through
`CODINGBUDDY_GITHUB_APP_CLIENT_ID`; no client secret is embedded. The user code
and device secret exist only for the lifetime of the sign-in sheet. Successful
access/refresh tokens and their expiries are encoded as one versioned Keychain
value using `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
The sheet keeps VoiceOver focus on the copyable code and waits for the user to
choose **Open GitHub**; it does not move focus into the browser automatically.

The Agent PR Monitor and Review Desk share one actor-owned credential
coordinator. Expiring access tokens are refreshed through one single-flight
request, and every caller receives the same resulting credential revision.
GitHub App Device Flow does not require a client secret for refresh. A failed
or expired refresh requires a new sign-in rather than silently falling back to
a different identity.

Credential replacement and deletion advance an actor-owned revision. Every
device-flow completion and every caller waiting on a shared refresh compares
that revision and the complete stored credential after suspension. A late
network result therefore cannot restore a token that the user removed or
replace a newer PAT or GitHub App session.

Legacy fine-grained PATs remain accepted for the Agent PR Monitor and read-only
Review Desk inspection. They never authorize writes. The capability check lives
below the UI so keyboard actions and future views cannot bypass it.

The minimum PAT profile depends on the surface. Agent PR Monitor needs read-only
Metadata, Pull requests, Issues, Checks, and Commit statuses. Read-only Review
Desk inspection additionally needs `Administration: read` because its complete
snapshot verifies branch protection and bypass rules. A PAT without that grant
remains monitor-only and fails closed instead of presenting an incomplete policy
as merge-ready.

Recommended GitHub App repository permissions:

| Permission | Access | Purpose |
|---|---:|---|
| Metadata | read | Repository and pull request identity baseline. |
| Administration | read | Read branch protection, admin enforcement, and bypass allowances. |
| Pull requests | read/write | Inspect threads/reviews and perform scoped Review Desk mutations. |
| Checks | read | Current-head check runs. |
| Commit statuses | read | Legacy current-head status contexts. |
| Issues | read | Linked issue context. |
| Contents | write | Required by GitHub when merging through the API. |

## Complete Snapshot Invariant

The read-only monitor's aggregate row is advisory and cannot authorize a write.
Every Review Desk action starts from a dedicated snapshot that fully paginates:

- pull request head/base object IDs and branch names;
- draft, review-decision, and merge-state values;
- the base branch's complete classic branch-protection enforcement policy;
- repository-enabled merge commit, squash, and rebase methods;
- all current-head checks and status contexts;
- all approval reviews;
- all top-level conversation comments;
- all review threads and every reply in every thread.

Repeated cursors, missing cursors, duplicate IDs, page-limit exhaustion,
unknown gate enums, GraphQL partial errors, or truncated nested connections make
the snapshot incomplete. Incomplete snapshots remain inspectable but authorize
no writes.

One snapshot task tree also shares aggregate request, reserved-node, and
response-byte budgets. The production defaults accept at most 256 GraphQL
reads, 25,600 pessimistically reserved nodes, 64 MiB in aggregate, and 10 MiB
for any one response. Exceeding a budget fails the snapshot before it can
authorize a mutation.

The service computes a SHA-256 digest over mutation-relevant normalized state.
A preflight is bound to the authenticated GitHub principal, pull request,
action intent, head OID, and this digest. Reply intents additionally bind the
exact UTF-8 reply body through a SHA-256 digest without retaining a second
cleartext copy. The preflight is one-use, remains in memory only, and is revoked
when the user cancels its confirmation.

Merge requires a fully positive server-enforcement proof. The base branch must
require at least one approving review, required and strict status checks,
conversation resolution, and admin enforcement, with zero pull-request bypass
allowances. Missing policy data, a branch without classic protection, or a
repository whose effective rules are not visible through this API remains
fail-closed even when the current PR appears locally green. The normalized
policy is part of the snapshot digest, so a protection change also invalidates
an existing confirmation. Repository merge-method settings are bound by the
same consistency reads and digest. The UI offers only methods GitHub reports as
enabled, and the service rejects an unavailable method before mutation.

## Mutation Protocol

1. Load a fresh, complete snapshot immediately before the proposed action.
2. Verify the GitHub App write capability and action-specific conditions.
3. Bind the preflight to principal, target, intent, digest, and expected head
   OID.
4. For Ready for Review and merge, show a confirmation based on that exact
   preflight. Inline replies do not need a confirmation; thread resolution is
   an explicit reversible command.
5. After a confirmation, load another complete snapshot. Any drift invalidates
   the confirmation and returns to inspection.
6. Execute exactly one mutation. Merge sends `expectedHeadOid` so GitHub also
   rejects a changed head.
7. Re-fetch the snapshot and show verified server state. The UI does not remove
   rows optimistically.

Mutation requests are serialized per pull request. CodingBuddy never
automatically retries a write after a transport interruption because the server
may already have committed it. Such outcomes remain **ambiguous** and block all
further writes and target changes until a complete same-principal snapshot proves
the exact state transition, or the user explicitly confirms that they checked the
pull request on GitHub. A completed reply is reconciled only with the exact
comment ID returned in GitHub's mutation receipt plus the bound body digest.
After a transport interruption no receipt exists, so matching concurrent text
stays ambiguous; merge reconciliation requires GitHub's merged flag.

## Confirmation Policy

| Action | Confirmation | Gate |
|---|---|---|
| Reply to inline thread | No | Fresh complete snapshot, target thread exists, non-empty bounded body. |
| Resolve inline thread | Explicit command | Fresh complete snapshot, thread exists and is unresolved. |
| Ready for Review | Compact confirmation | Fresh complete snapshot, PR still draft. |
| Merge | Strict confirmation plus second preflight | Current head unchanged, complete data, all required checks green, required approval satisfied, no actionable unresolved thread, clean/unblocked merge state, plus GitHub-enforced strict checks, approval, conversation resolution, admin enforcement, and zero bypass allowances. |

## UI And Accessibility

The macOS layout uses a dense native table and an unframed inspector. A status
band distinguishes complete, refreshing, partial, and unavailable queue state;
cached rows from failed repositories show the affected repository, safe error
reason, and last successful refresh time instead of appearing current. It keeps the
previous verified snapshot visible during refresh, but disables actions while
data is stale, partial, refreshing, or mutation ownership is unresolved. The
inspector and device-flow sheet support VoiceOver labels and predictable focus.
Keyboard commands include combined queue/detail refresh (`Command-R`), search
(`Command-F`), inspector toggle (`Option-Command-I`), and reply
(`Command-Return`) when the editor is focused.

## Testing Boundary

Tests inject HTTP transport, clock, sleeper, and credential store. They never
use the real Keychain, network, `$HOME`, or GitHub account. Required coverage
includes OAuth polling/slowdown/expiry/refresh, PAT write denial, every
pagination connection, repeated cursors, duplicate IDs, partial data, unknown
states, aggregate budgets, credential replacement/deletion races, principal and
reply-body drift, cancelled-preflight revocation, expected-head merge variables,
ambiguous writes, post-write verification, absent or bypassable branch
protection, and branch-policy drift immediately before merge.
Coverage also includes repository-disabled merge methods, exact reply-receipt
reconciliation, matching concurrent reply text, stale repository rows, and
Attention Queue cursor cycles, duplicate PR identities, and pagination budgets.
