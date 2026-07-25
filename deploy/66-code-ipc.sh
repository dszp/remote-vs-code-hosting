#!/usr/bin/env bash
# Keep the VM-side `code` CLI working across VS Code Remote-SSH reconnects.
#
# `code` run ON the VM reaches the connected VS Code window through the Unix
# socket named in $VSCODE_IPC_HOOK_CLI, captured when the shell started. A
# Remote-SSH reconnect spins up a NEW socket and abandons the old one WITHOUT
# deleting the file, so any shell that outlived the reconnect points at a dead
# socket and `code .` fails with:
#     Unable to connect to VS Code server: Error in request.
#     Error: connect ENOENT /run/user/<uid>/vscode-ipc-*.sock
#
# tmux's `update-environment VSCODE_IPC_HOOK_CLI` (config/tmux.conf) already
# refreshes the value for NEW panes on attach, but it can't fix a shell that is
# already open, and a file test can't tell a dead-but-present socket file from a
# live one (VS Code never unlinks the old files — they accumulate in the runtime
# dir). This installs a thin `code` wrapper that, only when you actually run
# `code`, repoints $VSCODE_IPC_HOOK_CLI at a socket that ACCEPTS a connection.
# It complements the tmux setting rather than replacing it.
#
# Newest-live-socket is only a guess, though: socket mtime is window CREATION
# time, so with several windows open it targets the newest one rather than the
# one you were just working in. So integrated terminals also stamp their own
# socket into $XDG_RUNTIME_DIR/vscode-ipc-latest, and the wrapper prefers that
# stamp over guessing. This is what lets a shell with no socket of its own — a
# tmux or herdr pane, a session attached from a plain ssh/mosh login — still
# land files in the window you actually used last. Backend-agnostic on purpose:
# it does not depend on tmux's update-environment.
#
# NOTE: this is the VM-side `code`. The Mac-side `rcode` (config/shell-helpers.sh),
# which opens a NEW window over Remote-SSH, is a separate mechanism — unaffected.
#
# Installs an idempotent ~/.bashrc.d/ drop-in (the stock AlmaLinux ~/.bashrc
# sources ~/.bashrc.d/*; we ensure that loop exists if a custom rc dropped it).
#
# RUN ON: the VM. run-remote sudo's; we write the dev user's home.
#   ./deploy/run-remote.sh __VM_NAME__ deploy/66-code-ipc.sh DEV_USER=__DEV_USER__
set -euo pipefail

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="/home/$DEV_USER"
RC="$HOME_DIR/.bashrc"
DROPIN_DIR="$HOME_DIR/.bashrc.d"
DROPIN="$DROPIN_DIR/vscode-ipc-refresh.sh"

install -d -o "$DEV_USER" -g "$DEV_USER" -m 0755 "$DROPIN_DIR"

# The wrapper drop-in (idempotent: overwritten on every deploy).
install -o "$DEV_USER" -g "$DEV_USER" -m 0644 /dev/stdin "$DROPIN" <<'WRAPPER'
# Keep the VS Code `code` CLI working across Remote-SSH reconnects.
# Managed by remote-vs-code deploy/66-code-ipc.sh — local edits are overwritten.
#
# `code` talks to the running VS Code server over the Unix socket named in
# $VSCODE_IPC_HOOK_CLI, captured when the shell started. A Remote-SSH reconnect
# creates a NEW socket and abandons the old one WITHOUT deleting the file, so a
# shell that outlived the reconnect points at a dead socket and `code` fails
# with `connect ENOENT/ECONNREFUSED .../vscode-ipc-*.sock`. A file test ([ -S ])
# can't tell live from dead — the abandoned socket file lingers on disk. The
# only reliable signal is actually connecting, so we do it lazily: the `code`
# wrapper repoints $VSCODE_IPC_HOOK_CLI at the newest socket that accepts a
# connection, and only when you run `code`. Zero idle overhead; one short-lived
# python probe per invocation.

# Does this unix socket have a live listener?  exit 0 = yes, 1 = dead/absent.
_vscode_sock_live() {
    python3 - "$1" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(0.5)
try:
    s.connect(sys.argv[1]); s.close()
except OSError:
    sys.exit(1)
PY
}

# Newest vscode-ipc socket (by mtime) that is actually live; prints it, or fails.
# mtime is the socket's CREATION time, so this means "newest WINDOW", which is not
# necessarily the window you were last working in — see the stamp below.
_vscode_newest_live() {
    local dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" s
    for s in $(ls -t "$dir"/vscode-ipc-*.sock 2>/dev/null); do
        _vscode_sock_live "$s" && { printf '%s' "$s"; return 0; }
    done
    return 1
}

# --- last-used-window stamp -------------------------------------------------
# Only a REAL integrated terminal knows which window it belongs to. Shells that
# never inherited a socket — tmux/herdr panes, sessions you attached to from a
# plain ssh/mosh login, anything that outlived its window — have to guess, and
# "newest socket" picks the most recently OPENED window, not the one you were
# just typing in. So integrated terminals record their socket here on startup,
# and everyone else prefers that over guessing. Lives in the runtime dir so it
# vanishes with the login session instead of going stale in $HOME.
_VSCODE_IPC_STAMP="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vscode-ipc-latest"

if [ -n "$VSCODE_IPC_HOOK_CLI" ] && [ "$TERM_PROGRAM" = vscode ]; then
    printf '%s\n' "$VSCODE_IPC_HOOK_CLI" > "$_VSCODE_IPC_STAMP" 2>/dev/null
fi

# The stamped socket, if it is still live; prints it, or fails.
_vscode_stamped_live() {
    local s
    [ -r "$_VSCODE_IPC_STAMP" ] || return 1
    IFS= read -r s < "$_VSCODE_IPC_STAMP" || return 1
    [ -n "$s" ] || return 1
    _vscode_sock_live "$s" && { printf '%s' "$s"; return 0; }
    return 1
}

# `code` wrapper: ensure a live IPC socket before delegating to the real CLI.
# Resolution order — own env if still live (correct window when several are open),
# else the last-used-window stamp, else newest live socket as a last guess.
code() {
    local live
    if [ -z "$VSCODE_IPC_HOOK_CLI" ] || ! _vscode_sock_live "$VSCODE_IPC_HOOK_CLI"; then
        live=$(_vscode_stamped_live) || live=$(_vscode_newest_live) || live=""
        [ -n "$live" ] && export VSCODE_IPC_HOOK_CLI="$live"
    fi
    command code "$@"
}
WRAPPER

# The stock AlmaLinux ~/.bashrc sources ~/.bashrc.d/*; ensure the loop exists in
# case a custom ~/.bashrc dropped it, so the drop-in actually loads.
if [ -f "$RC" ] && ! grep -q '\.bashrc\.d' "$RC"; then
  cat >> "$RC" <<'RC'

# >>> remote-vs-code: source ~/.bashrc.d drop-ins >>>
if [ -d ~/.bashrc.d ]; then for rc in ~/.bashrc.d/*; do [ -f "$rc" ] && . "$rc"; done; unset rc; fi
# <<< remote-vs-code: source ~/.bashrc.d drop-ins <<<
RC
  chown "$DEV_USER:$DEV_USER" "$RC"
  echo "added ~/.bashrc.d sourcing loop to $RC"
fi

echo "installed VS Code IPC-socket wrapper -> $DROPIN"
echo "  (new shells pick it up; an already-open shell: source '$DROPIN')"
