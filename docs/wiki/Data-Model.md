# Data Model & Safety

## The decomposition invariant

Every assignment line is decomposed into parts that reassemble **byte-for-byte**:

```
prefix + exportToken + name + "=" + quote + rawValue + quote + suffix
  │         │            │              │       │          └ trailing whitespace/comment, verbatim
  │         │            │              │       └ text between the quotes, verbatim (no unescaping)
  │         │            │              └ "", '"' or "'"
  │         │            └ [A-Za-z_][A-Za-z0-9_]*
  │         └ "export " incl. original spacing, or ""
  └ leading whitespace
```

`ParsedAssignment.rendered == sourceLine` holds for every editable line — this is what makes round-trips safe and is asserted by the parser tests.

## Read-only rules (fail-safe)

A line is surfaced but marked `isEditable = false` when rewriting it from parts could change meaning:

- command substitution in the value: `$(…)` or backticks
- multi-assignments / trailing code: `export A=1 B=2`, `FOO=1 ./run.sh`
- unclosed quotes
- unquoted values containing characters outside the conservative safe set (`;`, `|`, `*`, quotes, …)
- a `#` immediately after the closing quote (not a comment in zsh)

Read-only lines are never rewritten; deletion and editing are refused at the writer level too (`lineNotEditable`).

## Quoting model

`rawValue` is the **literal source text** between the quotes — no unescape/re-escape cycle exists anywhere. When an edit makes a value incompatible with its current quoting (e.g. a space in an unquoted value), `ShellQuoting.bestQuoting` picks the nearest style that can hold the text verbatim (`preferred → double → single → none`); if none fits, the write is refused (`unrepresentableValue`).

## Precedence

zsh load order for interactive login shells: `.zshenv → .zprofile → .zshrc`. The **effective** assignment for a name is the last one in `(file.loadOrder, lineIndex)` order; all others are badged *overridden* in the UI.

## Managed block

New variables (and `.env` imports) are appended inside a marker block at the end of the chosen file, keeping hand-written content and app-written content visibly separate:

```bash
# >>> EnvVarBuddy >>>
export MY_VAR="value"
# <<< EnvVarBuddy <<<
```
