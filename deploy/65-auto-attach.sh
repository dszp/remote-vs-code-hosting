#!/usr/bin/env bash
# Make every INTERACTIVE shell on the VM auto-attach to a persistent tmux session
# NAMED AFTER THE FOLDER it starts in — so each VS Code window / project gets its
# own session and its own Claude automatically. The home dir maps to 'claude'
# (the session the boot service pre-creates). Covers VS Code terminals, ssh, mosh.
#
# Examples:
#   open ~/workspace/proj-a in VS Code -> terminal lands in session 'proj-a'
#   open ~/workspace/proj-b in another -> session 'proj-b' (independent, persists)
#   plain `ssh __VM_NAME__` (home dir)     -> session 'claude'
#
# Guards: interactive only (scp/rsync/`ssh host cmd`/VS Code server bootstrap are
# untouched), not already in tmux, tmux exists, and NO_AUTO_TMUX=1 opts out.
# Idempotent: replaces any previously-installed block between the markers.
#
# RUN ON: the VM. run-remote sudo's; we edit the dev user's ~/.bashrc.
#   ./deploy/run-remote.sh __VM_NAME__ deploy/65-auto-attach.sh DEV_USER=__DEV_USER__
set -euo pipefail

DEV_USER="${DEV_USER:-__DEV_USER__}"
RC="/home/$DEV_USER/.bashrc"

# Remove any prior block so re-running updates cleanly.
if grep -qF "# >>> remote-vs-code auto-attach tmux >>>" "$RC" 2>/dev/null; then
  sed -i '/# >>> remote-vs-code auto-attach tmux >>>/,/# <<< remote-vs-code auto-attach tmux <<</d' "$RC"
  echo "removed previous auto-attach block"
fi

cat >> "$RC" <<'RC'
# >>> remote-vs-code auto-attach tmux >>>
# Land in a persistent tmux session named after the current folder (home -> 'claude').
# Each VS Code window / project thus gets its own session. Opt out: NO_AUTO_TMUX=1
if [[ $- == *i* && -z "$TMUX" && -z "$NO_AUTO_TMUX" ]] && command -v tmux >/dev/null; then
  if [[ "$PWD" == "$HOME" ]]; then _rvc_sess="claude"; else _rvc_sess="${PWD##*/}"; fi
  _rvc_sess="${_rvc_sess//[^a-zA-Z0-9_-]/_}"   # tmux dislikes . and : in names
  tmux new -A -s "$_rvc_sess"
  unset _rvc_sess
fi
# <<< remote-vs-code auto-attach tmux <<<
RC
chown "$DEV_USER:$DEV_USER" "$RC"
echo "installed folder-named auto-attach block in $RC"
