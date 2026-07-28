#!/usr/bin/env bash
# hs: s / x / k / rm semantics, guards, and the destructive-action prompt.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HS="../deploy/build/hs"
[ -x "$HS" ] || { printf 'missing %s\n' "$HS" >&2; exit 1; }
HSABS="$PWD/$HS"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export HS_HERDR_DIR="$HOME/.config/herdr"
export HS_WS_LIB="$PWD/../deploy/build/ws-name.sh"
export PATH="$TMP/bin:$PATH"
export HS_DRY_RUN=1
make_stub_herdr "$TMP/bin"
make_fixture "$HS_HERDR_DIR"

export HS_STUB_JSON="$TMP/sessions.json"
cat > "$HS_STUB_JSON" <<'JSON'
{"sessions":[
 {"default":false,"name":"Live","running":true},
 {"default":false,"name":"Dead","running":false}
]}
JSON

hs() { bash "$HSABS" "$@" 2>&1; }

# s attaches, and revives a stopped session rather than erroring.
like "s attaches running"  "$(hs s Live)" "herdr --session Live"
like "s revives stopped"   "$(hs s Dead)" "herdr --session Dead"

# x stops only.
like "x stops"             "$(hs x Live)" "session stop Live"
out="$(hs x Dead)"
unlike "x on stopped is a no-op" "$out" "session stop"
like   "x on stopped explains"   "$out" "already stopped"

# rm deletes stopped, refuses running.
like "rm deletes stopped"  "$(hs rm Dead)" "session delete Dead"
out="$(hs rm Live)"; rc=$?
is   "rm on running exits 1" "$rc" "1"
like "rm on running hints x" "$out" "hs x"
unlike "rm on running does nothing" "$out" "session delete"

# k stops AND deletes. Running -> prompts; declining does nothing.
out="$(printf 'n\n' | hs k Live)"
unlike "k declined stops nothing"   "$out" "session stop"
unlike "k declined deletes nothing" "$out" "session delete"

out="$(printf 'y\n' | hs k Live)"
like "k accepted stops"   "$out" "session stop Live"
like "k accepted deletes" "$out" "session delete Live"

# -y skips the prompt. </dev/null proves nothing is waiting on stdin.
out="$(hs k -y Live </dev/null)"
like "k -y stops"        "$out" "session stop Live"
like "k -y deletes"      "$out" "session delete Live"
out="$(hs k Live -y </dev/null)"
like "k name then -y"    "$out" "session delete Live"

# Already stopped: k is just a delete, and must not prompt.
out="$(hs k Dead </dev/null)"
like   "k on stopped deletes"    "$out" "session delete Dead"
unlike "k on stopped skips stop" "$out" "session stop"

# Unknown names list the valid ones instead of failing opaquely.
out="$(hs s Nope)"; rc=$?
is   "unknown name exits 1" "$rc" "1"
like "unknown name lists"   "$out" "Live"

# Management verbs work inside a pane; a warning fires for the current session.
out="$(HERDR_PANE_ID=wA:p1 HERDR_SOCKET_PATH="$HS_HERDR_DIR/sessions/Live/herdr.sock" \
       bash "$HSABS" x Live 2>&1)"
like "warns when stopping own session" "$out" "currently inside"
like "still stops own session"         "$out" "session stop Live"

# Esc in the picker (no selection) is a silent success, matching cs.
cat > "$TMP/bin/fzf" <<'FZF'
#!/usr/bin/env bash
exit 130
FZF
chmod +x "$TMP/bin/fzf"
out="$(hs s)"; rc=$?
is   "empty pick exits 0"   "$rc" "0"
is   "empty pick is silent" "$out" ""

finish
