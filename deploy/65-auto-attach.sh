#!/usr/bin/env bash
# Make every INTERACTIVE shell on the VM auto-attach to a persistent tmux session
# NAMED AFTER THE FOLDER it starts in — so each VS Code window / project gets its
# own session and its own Claude automatically. The home dir maps to 'claude'
# (the session the boot service pre-creates). Covers VS Code terminals, ssh, mosh.
#
# Anti-hijack: a new terminal attaches the first of <folder>, <folder>-2, <folder>-3, …
# that has NO live client. So Claude reconnects to its own <folder>, while a SECOND
# terminal opened against a session someone's already viewing (e.g. a code-server "+"
# tab vs the running Claude) lands on <folder>-2 instead of mirroring/fighting it.
# Reach the busy session deliberately with `cs <folder>` (forces it, -D).
#
# One reconnect wrinkle this creates: after a long laptop-off period VS Code REVIVES the
# dead terminal processes, and a revived shell re-runs this block and grabs the base
# session before the Claude-extension terminal does -> Claude lands on <folder>-2. The
# VS Code half of the fix lives in deploy/67-vscode-terminal-settings.sh
# (persistentSessionReviveProcess=never), which stops that revival; keep the two in sync.
#
# Also installs bash completion for `cs` (Tab-completes folder + session names like cd).
#
# Examples:
#   open ~/workspace/proj-a in VS Code -> terminal lands in session 'proj-a'
#   a 2nd terminal while 'proj-a' is viewed -> session 'proj-a-2'
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
# Land in a persistent tmux session. Claude Code keeps the folder-named session; a new
# TERMINAL instead reuses a FREE non-Claude session of that folder, or spins a fresh
# <folder>-N — so a code-server/VS Code "+" terminal never hijacks the Claude session.
# (Want the Claude session itself? run `cs <folder>` explicitly.) Opt out: NO_AUTO_TMUX=1
if [[ $- == *i* && -z "$TMUX" && -z "$NO_AUTO_TMUX" ]] && command -v tmux >/dev/null; then
  if [[ "$PWD" == "$HOME" ]]; then _rvc_base="claude"; else _rvc_base="${PWD##*/}"; fi
  _rvc_base="${_rvc_base//[^a-zA-Z0-9_-]/_}"   # tmux dislikes . and : in names
  # Attach the first of <base>, <base>-2, <base>-3, … that is NOT busy (no live client):
  # a free/new one is reused or created (so Claude reconnects to its own <base>), while a
  # session being actively viewed elsewhere is left alone, so the extra terminal gets <base>-N.
  _rvc_sess="$_rvc_base"; _rvc_i=1
  while tmux has-session -t "$_rvc_sess" 2>/dev/null \
        && [ -n "$(tmux list-clients -t "$_rvc_sess" -F x 2>/dev/null)" ]; do
    [ "$_rvc_i" -ge 50 ] && break
    _rvc_i=$((_rvc_i+1)); _rvc_sess="${_rvc_base}-${_rvc_i}"
  done
  tmux new -A -D -s "$_rvc_sess" -c "$PWD"
  unset _rvc_base _rvc_sess _rvc_i
fi

# Tab-complete `cs` like `cd`: folder names in the current dir + existing tmux sessions.
# So from ~/workspace:  cs Rem<Tab> -> cs Remote-VS-Code  (then attaches that session).
_cs_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local sessions; sessions="$(tmux ls -F '#{session_name}' 2>/dev/null)"
  mapfile -t COMPREPLY < <(printf '%s\n' $(compgen -d -- "$cur") $(compgen -W "$sessions" -- "$cur") | awk 'NF && !seen[$0]++')
}
complete -o filenames -F _cs_complete cs
# <<< remote-vs-code auto-attach tmux <<<
RC
chown "$DEV_USER:$DEV_USER" "$RC"
echo "installed folder-named auto-attach block (+ cs completion) in $RC"
