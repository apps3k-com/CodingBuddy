#!/bin/sh
# One-time developer setup: activates the repo's git hooks.
set -e

cd "$(dirname "$0")/.."
chmod +x .githooks/* scripts/*.sh
git config core.hooksPath .githooks

echo "✓ Git hooks activated (core.hooksPath = .githooks)"
echo "  - commit-msg: enforces Conventional Commits"
echo "  - pre-push:   checks the feature-flag registry"
