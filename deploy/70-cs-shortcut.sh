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
# cs — attach/create a persistent tmux session (folder-named by default).
set -euo pipefail
case "${1:-}" in
  ls|-l|list) exec tmux ls ;;
esac
name="${1:-}"
if [ -z "$name" ]; then
  if [ "$PWD" = "$HOME" ]; then name="claude"; else name="${PWD##*/}"; fi
  name="${name//[^a-zA-Z0-9_-]/_}"
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
