#!/usr/bin/env bash
# _rvc_ws_name: derives a herdr/tmux session name from a directory.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

LIB="../deploy/build/ws-name.sh"   # extracted from the deploy script via WS_LIB_COPY
[ -r "$LIB" ] || { printf 'missing %s\n' "$LIB" >&2; exit 1; }
. "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A self-contained fake HOME so the tests never depend on the real user's tree.
export HOME="$TMP/home"
export WORKSPACE_DIR="$HOME/workspace"
mkdir -p "$WORKSPACE_DIR/Remote-VS-Code/remote-vs-code" \
         "$WORKSPACE_DIR/NetSapiens" \
         "$WORKSPACE_DIR/we ird+dir"
: > "$WORKSPACE_DIR/NetSapiens/NS.code-workspace"

is "project dir"            "$(_rvc_ws_name "$WORKSPACE_DIR/Remote-VS-Code")"               "Remote-VS-Code"
is "subdir joins project"   "$(_rvc_ws_name "$WORKSPACE_DIR/Remote-VS-Code/remote-vs-code")" "Remote-VS-Code"
is "workspace file wins"    "$(_rvc_ws_name "$WORKSPACE_DIR/NetSapiens")"                    "NS"
is "workspace root"         "$(_rvc_ws_name "$WORKSPACE_DIR")"                               "claude"
is "home"                   "$(_rvc_ws_name "$HOME")"                                        "claude"
is "outside workspace"      "$(_rvc_ws_name /etc)"                                           "etc"
is "charset folded"         "$(_rvc_ws_name "$WORKSPACE_DIR/we ird+dir")"                    "we_ird_dir"

# Backwards compatibility: the .bashrc call sites invoke it with no argument.
( cd "$WORKSPACE_DIR/Remote-VS-Code" && [ "$(_rvc_ws_name)" = "Remote-VS-Code" ] ) \
  && ok "bare call uses \$PWD" || fail "bare call uses \$PWD" "did not match"

# WORKSPACE_DIR is honored, not hardcoded to ~/workspace.
mkdir -p "$TMP/alt/Thing/sub"
is "WORKSPACE_DIR honored" "$(WORKSPACE_DIR="$TMP/alt" _rvc_ws_name "$TMP/alt/Thing/sub")" "Thing"

finish
