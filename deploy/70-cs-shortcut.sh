#!/usr/bin/env bash
# Install /usr/local/bin/cs — a short "claude session" helper:
#   cs            attach/create the session for the current folder (home -> 'claude')
#   cs .          same as `cs` (the current folder)
#   cs <dir>      if <dir> is a directory, the session is NAMED after it and STARTED in it,
#                 so from ~/workspace `cs Rem<Tab>` -> `cs Remote-VS-Code` works (the bash
#                 completion installed by 65-auto-attach.sh Tab-completes folder names)
#   cs <name>     a plain named session (started in the current dir)
#   cs -n [base]  a NEW independent session (suffixed -2/-3 if taken)
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
#   cs ls           list sessions
set -euo pipefail
new=0
case "${1:-}" in
  ls|-l|list) exec tmux ls ;;
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
echo "usage: cs | cs . | cs <dir|name> | cs -n | cs ls"
