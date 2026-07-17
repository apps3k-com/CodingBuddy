# Architecture

Native macOS app — Swift, SwiftUI, AppKit only. No third-party dependencies (see [Conventions](Conventions)).

## Layers

```
Views/  (SwiftUI)            ContentView · VariableListView · VariableEditorView
                             PathEditorView · ImportPreviewView
   │  reads @Observable state, calls store methods
Stores/                      EnvStore (source of truth) · FileWatcher
   │  orchestrates parse/write, owns precedence logic
Services/  (pure logic)      ShellConfigParser · ShellConfigWriter
                             ShellQuoting · EnvFileCodec · FeatureFlags
Models/                      EnvVariable · ParsedAssignment · ShellConfigFile
```

- **`EnvStore`** (`@Observable`, MainActor) loads the three zsh files, exposes `[EnvVariable]`, performs mutations through the writer and reloads afterwards. Each source is classified as safely missing, loaded, or refused because it is unreadable or not valid UTF-8. A mixed scope retains verified rows but is explicitly incomplete; mutations, import, and export are blocked in both the view and store until every source is trustworthy. The base directory is injectable — tests never touch the real `$HOME`.
- **`ShellConfigParser` / `ShellConfigWriter`** are pure, stateless services. The parser produces the decomposed model (see [Data Model](Data-Model)); the writer is the only component that touches disk for mutations.
- **`FileWatcher`** wraps a kqueue-backed `DispatchSourceFileSystemObject` per watched path (home directory + each existing dotfile). Events are debounced (200 ms) and trigger a reload; watchers are recreated after every change because atomic saves replace the inode.

## Concurrency

The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. UI and store live on the main actor; pure logic types (`ShellQuoting`, parser et al.) are marked `nonisolated`. Dispatch sources deliver on the main queue and bridge with `MainActor.assumeIsolated`.

### Claude configuration startup boundary

`ContentView` materializes `ClaudeCodeStore` only when the Claude Code destination
opens. Store initialization is inert: application and unit-test-host startup do
not inspect the real home directory. Opening or retrying starts a detached,
bounded disk snapshot and publishes an explicit `loading` state before either
`loaded` (complete or partial) or `refused`. A request generation prevents a
cancelled navigation load or late result from replacing newer state.

The store keeps its home and backup roots injectable. Its editable settings,
read-only `~/.claude.json`, and project `.mcp.json` inputs all use
descriptor-bound, no-follow snapshots rather than path-based Foundation reads.
Per-file limits, a 512-project ceiling, and a 16 MiB aggregate project budget
bound each reload. Symbolic links, special files, unsafe project roots, invalid
UTF-8 or JSON, unsupported structures, and files outside those limits become
source-specific refusal reasons. A fully refused load exposes no configuration
content. A partial load keeps verified sources visible but disables mutations
for each refused settings source; safe embedded project definitions already
present in `~/.claude.json` remain available when only a project file is refused.

### Cursor configuration load boundary

`CursorStore` publishes one authoritative `missing`, `loaded`, or
`refused(reason)` state for `~/.cursor/mcp.json`. Each reload clears prior server
and environment rows before taking a descriptor-bound, no-follow snapshot with
a 4 MiB ceiling. Invalid UTF-8, malformed JSON, an unsupported root,
`mcpServers`, server, or `env` structure, unsafe path components, unreadable
targets, symbolic links, and non-regular or oversized files fail closed with a
typed refusal reason.

Only `loaded` permits value-precise add, update, or delete operations; the store
enforces this independently of disabled view controls. Every mutation is bound
to a SHA-256 fingerprint of the canonical complete server object captured when
the action opened. The view retains only that irreversible digest plus redacted
display metadata, while same-name changes to commands, URLs, arguments,
environment values, headers, or other JSON fields fail stale-state validation
before any secret is patched. The view replaces all
tables with a refusal state, exposes retry and a bounded Finder reveal, and
dismisses editor or deletion state when its loaded entry or server definition
changes or the load becomes untrusted. File watching uses the MCP file only after a safe snapshot;
filesystem refusals fall back to the parent directory rather than opening the
refused path.

## Write path (safety-critical)

1. UI calls a store mutation → store delegates to `ShellConfigWriter`.
2. Writer captures an opaque `SafeFileWriter.Snapshot`: exact bytes, file identity, followed symlinks, and open parent/file descriptors. It verifies the target line against those bytes and commits through the same snapshot, so retargeting a symlink to equal content still fails closed.
3. **Backup** of the current content to Application Support (retention 20/file). The backup file and its directory are `fsync`ed before the target commit. Enumeration is capped at 4,096 total directory entries before creation and rechecked after creation; overflow fails closed without changing the target, while a newly durable backup is retained for recovery.
4. New content is written **atomically** to the **symlink-resolved** path. Existing modes are preserved; newly created secret-capable shell files use `0600`, while generic writes without an explicit create mode retain the process `umask` result.
5. Post-rename identity, symlink, and parent checkpoints are revalidated. Cleanup first atomically quarantines the candidate under an unguessable `.codingbuddy-recovery-*` name, then repeats regular-file and inode validation immediately before `unlinkat`. A replacement observed at either validation boundary is never deleted and is surfaced as typed recovery state. If the entry was removed but the final directory sync fails, CodingBuddy reports a committed cleanup-durability warning without inventing a recovery path. Clean writes leave no recovery copy behind and backup retention remains bounded.
6. Store reloads and re-arms the watchers.

No-op writes (identical content) skip backup and write entirely.

### Credential-cache transactions

`MCPAuthStore` routes authenticated edits through `SafeFileWriter`. The writer
opens and snapshots the exact target, compares the editor's original bytes, and
revalidates content and filesystem identity immediately before its atomic
compare-and-swap. This keeps external OAuth refreshes from being overwritten by
a stale editor. JSON is validated before the backup-first, symlink-preserving
and permission-preserving replacement.

Multi-item resets walk the absolute credential, staging, and recovery roots from
`/` with descriptor-relative `fstatat`, `openat`, and `O_NOFOLLOW` checks for
every component. Only the exact immutable macOS `/var`, `/tmp`, and `/etc`
compatibility aliases are translated after their targets are revalidated.
App-owned directories are created with `mkdirat` and then checked for owner,
mode, type, and inode identity, including `EEXIST` races. Resets then stage
the exact selected directory entries in an owner-only transaction. The displayed
scanner generation also captures every top-level root entry, its complete
bounded recursive subtree, and every represented credential leaf as a
descriptor-bound identity.
At action time a fresh bounded scan and fresh no-follow inventory must exactly
match that snapshot before the first rename. Each final rename boundary reopens
the parent through the root descriptor and re-captures the exact leaf subtree;
Reset All additionally proves the remaining root-name set plus its private
transaction directory. Directory enumeration reopens `.`
with `openat` so repeated passes have independent offsets; `dup` is deliberately
not used because it would share the original open-file-description offset.
Reset leaves are identified repeatedly through descriptor-relative
`fstatat(..., AT_SYMLINK_NOFOLLOW)`
and moved with an exclusive `renameatx_np`; they are never opened. The same
transaction therefore safely handles regular files, directories, symlinks,
FIFOs and other reset-only special entries without following or reading their
contents. A post-rename identity and recursive subtree check proves that the
staged object still matches the confirmation inventory; a change through a
previously opened directory descriptor aborts and enters the normal
rollback/recovery path. Before invoking the
path-based Trash API, the store moves that validated transaction
descriptor-relative and exclusively into CodingBuddy's private `0700` staging
root, rechecks every staged leaf identity and directory subtree there, and
accepts success only when the
Trash API's result has the same identity and the staging name is gone. The
subtree check occurs immediately before the path-based system API; macOS does
not expose an atomic "validate and trash" operation, so a hostile same-UID
process retaining a descriptor could still mutate after that final boundary.
Intermediate
components are opened descriptor-relative with no-follow semantics. Before its
first rename, recovery preflights every transaction source identity and every
destination; one missing or replaced source retains the complete transaction
unchanged. Recovery then uses exclusive renames, so a destination created after
preflight is never overwritten. A failure restores only entries actually staged and otherwise
retains explicit recovery state; silent partial success is not accepted. The
transaction descriptor remains open across the Trash call. If validation or
rollback then fails, `F_GETPATH` resolves its current location and CodingBuddy
accepts that path only after revalidating the same owner-only directory
identity. Recovery therefore points at the actual retained transaction,
including its macOS Trash location. When that location is outside the two
enumerable app roots, CodingBuddy persists the exact path plus device, inode,
type, owner and mode in an owner-only `0600` application-support record. A
later launch validates both record and transaction without scanning the Trash;
malformed, stale or path-reused state stays blocked instead of being guessed.

### Credential input and preview boundary

Credential scanning opens the `~/.mcp-auth` root, version directories and
artifacts descriptor-relative with no-follow semantics. Only owner-controlled,
non-group/world-writable regular files are read, and each credential/config
input is capped at 1 MiB. Enumeration is separately bounded to 32 cache-version
directories and 512 artifacts per version, so many tiny entries cannot bypass
the byte ceiling. Recovery discovery and Reset All independently re-enumerate
their already-open roots with the same 32-entry top-level ceiling; overflow or
identity failure becomes a visible fail-closed state that blocks reset rather
than masquerading as an empty cache. Symbolic links and other special entries
remain visible as reset-only metadata but are never opened for preview or edit;
their exact directory entries can still enter the reversible reset transaction.
FIFO, device, oversized, externally writable and changing inputs are never read
or followed. The
action-time editor snapshot rejects final and user-controlled intermediate
symlinks; only immutable macOS root aliases such as `/var` are accepted and
revalidated.

Shared secret locking distinguishes an editor that owns authenticated store
cleartext or has accepted cleartext under a sensitive name from an ordinary
draft. Protection is latched for the editor lifetime: renaming a tainted draft
to a non-sensitive name cannot downgrade it. Automatic expiry clears only
protected drafts.
Manual locking preserves ordinary drafts; dirty revealed-secret drafts must be
saved, discarded, or cancelled explicitly. Every protected editor receives a
final 30-second warning, and save callbacks return explicit success so a refused
write cannot dismiss and lock a dirty editor. Credential-editor authentication
requests also carry a presentation generation and are cancelled on dismissal;
the shared guard checks Swift task cancellation before unlock, so a late system-
authentication result cannot repopulate a buffer or globally reveal secrets.
Shell and shared environment-table disclosures use the same fail-closed model:
`SecretActionSnapshot` binds the requested row to a monotonic presentation
generation. Store reloads, scope/search/filter changes, source refusals, and view
dismissal invalidate that generation; successful authentication then re-resolves
and exact-compares the row before copy, edit, or export proceeds. File-menu
transfer commands are focused values, so incomplete or unrelated views cannot
dispatch a silent no-op into a stale shell scope.

The backup browser applies the same identity-bound reader to discovered backup
files with an 8 MiB ceiling. Discovery retains only validated no-follow metadata;
preview and restore lazily open the selected file and require the same device,
inode, type, owner, mode, size, modification time and change time. This avoids
holding one descriptor and content copy per displayed backup while preserving
replacement detection. Parseable regular artifacts that fail ownership, mode,
or size validation remain in the inventory as typed rejected states without a
content snapshot; preview and restore are unavailable while the rejection reason
and Finder recovery action remain visible. Shell previews mask every assignment
value, including unknown names, declaration forms, append/index syntax, and
ambiguous assignment-bearing lines. JSON backup previews preserve keys and
container shape while replacing every scalar value, including values under
innocent-looking keys. Malformed credential-bearing JSON is masked as a whole.
When multiline shell syntax prevents the redactor from proving a safe document
boundary, `BackupBrowserPreviewContent.suppressedForSafety` carries that typed
decision to the view. The UI renders a localized explanation instead of
conflating full suppression with ordinary per-value masks. Active zsh ANSI-C
quotes (`$'…'`) and legacy arithmetic expansions (`$[…]`) are deliberately
treated as unsupported boundaries and suppress the complete preview.

### Agent Context action boundary

`AgentContextScanner` opens the selected repository from `/` and every
allowlisted path component descriptor-relative with no-follow semantics. It
rejects a selected or action-time substituted symbolic-link repository root;
only the exact immutable macOS `/var`, `/tmp`, and `/etc` compatibility aliases
are revalidated and translated to their `/private/...` targets. Present actionable
items carry an opaque identity token covering the repository root, intermediate
directories, and leaf. Immediately before **Open**, the scanner opens a regular
file descriptor-relative, repeats the complete identity inspection, copies at
most 1 MiB while checking descriptor metadata before and after the read, and
writes the exact bytes into a private `0500` UUID directory as a `0400` snapshot.
AppKit receives only that private snapshot path. Repository directories and
Finder reveal are excluded because those path-only handoffs cannot preserve the
verified descriptor identity. This blocks post-scan, pre-handoff, and post-
validation path replacement from redirecting the external open. A ten-minute
timer removes normal snapshots. Startup/action cleanup also sweeps a bounded set
of expired UUID directories through no-follow descriptors and deletes only one
validated owner-only regular leaf. Application termination applies the same
expired-only sweep: fresh snapshots retain the handoff lifetime promised to a
cold-starting editor, while expired artifacts are removed best-effort.

### Native command boundary

`FoundationCommandRunner` accepts an absolute executable plus a separate
argument vector; it never accepts a shell command string. `posix_spawn` creates
each invocation in a dedicated process group with non-blocking output pipes and
close-on-exec defaults for unrelated descriptors. Timeout, cancellation, output
overflow and successful leader exit clean up remaining descendants that stay
inside the invocation's dedicated process group;
resistant groups escalate from `SIGTERM` to `SIGKILL` after a bounded grace
period. A process-wide non-blocking `waitpid(WNOHANG)` reaper owns the leader;
after cancellation or timeout the caller also has a bounded post-`SIGKILL`
return deadline even if the child is not yet waitable. Combined standard output and
standard error are bounded, and public errors expose only typed summaries rather
than raw command output. This prevents memory growth, descriptor leakage and
descendant pipe writers from keeping an awaiting task alive indefinitely.

The boundary does not claim to contain a child that deliberately creates a new
session/process group, nor can pathname cleanup defend against a malicious
same-UID process racing the final system call; such a process already has the
user's authority to mutate or delete the managed files. CodingBuddy's checks
target ordinary concurrent writers, symlink/path replacement and deterministic
race boundaries without overstating the guarantees macOS exposes.

### GitHub monitoring evidence boundary

`GitHubClient` treats provider pagination as part of the trust boundary, not as
a display concern. GraphQL requests fetch up to 100 latest reviews and retain
`pageInfo.hasNextPage`; a missing review decision with additional unseen
reviews stays unknown. The REST combined-status fallback requests 100 legacy
statuses per page and follows `Link` or `total_count` evidence for at most ten
pages. A changing count, an empty page before declared completion, or a
remaining next page marks the check collection as truncated. Duplicate
case-insensitive status contexts and disagreement with GitHub's global combined
state also fail closed because page ordering can shift during pagination. Truncated review
or check collections cannot produce approved or green readiness.

`PRAttentionQueueBuilder` merges concrete `AgentPullRequest` sources with typed
repository sources. A stale watched repository that returned no PR row becomes
one repository-level queue item with only refresh or Settings routes; it never
receives a placeholder PR number or an Open PR action. Healthy repositories and
their last trustworthy snapshots remain independently visible.

### MCP inventory disclosure boundary

`MCPServerInventoryScanner` preserves every source occurrence, including a
same-named Claude Code server defined in both `.claude.json` and a project
`.mcp.json`. Keeping these rows separate enables later duplicate and shadowing
analysis. Human-readable command summaries remove URL credentials and query
data, token-like arguments, and all unrecognized header values. Header values
use a finite allowlist instead of relying on names or MIME grammar: `Accept`
may expose only `application/json`, `text/event-stream`, and `*/*`, while
`Content-Type` may expose only `application/json`. Comma-separated `Accept`
values are visible only when every item is in that set; all custom and otherwise
unrecognized values are masked. The inventory never claims that a locally
recognized definition is reachable or authenticated.

### Capability hygiene evidence boundary

Capability Hygiene builds a read-only occurrence graph from bounded local MCP,
skill, and installed-plugin adapters. A plugin occurrence requires an
authoritative installation registry supported by its adapter; a configuration
override such as Codex `plugins.*` is not installation evidence. The current v1
plugin registry adapter is Claude Code's installed-plugin registry. Every adapter
reports source completeness independently. Missing, malformed, refused,
unsupported, descriptor- or tree-changing, or resource-limit-truncated sources
therefore cannot collapse a partial scan into an empty successful snapshot.
Limits cover individual and aggregate bytes, entries, traversal and JSON depth,
and provider/project roots. Schema-shape failures are partial evidence rather
than silently empty collections. Discovered commands remain inert data and are
never executed.

Relations are evidence-tiered. Exact duplicates require the same capability
kind, exact runtime identity, and complete versioned canonical behavior. Public,
non-secret definitions use a domain-separated SHA-256 equality token.
Secret-bearing complete definitions use HMAC-SHA-256 with a fresh scan-local key
that is discarded after analysis. Digests and source bytes are opaque to UI,
persistence, logging, and export. An unknown or unsupported behavior-bearing
field makes exact matching unavailable instead of producing a weaker hash.

Shadowing is independent from exact matching. It requires equal typed identity
and kind plus an adapter-supplied provider rule that names the winner, loser, and
explicit repository or working-directory evaluation context. Declaration scopes
may differ as long as both occurrences apply in that context; differing
fingerprints are not required. Possible overlap compares only conservative,
provider-aware tokens from distinct capability names within the same kind,
consumer, and effective scope. Provider namespaces do not count as shared
purpose, and descriptions or natural-language analysis never contribute.
Comparison and output caps make advisory analysis partial instead of allowing
unbounded pair growth.

The UI keeps verified rows visible alongside source and analysis coverage
details. Relation inspectors expose the exact evidence tier, including
similarity evidence or the typed shadowing rule, evaluation context, winner, and
loser. Occurrence inspectors expose safe repository usage, registration and
tri-state activation evidence, permission identifiers, secret-reference names, and HTTP header
names. The only commands are rescan and copy value-free source paths. Capability
Hygiene does not open sources, delete, disable, rewrite, execute, install, or
update anything.

Relation analysis admits only explicitly enabled occurrences. Provider settings
may prove enabled or disabled only where their schema is authoritative: Codex's
`enabled` field and Claude's user plugin `enabledPlugins` map. Claude and Cursor
MCP configuration remains unknown because effective policy, approval, and UI
disablement are not fully represented by those static definitions. Malformed
Codex TOML also downgrades recovered occurrences to unknown. Claude's exclusive
system `managed-mcp.json` is checked before lower-scope scanning; v1 records
incomplete policy coverage and emits no Claude MCP precedence claim without
effective activation evidence.

These fields are facts, not risk conclusions. The feature does not infer runtime
tool availability or health, trust, approval, effective OAuth grants, actual
usage, or token savings. Those interpretations remain owned by the MCP Risk
Auditor and Token/Scope Map roadmap.

## Sandbox

The app is deliberately **not sandboxed**: its purpose is reading and writing dotfiles in `$HOME`, which the App Sandbox forbids. Hardened runtime stays enabled. See [ADRs](ADRs).
