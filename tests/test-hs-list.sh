#!/usr/bin/env bash
# hs: session enumeration, cwd enrichment from session.json, and `hs ls` output.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HS="../deploy/build/hs"
[ -x "$HS" ] || { printf 'missing %s\n' "$HS" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/workspace/NetSapiens"
export HS_HERDR_DIR="$HOME/.config/herdr"
export HS_WS_LIB="$PWD/../deploy/build/ws-name.sh"
export PATH="$TMP/bin:$PATH"

make_stub_herdr "$TMP/bin"
make_fixture "$HS_HERDR_DIR"

export HS_STUB_JSON="$TMP/sessions.json"
cat > "$HS_STUB_JSON" <<JSON
{"sessions":[
 {"default":true,"name":"default","running":true,
  "session_dir":"$HS_HERDR_DIR"},
 {"default":false,"name":"NetSapiens","running":true,
  "session_dir":"$HS_HERDR_DIR/sessions/NetSapiens"},
 {"default":false,"name":"Stale","running":false,
  "session_dir":"$HS_HERDR_DIR/sessions/Stale"},
 {"default":false,"name":"Corrupt","running":false,
  "session_dir":"$HS_HERDR_DIR/sessions/Corrupt"}
]}
JSON

out="$(bash "$HS" ls 2>&1)"

like "lists default"         "$out" "default"
like "lists named session"   "$out" "NetSapiens"
like "running marker"        "$out" "running"
like "stopped marker"        "$out" "stopped"
like "home abbreviated"      "$out" "~"
like "cwd from session.json" "$out" "~/workspace/NetSapiens"
like "missing file -> dash"  "$out" "Stale"
like "corrupt file -> dash"  "$out" "Corrupt"
# A broken session.json must not swallow the rest of the listing.
is   "all four rows"         "$(printf '%s\n' "$out" | grep -c .)" "4"

# The absolute HOME path must never appear once abbreviated.
unlike "no raw home path"    "$out" "$HOME/workspace/NetSapiens"

# herdr failing is an error, never an empty list.
cat > "$TMP/bin/herdr" <<'BAD'
#!/usr/bin/env bash
echo "herdr: socket refused" >&2; exit 1
BAD
chmod +x "$TMP/bin/herdr"
bad="$(bash "$HS" ls 2>&1)"; rc=$?
is   "herdr failure exits non-zero"  "$rc" "1"
like "herdr failure surfaces stderr" "$bad" "socket refused"

# Help works with no herdr at all.
help="$(PATH="/usr/bin:/bin" bash "$HS" -h 2>&1)"
like "help lists ls" "$help" "hs ls"
like "help lists k"  "$help" "hs k"

finish
