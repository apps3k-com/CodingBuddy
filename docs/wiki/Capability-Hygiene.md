# Capability Hygiene

Capability Hygiene is CodingBuddy's local, read-only inventory for configured
MCP servers, standalone agent skills, and plugins proven installed by supported
authoritative registries. Its purpose is to make duplicate and precedence
evidence reviewable without turning weak similarity into an automatic cleanup
decision.

## Why this exists

Agent clients resolve capabilities from several user, project, plugin, and
working-directory layers. Their precedence rules differ, and progressive loading
means a static file scan cannot prove the live runtime tool set or a universal
token cost. The product therefore reports only evidence available from bounded
local sources.

Useful primary references:

- [Claude Code MCP scopes and precedence](https://code.claude.com/docs/en/mcp)
- [Claude Code skill precedence](https://code.claude.com/docs/en/skills)
- [Codex configuration layers](https://learn.chatgpt.com/docs/config-file/config-basic)
- [Agent Skills progressive disclosure](https://agentskills.io/specification)
- [MCP dynamic tool-list changes](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- [MCP security guidance](https://modelcontextprotocol.io/docs/tutorials/security/security_best_practices)

## Evidence levels

| Relation | Required evidence | Meaning |
|---|---|---|
| Exact duplicate | Same kind, exact runtime identity, and complete versioned canonical behavior fingerprint | Supported behavior matched exactly across at least two occurrences. |
| Shadowing | Same typed identity and kind, typed provider rule, explicit evaluation context, and named winner/loser | One local definition deterministically takes precedence over another in that context; declaration scopes may differ. |
| Possible overlap | Conservative provider-aware name-token similarity between distinct identities in the same kind, consumer, and effective scope | The names may indicate related responsibilities. Keeping both can be correct. |

Every occurrence remains visible before relations are calculated. Source path,
scope, or repository metadata do not become part of an exact-content
fingerprint. Complete public, non-secret content uses a domain-separated,
versioned SHA-256 equality token. Complete secret-bearing content uses
HMAC-SHA-256 with a fresh scan-local key that is discarded after analysis. The
opaque digests, canonical bytes, and secret values are never displayed,
persisted, logged, or exported. If an adapter cannot account for every supported
behavior-bearing field, the fingerprint is unavailable and no exact-duplicate
claim is emitted.

Possible overlap never reads descriptions or performs natural-language
analysis. It tokenizes only capability names, removes generic/provider namespace
signals, and stays advisory. Shadowing does not depend on fingerprint inequality:
the provider adapter must prove that both occurrences apply to one explicit
repository or working-directory context and supply its typed precedence rule.

## Supported installation evidence

Configured MCP definitions and standalone skills have provider-owned source
adapters. A plugin is marked installed only when a supported authoritative
installation registry names it. v1 currently supports Claude Code's
installed-plugin registry. Codex `plugins.*` configuration overrides are not an
installation registry and therefore do not create installed-plugin occurrences.

## Completeness and safety

Each adapter has bounded file size, aggregate size, entry count, traversal and
JSON depth, and provider/project-root limits. Symbolic links, special files,
external manifest paths, malformed schema shapes, unsupported behavior fields,
or descriptors and trees that change during inspection make the affected source
partial, refused, or unsupported. The analyzer separately caps possible-overlap
comparisons and retained findings; reaching either cap marks analysis coverage
partial. Verified evidence from other sources remains visible, and an incomplete
scan is never presented as an empty all-clear.

Activation is tri-state: enabled, disabled, or unknown. Only occurrences with
explicit enabled evidence participate in relation analysis. Codex's `enabled`
field and Claude's user plugin `enabledPlugins` setting are preserved. Claude
and Cursor MCP configuration alone cannot prove effective provider activation,
so those MCP occurrences remain unknown. Approval, UI disablement, project
override, managed-policy, malformed TOML, or unsupported settings likewise keep
the state unknown instead of defaulting to enabled. When Claude's system
`managed-mcp.json` exists or cannot be safely ruled out, v1 marks that policy as
incomplete evidence. v1 emits no Claude MCP precedence claim without effective
provider activation evidence.

The scanner never launches a configured process, contacts a server, installs or
updates a package, or rewrites configuration. Source reads are bounded,
descriptor-relative, and no-follow. The UI exposes source and analysis coverage,
relation evidence, safe repository usage, registration and tri-state activation evidence,
permission identifiers, secret-reference names, and HTTP header names. Its only
commands are rescan and copy value-free source paths; there is no external open,
delete, disable, write, execute, or auto-consolidate action.

## Truthful unknowns

The following remain unknown unless a bounded local source explicitly proves
them:

- whether a server is reachable or its runtime tool list changed;
- whether a capability is trusted, approved, callable, or actually used;
- ambient environment inherited by a local process;
- effective OAuth grants and whether a declared permission is appropriate;
- exact prompt-token savings across clients and model versions.

Permission and secret-reference facts are handoff data for the separate MCP Risk
Auditor and Token/Scope Map roadmap. Capability Hygiene does not duplicate their
risk interpretation or assign a universal health score.
