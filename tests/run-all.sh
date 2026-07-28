#!/usr/bin/env bash
# Run every test-*.sh in this directory. Non-zero if any file fails.
set -uo pipefail
cd "$(dirname "$0")"

# The tests source the exact bytes the deploy scripts install, so those have to be
# extracted to deploy/build/ first. See README.md for the one-time build command.
if [ ! -d ../deploy/build ]; then
  printf 'tests: ../deploy/build is missing — build the artifacts first:\n\n' >&2
  sed -n '/^```bash$/,/^```$/p' README.md | sed '1d;$d' >&2
  exit 1
fi

rc=0
for t in test-*.sh; do
  printf '\n=== %s ===\n' "$t"
  bash "$t" || rc=1
done
exit "$rc"
