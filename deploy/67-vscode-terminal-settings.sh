#!/usr/bin/env bash
# The VS Code half of the reconnect story (65-auto-attach.sh is the tmux half).
#
# THE RACE: after the laptop is off for hours the Remote-SSH link fully drops and the
# VS Code server / pty host on the VM is torn down. On reconnect VS Code *revives*
# (re-creates) the dead terminal processes; each revived shell re-runs ~/.bashrc, whose
# folder-named tmux auto-attach (65-auto-attach.sh) grabs the base session '<folder>'
# FIRST — so the Claude-extension terminal, launching a beat later, hits the anti-hijack
# path and lands on '<folder>-2'. You then have to exit and `cs <folder>` back to the
# original.
#
# THE FIX: set `terminal.integrated.persistentSessionReviveProcess: never` so VS Code
# does NOT re-create a killed terminal process — the tab returns as static history
# instead of a fresh shell that re-runs .bashrc and races. This is deliberately the
# *soft* switch: `enablePersistentSessions` is left at its default (true), so the
# RECONNECT path (process still alive — a plain Reload Window, or a short blip where
# the server stayed up) still reattaches terminals to their live, tmux-backed shells.
# Only the REVIVE path (process was actually killed) is disabled — exactly the case
# that spawned the '-2'. Durable Claude work lives in tmux, so it is unaffected either way.
#
# TWO client surfaces, both MACHINE-scoped and both VM-side (the setting defaults to
# window scope, which is settable at machine level):
#   - native Remote-SSH server -> ~/.vscode-server/data/Machine/settings.json
#   - code-server (browser IDE) -> ~/.local/share/code-server/Machine/settings.json
#
# Idempotent & non-destructive: creates the file if absent; if the key is already
# present it leaves the existing value alone (respects hand-edits); it backs up before
# any merge; and if a file isn't plain JSON (e.g. hand-added // comments that jq can't
# parse) it refuses to touch it and tells you to add the key by hand. Best run AFTER
# you've connected via each client at least once, so the data dirs already exist.
#
# RUN ON: the VM.
#   ./deploy/run-remote.sh __VM_NAME__ deploy/67-vscode-terminal-settings.sh DEV_USER=__DEV_USER__
#
# To VERIFY it: a plain Reload Window won't show a difference (that's the reconnect
# path). Fully CLOSE the VS Code window/app and reopen connected to the VM — closing is
# what triggers process shutdown, so the revive-vs-not path runs; the terminal should
# come back inert and the Claude extension should claim the base session, not '-2'.
set -euo pipefail

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="/home/$DEV_USER"
KEY="terminal.integrated.persistentSessionReviveProcess"
VAL="never"

command -v jq >/dev/null 2>&1 || { echo "!! jq not found — install jq first" >&2; exit 1; }

FILES=(
  "$HOME_DIR/.vscode-server/data/Machine/settings.json"          # native Remote-SSH
  "$HOME_DIR/.local/share/code-server/Machine/settings.json"     # code-server (browser)
)

ensure_setting() {
  local f="$1" dir tmp
  dir="$(dirname "$f")"
  # Create any missing dirs owned by the dev user (existing ones are left untouched),
  # so we never leave a root-owned ~/.vscode-server that the VS Code server can't use.
  install -d -o "$DEV_USER" -g "$DEV_USER" "$dir"

  if [ ! -s "$f" ]; then
    printf '{\n  "%s": "%s"\n}\n' "$KEY" "$VAL" > "$f"
    chown "$DEV_USER:$DEV_USER" "$f"; chmod 644 "$f"
    echo ">> $f: created with $KEY=$VAL"
    return
  fi

  if grep -q "$KEY" "$f"; then
    echo ">> $f: $KEY already present — leaving as-is"
    return
  fi

  # Never clobber a file we can't parse (JSONC with comments, etc.).
  if ! jq -e . "$f" >/dev/null 2>&1; then
    echo "!! $f: not plain JSON (comments?) — NOT modifying; add \"$KEY\": \"$VAL\" by hand" >&2
    return
  fi

  cp -p "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp "$dir/.rvc-settings.XXXXXX")"
  jq --indent 2 --arg k "$KEY" --arg v "$VAL" '. + {($k): $v}' "$f" > "$tmp"
  mv "$tmp" "$f"
  chown "$DEV_USER:$DEV_USER" "$f"; chmod 644 "$f"
  echo ">> $f: added $KEY=$VAL (backup written alongside)"
}

for f in "${FILES[@]}"; do ensure_setting "$f"; done
echo ">> done. Reload VS Code / reconnect for it to take effect (see header for how to verify)."
