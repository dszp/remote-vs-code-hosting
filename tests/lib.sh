# Shared assertions for the repo's shell tests. Source, don't execute.
# Deliberately no `set -e`: a failing assertion must record and continue.
TESTS_RUN=0
TESTS_FAILED=0

ok()   { TESTS_RUN=$((TESTS_RUN+1)); printf '  ok   %s\n' "$1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1))
         printf '  FAIL %s\n         %s\n' "$1" "$2"; }

is() {   # name, got, want
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want [$3] got [$2]"; fi
}
like() { # name, got, substring
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"
  else fail "$1" "[$2] does not contain [$3]"; fi
}
unlike() { # name, got, substring
  if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1" "[$2] unexpectedly contains [$3]"
  else ok "$1"; fi
}
finish() {
  printf '\n%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}

# A fake `herdr` for PATH. Serves $HS_STUB_JSON for `session list --json` and
# echoes what it was asked to do for the mutating verbs, so tests can assert on
# the call without a real server.
make_stub_herdr() { # $1 = dir to create the stub in
  mkdir -p "$1"
  cat > "$1/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "session list")   cat "$HS_STUB_JSON" ;;
  "session stop")   printf 'stopped %s\n' "${3:-}" ;;
  "session delete") printf 'deleted %s\n' "${3:-}" ;;
  *)                printf 'stub herdr: %s\n' "$*" ;;
esac
STUB
  chmod +x "$1/herdr"
}

# A ~/.config/herdr tree: the default session at the root, named ones under
# sessions/<name>/. Only the fields hs reads are populated.
make_fixture() { # $1 = herdr dir
  local d="$1"
  mkdir -p "$d/sessions/NetSapiens" "$d/sessions/Stale" "$d/sessions/Corrupt"
  _fixture_session "$d/session.json"                     "$HOME"
  _fixture_session "$d/sessions/NetSapiens/session.json" "$HOME/workspace/NetSapiens"
  # Stale has no session.json at all; Corrupt has invalid JSON. Both must degrade
  # to "-" rather than break the whole listing.
  printf 'not json{' > "$d/sessions/Corrupt/session.json"
}
_fixture_session() { # $1 = path, $2 = identity_cwd
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<JSON
{"version":3,"active":0,"workspaces":[{"id":"w1","identity_cwd":"$2",
 "tabs":[{"panes":{"1":{"cwd":"$2"}}}]}]}
JSON
}
