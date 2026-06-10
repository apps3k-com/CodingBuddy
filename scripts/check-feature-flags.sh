#!/bin/sh
# Verifies that every flag in FeatureFlags.swift has a section in
# docs/FEATURE_FLAGS.md and vice versa. Used by the pre-push hook and CI.
set -e

cd "$(dirname "$0")/.."
FLAGS_FILE="CodingBuddy/Services/FeatureFlags.swift"
DOCS_FILE="docs/FEATURE_FLAGS.md"

if [ ! -f "$FLAGS_FILE" ] && [ ! -f "$DOCS_FILE" ]; then
  echo "No feature-flag registry yet — skipping."
  exit 0
fi
if [ ! -f "$FLAGS_FILE" ] || [ ! -f "$DOCS_FILE" ]; then
  echo "✖ $FLAGS_FILE and $DOCS_FILE must exist together." >&2
  exit 1
fi

# Flag cases: lines like `case someFlag` inside the FeatureFlag enum.
CODE_FLAGS=$(sed -n '/enum FeatureFlag/,/^}/p' "$FLAGS_FILE" \
  | grep -E '^\s*case [a-zA-Z0-9_]+' \
  | sed -E 's/.*case ([a-zA-Z0-9_]+).*/\1/' | sort -u)

# Documented flags: headings like ### `someFlag`
DOC_FLAGS=$(grep -E '^### `[a-zA-Z0-9_]+`' "$DOCS_FILE" \
  | sed -E 's/^### `([a-zA-Z0-9_]+)`.*/\1/' | sort -u)

FAIL=0
for flag in $CODE_FLAGS; do
  if ! echo "$DOC_FLAGS" | grep -qx "$flag"; then
    echo "✖ Flag '$flag' is in $FLAGS_FILE but not documented in $DOCS_FILE (add a '### \`$flag\`' section)." >&2
    FAIL=1
  fi
done
for flag in $DOC_FLAGS; do
  if ! echo "$CODE_FLAGS" | grep -qx "$flag"; then
    echo "✖ Flag '$flag' is documented in $DOCS_FILE but missing from $FLAGS_FILE." >&2
    FAIL=1
  fi
done

if [ "$FAIL" -eq 0 ]; then
  echo "✓ Feature-flag registry is consistent ($(echo "$CODE_FLAGS" | grep -c . || true) flags)."
fi
exit $FAIL
