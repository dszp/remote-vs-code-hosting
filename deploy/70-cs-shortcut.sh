#!/usr/bin/env bash
# Install /usr/local/bin/cs — a short "claude session" helper:
#   cs            attach/create the session for the current folder (home -> 'claude')
#   cs .          same as `cs` (the current folder)
#   cs <dir>      if <dir> is a directory, the session is NAMED after it and STARTED in it,
#                 so from ~/workspace `cs Rem<Tab>` -> `cs Remote-VS-Code` works (the bash
#                 completion installed by 65-auto-attach.sh Tab-completes folder names)
#   cs <name>     a plain named session (started in the current dir)
#   cs -n [base]  a NEW independent session (suffixed -2/-3 if taken)
#   cs s|d|k [n]  switch / detach-all-clients / kill a session — name N if given, else fzf
#                 (aliases: cs switch | cs detach | cs kill; picker shows client counts)
#   cs ls         list sessions
# Attaches with -D so a reconnect detaches any stale client (no mirror/scroll-lock).
# Works inside tmux too (switches client instead of erroring on nesting).
#
# RUN ON: the VM.  ./deploy/run-remote.sh __VM_NAME__ deploy/70-cs-shortcut.sh
set -euo pipefail

BIN="${CS_BIN:-/usr/local/bin/cs}"
cat > "$BIN" <<'CS'
#!/usr/bin/env bash
# cs — attach/create a persistent tmux session (attaches with -D so a reconnect
# detaches any stale client; no mirror/scroll-lock).
#   cs              session named after the current folder (home -> 'claude')
#   cs .            same as `cs` (the current folder)
#   cs <dir>        if <dir> is a directory, the session is NAMED after it and STARTED
#                   in it — so from ~/workspace, `cs Rem<Tab>` -> `cs Remote-VS-Code`
#                   works without cd'ing first (Tab-completes folder names, like cd)
#   cs <name>       otherwise, a plain named session (started in the current dir)
#   cs -n [base]    a NEW independent session (base/folder, suffixed -2/-3 if taken)
#   cs s [name]     switch/attach to a session — NAME if given, else fzf-pick (alias: cs switch)
#   cs d [name]     detach ALL clients from a session (alias: cs detach; frees it, never kills)
#   cs k [name]     KILL a session                    (alias: cs kill)
#                   bare s/d/k pick via fzf (the list shows each session's client count);
#                   `cs s` (bare) falls back to tmux choose-tree without fzf
#   cs ls           list sessions
set -euo pipefail
new=0
case "${1:-}" in
  ls|-l|list) exec tmux ls ;;
  -h|--help|help)
    cat <<'USAGE'
cs — attach/create a persistent tmux session (attaches with -D: a reconnect detaches the stale client)
  cs              session for the current folder (home -> 'claude')
  cs .            same as `cs` (the current folder)
  cs <dir>        name a session after a folder AND start it there (Tab-completes like cd)
  cs <name>       a plain named session (started in the current dir)
  cs -n [base]    a NEW independent session (suffixed -2/-3 if taken)
  cs s|switch [name]   switch/attach to a session — NAME if given, else pick (fzf)
  cs d|detach [name]   detach ALL clients from a session (frees it; never kills)
  cs k|kill   [name]   KILL a session   (bare picker list shows each session's client count)
  cs ls           list sessions
  cs -h | --help  this help
USAGE
    exit 0 ;;
  s|switch|select|-s|d|detach|k|kill)
    act="$1"; sel="${2:-}"
    if [ -z "$sel" ]; then    # bare -> pick interactively
      if ! command -v fzf >/dev/null 2>&1; then
        case "$act" in s|switch|select|-s) [ -n "${TMUX:-}" ] && exec tmux choose-tree -Zs ;; esac
        echo "cs $act needs fzf (e.g. 'sudo dnf install fzf'), or pass a session name" >&2; exit 1
      fi
      case "$act" in
        s|switch|select|-s) prompt="switch to" ;;
        d|detach)           prompt="detach all from" ;;
        k|kill)             prompt="KILL" ;;
      esac
      sel="$(tmux list-sessions -F '#{session_name}: #{session_windows} win · #{session_attached} client(s)' 2>/dev/null | fzf --reverse --height=40% --prompt="$prompt> " | cut -d: -f1)" || true
    fi
    [ -n "${sel:-}" ] || exit 0
    case "$act" in
      s|switch|select|-s)
        if [ -n "${TMUX:-}" ]; then exec tmux switch-client -t "$sel"; else exec tmux attach -d -t "$sel"; fi ;;
      d|detach)
        if tmux detach-client -s "$sel" 2>/dev/null; then echo "detached all clients from '$sel'"; else echo "no clients on '$sel' (or gone)"; fi ;;
      k|kill)
        if tmux kill-session -t "$sel" 2>/dev/null; then echo "killed session '$sel'"; else echo "could not kill '$sel'" >&2; fi ;;
    esac
    exit 0
    ;;
  -n|--new)   new=1; shift ;;
esac
arg="${1:-}"
startdir="$PWD"
if [ -z "$arg" ]; then
  if [ "$PWD" = "$HOME" ]; then base="claude"; else base="${PWD##*/}"; fi
elif [ -d "$arg" ]; then
  startdir="$(cd -- "$arg" && pwd)"
  if [ "$startdir" = "$HOME" ]; then base="claude"; else base="${startdir##*/}"; fi
else
  base="$arg"
fi
base="${base//[^a-zA-Z0-9_-]/_}"   # tmux dislikes . and : in names
name="$base"
if [ "$new" = 1 ]; then
  i=2; while tmux has-session -t "$name" 2>/dev/null; do name="${base}-$i"; i=$((i+1)); done
fi
if [ -n "${TMUX:-}" ]; then
  # already inside tmux: create if needed (in startdir), then switch (can't nest-attach)
  tmux has-session -t "$name" 2>/dev/null || tmux new-session -d -s "$name" -c "$startdir"
  exec tmux switch-client -t "$name"
else
  exec tmux new -A -D -s "$name" -c "$startdir"
fi
CS
chmod 0755 "$BIN"
echo "installed $BIN"
"$BIN" ls >/dev/null 2>&1 || true
echo "usage: cs | cs . | cs <dir|name> | cs -n | cs s|d|k | cs ls"
