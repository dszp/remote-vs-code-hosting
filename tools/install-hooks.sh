#!/usr/bin/env bash
# Install leakguard as this clone's pre-commit hook.
#
# Hooks are per-clone and never travel with a push, so this has to be run once
# in every checkout that matters. It is intentionally a copy, not a symlink:
# a symlink into the worktree would let a branch that edits tools/leakguard.sh
# change what guards the commit that edits it.
set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
HOOK="$(git rev-parse --git-dir)/hooks/pre-commit"
install -m 0755 tools/leakguard.sh "$HOOK"
echo "installed $HOOK"
PATTERNS="$(git rev-parse --git-dir)/leakguard-patterns"
if [ ! -e "$PATTERNS" ]; then
  cp .leakguard.example "$PATTERNS"
  echo "seeded $PATTERNS — add your client and private-repo names to it"
else
  echo "kept existing $PATTERNS"
fi
