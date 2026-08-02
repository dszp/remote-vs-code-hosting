#!/usr/bin/env bash
# `mux` / `_mux_herdr` — which command each form dispatches (deploy/65).
#
# Exercises the bytes that actually land in ~/.bashrc: deploy/65-auto-attach.sh
# sed-extracts both functions to deploy/build/mux.sh when MUX_COPY is set (see
# tests/README.md), the same trick test-ws-name.sh and test-hs-complete.sh use.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

MUX="../deploy/build/mux.sh"      # extracted from the deploy script via MUX_COPY
WSL="../deploy/build/ws-name.sh"  # extracted via WS_LIB_COPY
for f in "$MUX" "$WSL"; do
  [ -r "$f" ] || { printf 'missing %s — build the artifacts first (tests/README.md)\n' "$f" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Throwaway HOME + workspace tree, so nothing here reads the real user's config.
export HOME="$TMP/home"
export WORKSPACE_DIR="$HOME/workspace"
mkdir -p "$WORKSPACE_DIR/Remote-VS-Code/docs" "$HOME/.config/remote-vs-code"

# Stubs that report how they were called instead of doing anything.
BIN="$TMP/bin"; mkdir -p "$BIN"
for c in herdr hs cs; do
  cat > "$BIN/$c" <<STUB
#!/usr/bin/env bash
printf '$c[%s] mux_active=%s\n' "\$*" "\${RVC_MUX_ACTIVE:-}"
STUB
  chmod +x "$BIN/$c"
done
# A PATH with no \`hs\`, for the fallback assertion.
NOHS="$TMP/nohs"; mkdir -p "$NOHS"
cp "$BIN/herdr" "$BIN/cs" "$NOHS/"

export PATH="$BIN:$PATH"
. "$WSL"
. "$MUX"

cd "$WORKSPACE_DIR/Remote-VS-Code"

# --- bare `mux` -------------------------------------------------------------
like "bare mux delegates to hs"        "$(mux)"            "hs[]"
is   "bare mux passes hs no args"      "$(mux)"            "hs[] mux_active="

# Without deploy/71 installed it still lands on this project's session.
is   "bare mux falls back inline"      "$(PATH="$NOHS:/usr/bin:/bin" mux)" \
                                       "herdr[--session Remote-VS-Code] mux_active=herdr"

# --- `mux herdr` ------------------------------------------------------------
is   "mux herdr -> project session"    "$(mux herdr)"      "herdr[--session Remote-VS-Code] mux_active=herdr"
is   "mux herdr ws still works"        "$(mux herdr ws)"   "herdr[--session Remote-VS-Code] mux_active=herdr"
is   "mux herdr <name> passes through" "$(mux herdr NetSapiens)" \
                                       "herdr[--session NetSapiens] mux_active=herdr"

# 'default' must NOT become `--session default`: that would create a second
# session under sessions/default/ rather than herdr's real default socket.
is   "mux herdr default is bare herdr" "$(mux herdr default)" "herdr[] mux_active=herdr"

# A subdirectory joins the project's one session, not its own.
is   "subdir joins project session"    "$(cd docs && mux herdr)" \
                                       "herdr[--session Remote-VS-Code] mux_active=herdr"

# --- tmux path --------------------------------------------------------------
is   "mux tmux still reaches cs"       "$(mux tmux)"       "cs[] mux_active="

# --- policy no longer steers the manual command -----------------------------
printf 'RVC_AUTO_MUX=tmux\n' > "$HOME/.config/remote-vs-code/mux.env"
like "policy=tmux leaves bare mux alone" "$(mux)"          "hs["
printf 'RVC_AUTO_MUX=off\n'  > "$HOME/.config/remote-vs-code/mux.env"
like "policy=off leaves bare mux alone"  "$(mux)"          "hs["

# ...but `mux use` still writes it.
mux use herdr >/dev/null
is   "mux use rewrites the policy"     "$(sed -n 's/^RVC_AUTO_MUX=//p' "$HOME/.config/remote-vs-code/mux.env")" \
                                       "herdr"
mux use off >/dev/null
is   "mux use off rewrites the policy" "$(sed -n 's/^RVC_AUTO_MUX=//p' "$HOME/.config/remote-vs-code/mux.env")" \
                                       "off"
out="$(mux use nonsense 2>&1)"; rc=$?
is   "mux use rejects junk (rc)"       "$rc"               "2"
like "mux use rejects junk (msg)"      "$out"              "usage: mux use <tmux|herdr|off>"

# --- guards -----------------------------------------------------------------
out="$(RVC_MUX_ACTIVE=herdr _mux_herdr 2>&1)"; rc=$?
is   "nesting guard rc"                "$rc"               "1"
like "nesting guard message"           "$out"              "already inside herdr"

out="$(PATH="/nonexistent" _mux_herdr 2>&1)"; rc=$?
is   "missing herdr rc"                "$rc"               "1"
like "missing herdr message"           "$out"              "herdr is not installed"

# --- help -------------------------------------------------------------------
like "help documents default"          "$(mux --help)"     "ws|default"

finish
