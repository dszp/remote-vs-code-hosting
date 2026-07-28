#!/usr/bin/env bash
# hs: create/attach paths, -n suffixing, name safety, nesting guard.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HS="../deploy/build/hs"
[ -x "$HS" ] || { printf 'missing %s\n' "$HS" >&2; exit 1; }
HSABS="$PWD/$HS"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export WORKSPACE_DIR="$HOME/workspace"
mkdir -p "$WORKSPACE_DIR/Remote-VS-Code/remote-vs-code" "$WORKSPACE_DIR/Other"
export HS_HERDR_DIR="$HOME/.config/herdr"
export HS_WS_LIB="$PWD/../deploy/build/ws-name.sh"
export PATH="$TMP/bin:$PATH"
export HS_DRY_RUN=1
make_stub_herdr "$TMP/bin"
make_fixture "$HS_HERDR_DIR"

export HS_STUB_JSON="$TMP/sessions.json"
cat > "$HS_STUB_JSON" <<'JSON'
{"sessions":[
 {"default":false,"name":"Other","running":true},
 {"default":false,"name":"Other-2","running":false}
]}
JSON

run_in() { ( cd "$1" && shift && bash "$HSABS" "$@" 2>&1 ); }

# Bare: names after the project, launches with the mux marker set.
out="$(run_in "$WORKSPACE_DIR/Remote-VS-Code")"
like "bare uses ws name"    "$out" "herdr --session Remote-VS-Code"
like "bare sets mux marker" "$out" "RVC_MUX_ACTIVE=herdr"

# A subdirectory joins the project session rather than making its own.
is "subdir joins project" \
  "$(run_in "$WORKSPACE_DIR/Remote-VS-Code/remote-vs-code")" \
  "EXEC: env RVC_MUX_ACTIVE=herdr herdr --session Remote-VS-Code"

is "dot is the same as bare" \
  "$(run_in "$WORKSPACE_DIR/Remote-VS-Code" .)" \
  "EXEC: env RVC_MUX_ACTIVE=herdr herdr --session Remote-VS-Code"

# A directory argument names the session after that directory, from anywhere.
like "dir arg names after dir" \
  "$(run_in "$HOME" "$WORKSPACE_DIR/Remote-VS-Code")" \
  "herdr --session Remote-VS-Code"

# A non-directory argument is a literal session name.
like "plain name honored" "$(run_in "$HOME" scratch)" "herdr --session scratch"

# -n suffixes past every taken name, stopped ones included.
like "-n skips taken names" "$(run_in "$WORKSPACE_DIR/Other" -n)" "herdr --session Other-3"
like "-n with explicit base" "$(run_in "$HOME" -n Other)"          "herdr --session Other-3"

# `..` is a real directory, so it takes the directory branch and names the session
# after the parent — same as `cs ..`. The name guard is about the DERIVED name,
# which can never come out as '..' because it is always a basename.
like "'..' names after the parent" \
  "$(run_in "$WORKSPACE_DIR/Remote-VS-Code/remote-vs-code" ..)" \
  "herdr --session Remote-VS-Code"

# An option-lookalike is refused rather than silently becoming a session name.
out="$(run_in "$HOME" -x)"; rc=$?
is   "rejects '-x' (exit)" "$rc" "1"
like "rejects '-x' (msg)"  "$out" "hs:"

# A name that is not a directory has every path separator folded away, so it can
# never escape ~/.config/herdr/sessions/ — this is the real traversal guard.
like "slashes folded" "$(run_in "$HOME" "../etc/passwd")" "herdr --session .._etc_passwd"
unlike "no path escapes" "$(run_in "$HOME" "../etc/passwd")" "/etc/passwd"

# Nesting: herdr cannot run inside herdr.
out="$(cd "$HOME" && HERDR_PANE_ID=wA:p1 bash "$HSABS" 2>&1)"; rc=$?
is   "nesting blocked (exit)" "$rc" "1"
like "nesting blocked (msg)"  "$out" "inside herdr"
like "nesting names picker"   "$out" "workspace_picker"

out="$(cd "$HOME" && RVC_MUX_ACTIVE=herdr bash "$HSABS" 2>&1)"
like "RVC_MUX_ACTIVE also blocks" "$out" "inside herdr"

# ls still works from inside a pane — managing other sessions is legitimate.
out="$(HERDR_PANE_ID=wA:p1 bash "$HSABS" ls 2>&1)"; rc=$?
is "ls allowed inside a pane" "$rc" "0"

finish
