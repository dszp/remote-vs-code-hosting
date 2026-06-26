#!/usr/bin/env bash
# Install /usr/local/bin/cs — a short "claude session" helper:
#   cs            attach/create the session for the current folder (home -> 'claude')
#   cs <name>     attach/create a named session
#   cs ls         list sessions
# Works inside tmux too (switches client instead of erroring on nesting).
# Rename: just install under a different name, or `mv /usr/local/bin/cs /usr/local/bin/<name>`.
#
# RUN ON: the VM.  ./deploy/run-remote.sh __VM_NAME__ deploy/70-cs-shortcut.sh
set -euo pipefail

BIN="${CS_BIN:-/usr/local/bin/cs}"
cat > "$BIN" <<'CS'
#!/usr/bin/env bash
# cs — attach/create a persistent tmux session.
#   cs            folder-named session (home -> 'claude')
#   cs <name>     a named session
#   cs -n [base]  a NEW independent session (base or folder, suffixed -2/-3 if taken)
#   cs ls         list sessions
set -euo pipefail
new=0
case "${1:-}" in
  ls|-l|list) exec tmux ls ;;
  -n|--new)   new=1; shift ;;
esac
base="${1:-}"
if [ -z "$base" ]; then
  if [ "$PWD" = "$HOME" ]; then base="claude"; else base="${PWD##*/}"; fi
fi
base="${base//[^a-zA-Z0-9_-]/_}"
name="$base"
if [ "$new" = 1 ]; then
  i=2; while tmux has-session -t "$name" 2>/dev/null; do name="${base}-$i"; i=$((i+1)); done
fi
if [ -n "${TMUX:-}" ]; then
  # already inside tmux: create if needed, then switch (can't nest-attach)
  tmux has-session -t "$name" 2>/dev/null || tmux new-session -d -s "$name"
  exec tmux switch-client -t "$name"
else
  exec tmux new -A -s "$name"
fi
CS
chmod 0755 "$BIN"
echo "installed $BIN"
"$BIN" ls >/dev/null 2>&1 || true
echo "usage: cs | cs <name> | cs ls"
