# Agent PR Monitor Design

## Status

Design spike for issue #45 plus implementation notes for the shipped native
Agent PR Monitor. The feature is available behind the `agentPRMonitor` flag.

## Goal

The Agent PR Monitor should give developers one native place to watch pull
requests created by or involving coding agents. The first shippable version
should answer these questions without leaving CodingBuddy:

- Which agent-related PRs need attention?
- Is CI pending, failing, or green?
- Is review formally required, approved, or changes-requested?
- Are there unresolved review findings from automated reviewers such as
  CodeRabbit or cubic?
- Which GitHub issue is expected to close when the PR merges?

## Non-goals

- No merge, approve, comment, rebase, branch-update, or review-resolution
  actions in v1.
- No shelling out to `gh`, `git`, Node, Python, or helper scripts from the app.
- No third-party Swift packages for GitHub, GraphQL, or keychain access.
- No attempt to replace GitHub Projects, GitHub Actions, CodeRabbit, or cubic.
- No background daemon that polls GitHub while CodingBuddy is not running.

## Native Architecture

The feature should follow the existing CodingBuddy layers:

| Layer | Proposed types | Responsibility |
|---|---|---|
| `Views/` | `AgentPRMonitorView` | Searchable native table, watched-repository picker, refresh action, status badges, scoped empty/error states. |
| `Stores/` | `AgentPRMonitorStore` | Main-actor observable state, watched repositories, refresh cancellation, last aggregate snapshot, per-repository refresh states. |
| `Services/` | `GitHubClient`, `GitHubGraphQLRequest`, `GitHubTokenStore` | Foundation-only URLSession requests, GraphQL decoding, REST fallback requests, keychain storage. |
| `Models/` | `AgentPullRequest`, `AgentPRCheckSummary`, `AgentPRReviewSummary`, `GitHubRepositoryRef` | Small `Sendable` value types with stable IDs and search helpers. |

`AgentPRMonitorStore` should mirror the async refresh pattern already used by
read-only inventory features: cancel the previous refresh task, perform network
work in a cancellable task, then publish one immutable snapshot on the main
actor. Tests should inject a fake HTTP transport and in-memory token store; no
test may call GitHub or read real `$HOME` state.

The feature should be introduced behind an `agentPRMonitor` alpha flag only
when implementation begins. This spike intentionally does not add that flag.

## Repository Picker

The shipped monitor no longer requires users to type a repository manually as
the primary setup path. The repository setup sheet loads repositories visible to
the saved GitHub token through `GET /user/repos`, then shows a native searchable
list. Search matches owner, repository name, full `owner/name`, and visible
descriptions. Users can add multiple repositories to the watched list and
remove individual repositories without clearing the remaining list.

The picker keeps manual `owner/name` entry as a fallback when listing
repositories is unavailable or the desired repository is not returned. Reload
failures do not clear the current pull request snapshot, and a failed repository
list reload keeps cached repository choices selectable while showing a retry or
Settings recovery action.

The watched repository list is persisted as non-secret `owner/name` references
in UserDefaults. Existing single-repository selections migrate into the watched
list on first launch after the upgrade.

Repository listing is page-capped for v1. If GitHub exposes more pages after
the cap, the picker shows a truncation notice and keeps manual entry available.

## Authentication And Token Storage

Use a fine-grained personal access token for v1, scoped to selected
repositories. GitHub documents that fine-grained tokens are permission-based,
and REST endpoint responses include an `X-Accepted-GitHub-Permissions` header
that can help diagnose missing permissions.

Recommended repository permissions:

| Permission | Level | Why v1 needs it |
|---|---:|---|
| Metadata | read | Required baseline for repository identity. |
| Pull requests | read | List/get PRs, branch names, head SHA, author, labels, reviews, and PR files if a future view needs them. |
| Issues | read | Show linked closing issue numbers, titles, URLs, and state where the token can access them. |
| Checks | read | Read GitHub Actions/check-run state for the PR head SHA. |
| Commit statuses | read | Read legacy status contexts that are not check runs. |

Do not request write permissions for v1.

Example setup for a junior implementer to document in the future UI:

1. Open GitHub Developer settings and create a **fine-grained personal access
   token**, not a classic PAT.
2. Limit the token to the repositories the user wants CodingBuddy to monitor.
3. Grant only read access for Metadata, Pull requests, Issues, Checks, and
   Commit statuses.
4. Copy the token once into CodingBuddy under **Settings → Security**.
   CodingBuddy stores it in Keychain and never displays it again by default.

Token storage should use a small `GitHubTokenStore` wrapper around
Security.framework Keychain APIs. Store only the token and minimal metadata
needed to identify it, for example service `apps3k.CodingBuddy.github` and an
account key derived from `github.com` plus the selected owner or account label.
Non-secret choices such as selected repositories can live in `UserDefaults`;
the token itself must not.

The app should never copy the token into row models, diagnostics, logs, error
messages, or crash reports. The Settings token input UI should save or replace
the Keychain value without offering reveal or copy actions by default.

## GitHub API Surface

Use GraphQL as the primary read path because one query can return PR metadata,
review decision, linked closing issues, review threads, latest reviews, and
status rollups. GitHub's GraphQL reference is the source of truth for object
and connection fields.

Proposed v1 GraphQL query shape:

```graphql
query AgentPRMonitor($owner: String!, $repo: String!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequests(first: $first, after: $after, states: OPEN, orderBy: { field: UPDATED_AT, direction: DESC }) {
      nodes {
        number
        title
        url
        state
        isDraft
        updatedAt
        author { login }
        headRefName
        headRefOid
        baseRefName
        closingIssuesReferences(first: 5) {
          nodes { number title url state }
        }
        reviewDecision
        latestReviews(first: 10) {
          nodes { author { login } state submittedAt url bodyText }
        }
        reviewThreads(first: 50) {
          nodes {
            isResolved
            isOutdated
            path
            line
            comments(first: 1) {
              nodes { author { login } bodyText createdAt url }
            }
          }
        }
        commits(last: 1) {
          nodes {
            commit {
              oid
              statusCheckRollup {
                state
                contexts(first: 50) {
                  nodes {
                    __typename
                    ... on CheckRun { name status conclusion detailsUrl startedAt completedAt }
                    ... on StatusContext { context state targetUrl }
                  }
                }
              }
            }
          }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
  rateLimit { cost remaining resetAt }
}
```

REST fallback endpoints are useful when GraphQL omits a field or returns a
partial shape for a token:

| Data | Endpoint | Required permission |
|---|---|---|
| Accessible repositories | `GET /user/repos` | Metadata read for visible repositories. |
| PR list/details | `GET /repos/{owner}/{repo}/pulls` and `GET /repos/{owner}/{repo}/pulls/{pull_number}` | Pull requests read; GitHub also allows `Get a pull request` with Contents read. |
| Reviews | `GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews` | Pull requests read. |
| Linked issue details | `GET /repos/{owner}/{repo}/issues/{issue_number}` | Issues read. |
| Check runs | `GET /repos/{owner}/{repo}/commits/{ref}/check-runs` | Checks read. |
| Commit statuses | `GET /repos/{owner}/{repo}/commits/{ref}/status` | Commit statuses read. |

Primary references:

- GitHub GraphQL reference: <https://docs.github.com/en/graphql/reference>
- Fine-grained token permissions: <https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens>
- Pull request REST endpoints: <https://docs.github.com/en/rest/pulls/pulls>
- Check runs REST endpoints: <https://docs.github.com/en/rest/checks/runs>
- Commit statuses REST endpoints: <https://docs.github.com/en/rest/commits/statuses>

## Data Model

The app-facing model should be normalized and not expose raw GitHub response
objects directly:

```swift
struct AgentPullRequest: Identifiable, Hashable, Sendable {
    let id: String              // owner/repo#number
    let repository: GitHubRepositoryRef
    let number: Int
    let title: String
    let url: URL
    let authorLogin: String?
    let headRefName: String
    let headSHA: String
    let linkedIssues: [AgentPRLinkedIssue]
    let review: AgentPRReviewSummary
    let checks: AgentPRCheckSummary
    let updatedAt: Date
}
```

Derived values should be computed in the service layer:

- `agentSource`: likely agent-generated, human-authored, or unknown. v1 can use
  conservative signals such as branch prefixes, author login allowlist, PR body
  markers, or linked issue labels. Unknown must be a valid state.
- `reviewFindingsState`: no findings, unresolved findings, changes requested,
  or review pending. This should combine `reviewDecision`, latest reviews, and
  unresolved non-outdated review threads.
- `mergeReadiness`: blocked, attention needed, waiting, or ready. This is an
  advisory display state, not a merge permission decision.

## UI States

The first view should be read-only and table-first, consistent with Agent
Doctor, MCP Inventory, Agent Context, and Repo Readiness.

| State | UI behavior |
|---|---|
| No token | Show a setup empty state with a button that opens Settings → Security for GitHub token setup. |
| No repository | Open the repository picker so the user can search accessible repositories or use manual `owner/name` entry. |
| Repository list loading | Show a native progress state while keeping manual entry available. |
| Repository list unavailable | Show retry and Settings recovery actions; keep cached choices selectable when available. |
| Repository list empty | Explain that the saved token did not return accessible repositories and keep manual entry available. |
| Repository list truncated | Explain that some repositories are hidden because the page cap was reached. |
| Loading | Keep the previous snapshot visible with a subtle progress indicator unless the repository changed. |
| Loaded | Table rows show PR title, branch, author/source, linked issue, CI, review, findings, and updated time. |
| Empty | Explain that no matching open agent PRs were found. |
| Search empty | Explain that the current filter matches no PRs. |
| CI pending | Show waiting state without treating the PR as failed. |
| Review required | Highlight review requirement separately from CI. |
| Actionable findings | Link to the PR/review thread in the browser; do not try to resolve it in-app. |
| Ready | Show that CI is green and review has no known actionable blockers. |

Filters should start simple: repository, status group, author/source, and text
search. A later implementation can add saved views for "mine", "agent-authored",
or "needs reply".

## Failure Modes

| Failure | Expected behavior |
|---|---|
| No token | Do not call GitHub. Offer Settings → Security setup. |
| Invalid token | Show an authentication error and allow token replacement in Settings → Security. |
| Missing scope | Surface the missing permission if GitHub returns `X-Accepted-GitHub-Permissions`; otherwise show a scoped access error. |
| Private repo denied | Show `Denied` for that repository without deleting the saved repo or hiding successful repositories. |
| Network offline | Keep the last snapshot and show that refresh failed for the affected repository where possible. |
| Rate limited | Stop refreshing until GitHub's reset time; show reset time in local time. |
| Secondary rate limit | Back off aggressively and keep manual refresh disabled until retry is safe. |
| GraphQL partial data | Mark affected rows as partial and fetch REST fallback only for visible rows if needed. |
| CI pending | Show waiting; do not fail the row. |
| Unknown review provider | Keep generic review thread counts; provider-specific labels are best-effort only. |

## Refresh And Rate Limits

The monitor should start with explicit manual refresh plus a conservative
foreground interval, for example 5 minutes, only while the view is visible.
Every response should record rate-limit state. GraphQL responses include
`rateLimit { cost remaining resetAt }`, and REST responses expose standard
rate-limit headers.

Recommended behavior:

- Never refresh more frequently than once per minute per repository.
- Coalesce manual refresh taps while a request is running.
- Pause automatic refresh when remaining budget is low.
- Use pagination caps for v1: first 50 open PRs per repository, first 50 review
  threads per PR, first 50 status contexts per head commit.
- Prefer one GraphQL request per repository refresh; use REST fallback only
  when needed.

## Privacy And Safety

- Token values never appear in model values, tables, logs, alerts, or copied
  diagnostic text.
- Raw GitHub repository-list, PR, review, issue, check, and status responses
  are decoded into normalized in-memory models and are never logged.
- PR titles, issue titles, branch names, and review comments may be private
  repository data. They should stay local to the app and should not be written
  to disk unless a future cache is explicitly designed and documented.
- If a cache is added later, store only normalized non-secret snapshots, expire
  them, and provide a clear reset path.
- The view opens GitHub URLs in the user's browser for follow-up actions.
- v1 is read-only. No GitHub mutation should ship until a separate design covers
  write permissions and confirmation flow.

## v1 Limits

- One GitHub host: `github.com`. GitHub Enterprise Server can be a later issue.
- Fine-grained PAT setup only. GitHub App/OAuth device flow can be a later issue.
- Open PRs only.
- Read-only status and review monitoring.
- Best-effort agent-source detection.
- No in-app commenting, review thread resolution, merge, or Project status
  updates.
- No background monitoring after the app quits.

## Open Questions

- Should v1 require the user to manually add repositories, or should it discover
  repos from recent CodingBuddy selections?
- Should agent-source detection be configurable per repository, for example
  branch prefixes like `bvk/`, `codex/`, or bot account names?
- Should CodeRabbit/cubic be first-class providers with provider-specific
  parsing, or should all automated review tools stay generic in v1?
- Should a later version support GitHub App authentication to avoid long-lived
  user tokens?
- Should the first implementation create a local snapshot cache, or stay
  memory-only until the UX proves useful?

## Proposed Implementation Issue

Follow-up issue: [#54 — Stage 2: implement native Agent PR Monitor v1](https://github.com/apps3k-com/CodingBuddy/issues/54).

It should cover these tasks:

1. Add `agentPRMonitor` alpha flag and `docs/FEATURE_FLAGS.md` entry.
2. Add normalized PR monitor models and unit tests for check/review/readiness
   derivation.
3. Add `GitHubTokenStore` protocol, Keychain-backed implementation, and
   in-memory test fake.
4. Add URLSession-backed `GitHubClient` with injectable transport and GraphQL
   request/response models.
5. Add REST fallback only where GraphQL returns partial/missing linked issue or
   status data.
6. Add `AgentPRMonitorStore` with cancellable refresh, rate-limit state, and
   injected client/token store.
7. Add SwiftUI table view, setup empty state, manual refresh, repository
   filter, and external-link actions.
8. Add localized English/German strings and user guide sections.
9. Add tests with fake responses for no token, denied repo, rate limit, CI
   pending, changes requested, unresolved review threads, and ready state.
10. Run focused tests, full `CodingBuddyTests`, app build, feature-flag check,
    String Catalog JSON validation, whitespace check, and declaration-doc
    coverage before opening the PR.

Definition of done for #54: the feature is visible only in alpha builds, every
network/token dependency is injectable, no test touches real GitHub or real
Keychain, all user-facing strings are localized, and the view remains read-only.
