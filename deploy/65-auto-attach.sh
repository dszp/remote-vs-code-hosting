#!/usr/bin/env bash
# Auto-attach a persistent multiplexer session — in VS CODE INTEGRATED TERMINALS
# ONLY, and only when the policy asks for it.
#
# WHY VS CODE ONLY: the reason this exists is Claude-Code persistence. The Claude
# extension launches `claude` in a VS Code terminal, and if that terminal is a
# bare shell the session dies with the window. Auto-attaching there keeps Claude
# in tmux (with linger) so it survives reconnects. A HUMAN login has no such
# problem — you know which session you want and can say so — and being force-fed
# a session is actively annoying: `ssh __VM_NAME__` from Ghostty used to dump you
# into the 'claude' session (home dir -> base name 'claude'), fighting whatever
# was already attached there. So plain ssh/mosh logins (Ghostty, Moshi, Termius)
# now land in a NORMAL SHELL. Start one yourself:
#     mux             whichever backend the policy names (one word, either way)
#     mux use herdr   make herdr the default; `mux use tmux` / `mux use off`
#     cs [folder]     tmux, folder-named  (cs -h for the rest)
#     herdr           the herdr server directly
#
# POLICY: RVC_AUTO_MUX, read from ~/.config/remote-vs-code/mux.env so you can
# change it without redeploying (new terminals pick it up):
#     tmux    attach the folder-named tmux session   (default)
#     herdr   attach the herdr server instead
#     off     never auto-attach, even in VS Code — you type `cs` / `herdr`
# `off` is the right choice if you drive sessions from Moshi/herdr and want VS
# Code terminals to stay dumb shells; the cost is that the Claude extension's own
# terminal is then NOT persistent, so start Claude from `cs` instead.
#
# TMUX ANTI-HIJACK (tmux mode): a new terminal attaches the first of <folder>,
# <folder>-2, <folder>-3, … with NO live client. Claude reconnects to its own
# <folder>, while a second terminal opened against a session someone is already
# viewing lands on <folder>-2 rather than mirroring/fighting it. Reach a busy
# session deliberately with `cs <folder>` (forces it, -D). NOTE: a phone client
# (Moshi) counts as a live client, so a VS Code reconnect while your phone holds
# <folder> lands on <folder>-2 — that is the "why am I in -2" surprise. Use
# RVC_AUTO_MUX=off + `cs <folder>` if you'd rather always choose yourself.
#
# One reconnect wrinkle: after a long laptop-off period VS Code REVIVES dead
# terminal processes, and a revived shell re-runs this block and grabs the base
# session before the Claude-extension terminal does -> Claude lands on <folder>-2.
# The VS Code half of the fix lives in deploy/67-vscode-terminal-settings.sh
# (persistentSessionReviveProcess=never), which stops that revival; keep in sync.
#
# Also installs bash completion for `cs` (Tab-completes folder + session names).
#
# Guards: interactive only (scp/rsync/`ssh host cmd`/VS Code server bootstrap are
# untouched), not already inside a multiplexer, the tool exists, and
# NO_AUTO_TMUX=1 opts a single terminal out (the "shell (no tmux)" VS Code
# profile sets it). Idempotent: replaces any previously-installed block.
#
# RUN ON: the VM. run-remote sudo's; we edit the dev user's ~/.bashrc.
#   ./deploy/run-remote.sh __VM_NAME__ deploy/65-auto-attach.sh DEV_USER=__DEV_USER__
set -euo pipefail

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="/home/$DEV_USER"
RC="$HOME_DIR/.bashrc"
CONF_DIR="$HOME_DIR/.config/remote-vs-code"
CONF="$CONF_DIR/mux.env"

# Optional: also drop a standalone copy of the hs completion for the test suite.
# Extracted from the same heredoc that is appended to ~/.bashrc, so tests can
# never drift from what actually ships. $0 is this script; when run through
# run-remote.sh (stdin) $0 is "bash" and the sed finds nothing — harmless,
# because HS_COMPLETE_COPY is only ever set for local test builds.
emit_hs_complete() {
  sed -n '/^_hs_complete() {$/,/^complete -o filenames -F _hs_complete hs$/p' "$0"
}

# Remove any prior block so re-running updates cleanly. Both marker spellings:
# the block was "...auto-attach tmux" before it grew a herdr mode.
for marker in "auto-attach mux" "auto-attach tmux"; do
  if grep -qF "# >>> remote-vs-code $marker >>>" "$RC" 2>/dev/null; then
    sed -i "/# >>> remote-vs-code $marker >>>/,/# <<< remote-vs-code $marker <<</d" "$RC"
    echo "removed previous '$marker' block"
  fi
done

# The policy file: created once with the default, then left alone so a local
# choice survives redeploys.
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0755 "$CONF_DIR"
if [ ! -f "$CONF" ]; then
  install -o "$DEV_USER" -g "$DEV_USER" -m 0644 /dev/stdin "$CONF" <<'CONF'
# Which multiplexer VS Code integrated terminals auto-attach to.
#   tmux   folder-named tmux session (keeps the Claude extension's terminal persistent)
#   herdr  the herdr server
#   off    nothing — VS Code terminals stay plain shells; use `cs` or `herdr` by hand
# Plain ssh/mosh logins are NEVER auto-attached, whatever this says.
# Takes effect in new terminals; no redeploy needed.
RVC_AUTO_MUX=tmux
CONF
  echo "created $CONF (RVC_AUTO_MUX=tmux)"
else
  echo "kept existing $CONF ($(grep -h '^RVC_AUTO_MUX=' "$CONF" 2>/dev/null || echo 'RVC_AUTO_MUX unset'))"
fi

# The session-naming rule lives in ONE place: this lib. Both the .bashrc block
# below and /usr/local/bin/hs (deploy/71-hs-shortcut.sh) source it, so `hs` and
# VS Code auto-attach can never disagree about what a folder's session is called.
# Deploy scripts are streamed over stdin, so the content must be inline here.
WS_LIB_DIR="/usr/local/lib/remote-vs-code"
WS_LIB="$WS_LIB_DIR/ws-name.sh"
install -d -m 0755 "$WS_LIB_DIR"
install -m 0644 /dev/stdin "$WS_LIB" <<'WSLIB'
# _rvc_ws_name [dir] — session name for a directory (default $PWD).
#
# The *.code-workspace basename when there is one — a multi-root workspace is the
# real unit of work, and its name is stable no matter which of its folders the
# terminal happened to open in — else the PROJECT ROOT under $WORKSPACE_DIR, not
# the immediate folder, so a terminal in any subdir joins that project's one
# session instead of spawning a near-duplicate (…/Remote-VS-Code/remote-vs-code
# would otherwise get its own). Outside the workspace dir the project root is the
# directory itself, so /etc -> 'etc'. $HOME and $WORKSPACE_DIR both map to
# 'claude': a login lands in the workspace dir, and a bare `mux` there would
# otherwise produce a session literally named 'workspace'.
#
# herdr accepts only letters, numbers, '.', '_' and '-', so anything else is
# folded to '_' (note '.' IS legal, unlike tmux).
#
# Source of truth: deploy/65-auto-attach.sh. Do not edit in place — it is
# overwritten on every redeploy.
_rvc_ws_name() {
  local d="${1:-$PWD}"
  local ws="${WORKSPACE_DIR:-$HOME/workspace}" proot rel n="" f
  proot="$d"
  case "$d" in
    "$ws"/*) rel="${d#"$ws"/}"; proot="$ws/${rel%%/*}" ;;
  esac
  for f in "$d"/*.code-workspace "$proot"/*.code-workspace; do
    [ -f "$f" ] || continue
    n="${f##*/}"; n="${n%.code-workspace}"; break
  done
  if [ -z "$n" ]; then
    if [ "$d" = "$HOME" ] || [ "$d" = "$ws" ]; then n="claude"; else n="${proot##*/}"; fi
  fi
  printf '%s' "${n//[^A-Za-z0-9._-]/_}"
}
WSLIB
echo "installed $WS_LIB"
# Optional second copy so the repo's test suite can source the same bytes.
if [ -n "${WS_LIB_COPY:-}" ]; then
  install -d -m 0755 "$(dirname "$WS_LIB_COPY")"
  install -m 0644 "$WS_LIB" "$WS_LIB_COPY"
  echo "copied lib to $WS_LIB_COPY"
fi

cat >> "$RC" <<'RC'
# >>> remote-vs-code auto-attach mux >>>
# Auto-attach a persistent multiplexer — ONLY in VS Code integrated terminals.
# A plain ssh/mosh login (Ghostty, Moshi, Termius) lands in a normal shell; start
# a session yourself with `cs` (tmux) or `herdr`. Policy: RVC_AUTO_MUX in
# ~/.config/remote-vs-code/mux.env = tmux (default) | herdr | off.
# Per-terminal opt-out: NO_AUTO_TMUX=1. Rationale: deploy/65-auto-attach.sh.

# Land interactive LOGINS in the workspace dir rather than $HOME — it is the first
# cd of every session anyway. Deliberately narrow: only a fresh LOGIN shell that
# actually landed in $HOME moves, so nothing that picked a directory on purpose is
# overridden. Excluded on purpose:
#   - VS Code terminals: VS Code chose the folder, and $PWD is what names the herdr
#     session below, so moving it would rename the session out from under you.
#   - tmux / herdr panes: they restore their own cwd (and are not login shells).
#   - anything non-interactive: scp/rsync/`ssh host cmd` never reach this.
# Opt out for one shell: NO_AUTO_CD=1.
if [[ $- == *i* && -z "$TMUX" && -z "${HERDR_ENV:-}" && -z "${NO_AUTO_CD:-}" \
      && "${TERM_PROGRAM:-}" != "vscode" && "$PWD" == "$HOME" ]] \
   && shopt -q login_shell; then
  cd "${WORKSPACE_DIR:-$HOME/workspace}" 2>/dev/null || true
fi

# Session naming lives in one file shared with /usr/local/bin/hs, so `hs` and this
# auto-attach block can never disagree. Installed by deploy/65-auto-attach.sh.
# Same precedence ~/.claude/notify-remote.sh uses to decide which window to focus.
# The fallback keeps a shell usable if the lib is ever missing.
if [ -r /usr/local/lib/remote-vs-code/ws-name.sh ]; then
  . /usr/local/lib/remote-vs-code/ws-name.sh
else
  _rvc_ws_name() {
    local d="${1:-$PWD}" n
    if [ "$d" = "$HOME" ]; then n="claude"; else n="${d##*/}"; fi
    printf '%s' "${n//[^A-Za-z0-9._-]/_}"
  }
fi

if [[ $- == *i* && -z "$TMUX" && -z "${RVC_MUX_ACTIVE:-}" && -z "$NO_AUTO_TMUX" \
      && "${TERM_PROGRAM:-}" == "vscode" ]]; then
  # File is the default; an inherited RVC_AUTO_MUX (e.g. from a VS Code terminal
  # profile's env) wins, so don't let sourcing overwrite one that's already set.
  [ -z "${RVC_AUTO_MUX:-}" ] && [ -r ~/.config/remote-vs-code/mux.env ] \
    && . ~/.config/remote-vs-code/mux.env
  case "${RVC_AUTO_MUX:-tmux}" in
    tmux)
      if command -v tmux >/dev/null; then
        if [[ "$PWD" == "$HOME" ]]; then _rvc_base="claude"; else _rvc_base="${PWD##*/}"; fi
        _rvc_base="${_rvc_base//[^a-zA-Z0-9_-]/_}"   # tmux dislikes . and : in names
        # Attach the first of <base>, <base>-2, <base>-3, … that is NOT busy (no live
        # client): a free/new one is reused or created (so Claude reconnects to its own
        # <base>), while a session being actively viewed elsewhere is left alone.
        _rvc_sess="$_rvc_base"; _rvc_i=1
        while tmux has-session -t "$_rvc_sess" 2>/dev/null \
              && [ -n "$(tmux list-clients -t "$_rvc_sess" -F x 2>/dev/null)" ]; do
          [ "$_rvc_i" -ge 50 ] && break
          _rvc_i=$((_rvc_i+1)); _rvc_sess="${_rvc_base}-${_rvc_i}"
        done
        tmux new -A -D -s "$_rvc_sess" -c "$PWD"
        unset _rvc_base _rvc_sess _rvc_i
      fi
      ;;
    herdr)
      # A NAMED session per VS Code workspace, so each window is independent and
      # does NOT mirror whatever a phone/Ghostty client is looking at. herdr focus
      # is a session-level property (exactly one workspace is `focused`), so every
      # client on one session renders the same view — named sessions are the only
      # real isolation, each getting its own server and socket.
      #
      # DELIBERATE ASYMMETRY: only this auto-attach path derives a name. A human
      # running bare `herdr` or `mux` stays on `default`. If both sides derived the
      # same name from the same folder they would collide right back into mirroring,
      # which is the thing this is here to avoid.
      #
      # RVC_MUX_ACTIVE is exported so panes the herdr SERVER spawns — which inherit
      # the server's env, TERM_PROGRAM=vscode included — don't recurse into herdr.
      # Not exec'd, so detaching (ctrl+b q) drops you to this shell instead of
      # closing the terminal, matching the tmux branch.
      if command -v herdr >/dev/null; then
        RVC_MUX_ACTIVE=herdr herdr --session "$(_rvc_ws_name)"
      fi
      ;;
    off|*) : ;;
  esac
fi

# `mux` — one word to get a session, whichever backend you're currently on, so
# muscle memory doesn't have to track which multiplexer you've settled on.
#   mux                  launch per policy (herdr if selected, else tmux via `cs`)
#   mux tmux | mux herdr  launch that one NOW without changing the policy
#   mux use <tmux|herdr|off>   set the persistent policy (what VS Code auto-attaches)
#   mux status           show the policy and what's running
# Note `off` only disables AUTO-attach; bare `mux` still gives you tmux, since a
# command you typed on purpose should do something. Want herdr occasionally
# without making it the default? `mux herdr`.
# Optional $1 = session name. Bare (no name) means the 'default' session on
# purpose: VS Code auto-attach uses workspace-named sessions, and a human landing
# on the same derived name would collide back into a mirrored view.
# `mux herdr ws` opts in to the same name VS Code would pick for this directory.
_mux_herdr() {
  if [ -n "${RVC_MUX_ACTIVE:-}" ]; then echo "already inside herdr" >&2; return 1; fi
  command -v herdr >/dev/null || { echo "mux: herdr is not installed" >&2; return 1; }
  local n="${1:-}"
  [ "$n" = "ws" ] && n="$(_rvc_ws_name)"
  if [ -n "$n" ]; then RVC_MUX_ACTIVE=herdr herdr --session "$n"
  else RVC_MUX_ACTIVE=herdr herdr; fi
}
mux() {
  local conf="$HOME/.config/remote-vs-code/mux.env" pol=""
  [ -r "$conf" ] && pol="$(sed -n 's/^RVC_AUTO_MUX=//p' "$conf" | tail -1)"
  pol="${pol:-tmux}"
  case "${1:-}" in
    use)
      case "${2:-}" in
        tmux|herdr|off)
          mkdir -p "${conf%/*}"
          if [ -f "$conf" ] && grep -q '^RVC_AUTO_MUX=' "$conf"; then
            sed -i "s|^RVC_AUTO_MUX=.*|RVC_AUTO_MUX=$2|" "$conf"
          else
            printf 'RVC_AUTO_MUX=%s\n' "$2" >> "$conf"
          fi
          echo "policy -> $2 (VS Code terminals; applies to NEW terminals)" ;;
        *) echo "usage: mux use <tmux|herdr|off>" >&2; return 2 ;;
      esac ;;
    status)
      echo "policy (VS Code auto-attach): $pol"
      printf 'tmux sessions: %s\n' "$(tmux ls 2>/dev/null | wc -l)"
      if command -v herdr >/dev/null; then echo "herdr: $(herdr --version 2>/dev/null)"
      else echo "herdr: not installed"; fi ;;
    tmux)  cs ;;
    herdr) _mux_herdr "${2:-}" ;;
    "")    case "$pol" in herdr) _mux_herdr ;; *) cs ;; esac ;;
    -h|--help|help)
      echo "mux [tmux | herdr [<name>|ws]] | mux use <tmux|herdr|off> | mux status" ;;
    *) echo "usage: mux [tmux|herdr] | mux use <tmux|herdr|off> | mux status" >&2; return 2 ;;
  esac
}

# hn — name THIS pane's herdr agent (optionally its space too) with no ID lookup.
#   hn              show this pane's agent + space labels
#   hn <name>       name the agent
#   hn -w <name>    name the agent AND its space
#   hn --clear      back to herdr's auto label
#
# Why this exists when everything else is a keystroke: herdr binds rename-tab
# (prefix+shift+t) and rename-workspace (prefix+,) but there is NO rename_agent key —
# `config check` rejects it as an unknown key, so agent labels are CLI-only. And the
# agent label is the one that matters for navigation, because in the TUI the agents
# list IS clickable (clicking one jumps to its tab) while the tab bar and space list
# are not, so you steer by agent name.
#
# A herdr pane exports HERDR_PANE_ID / HERDR_WORKSPACE_ID / HERDR_SOCKET_PATH, and the
# CLI honors the socket path, so a bare `herdr` call from inside a pane already talks to
# that pane's own server — no --session needed even in a named session. Uses the env
# rather than `herdr pane current` on purpose: env names the pane this shell lives in,
# while `current` names the FOCUSED pane, which is not always the same one.
hn() {
  local pane="${HERDR_PANE_ID:-}" wsid="${HERDR_WORKSPACE_ID:-}" both=0
  if [ -z "$pane" ]; then echo "hn: not inside a herdr pane" >&2; return 1; fi
  case "${1:-}" in
    -h|--help) echo "hn [-w] <name> | hn --clear | hn   (name this pane's agent; -w also names its space)"; return 0 ;;
    --clear)   herdr agent rename "$pane" --clear >/dev/null && echo "agent label cleared ($pane)"; return ;;
    -w|--workspace) both=1; shift ;;
  esac
  if [ -z "${1:-}" ]; then
    # NB the agent's custom name lives in "name"; "label" is the WORKSPACE field. Reading
    # the wrong one makes a successful rename look like a no-op. Also print the terminal
    # title, which for Claude is its own live task summary.
    herdr agent get "$pane" 2>/dev/null | python3 -c 'import sys,json
a=json.load(sys.stdin)["result"]["agent"]
print("  agent %s  name=%r  status=%s" % (a.get("agent"), a.get("name"), a.get("agent_status")))
t=a.get("terminal_title_stripped")
if t: print("  doing %r" % t)' 2>/dev/null \
      || echo "  (no agent detected in $pane)"
    [ -n "$wsid" ] && herdr workspace get "$wsid" 2>/dev/null | python3 -c 'import sys,json
w=json.load(sys.stdin)["result"]["workspace"]
print("  space %s  label=%r" % (w.get("workspace_id"), w.get("label")))' 2>/dev/null
    # `hn` reads like a verb, so say plainly that the bare form only reports.
    echo "  (report only — 'hn <name>' renames the agent, 'hn -w <name>' the space too)"
    return 0
  fi
  herdr agent rename "$pane" "$1" >/dev/null && echo "agent -> $1 ($pane)"
  if [ "$both" = 1 ] && [ -n "$wsid" ]; then
    herdr workspace rename "$wsid" "$1" >/dev/null && echo "space -> $1 ($wsid)"
  fi
}

# Tab-complete `cs` like `cd`: folder names in the current dir + existing tmux sessions.
# So from ~/workspace:  cs Rem<Tab> -> cs Remote-VS-Code  (then attaches that session).
_cs_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local sessions; sessions="$(tmux ls -F '#{session_name}' 2>/dev/null)"
  mapfile -t COMPREPLY < <(printf '%s\n' $(compgen -d -- "$cur") $(compgen -W "$sessions" -- "$cur") | awk 'NF && !seen[$0]++')
}
complete -o filenames -F _cs_complete cs
complete -W "tmux herdr use status" mux

# Tab-complete `hs` like `cs`: folder names in the current dir + herdr session
# names + the verbs. Session names come straight from herdr rather than through
# `hs`, so Tab keeps working while hs is being redeployed; if herdr is missing or
# erroring, completion quietly degrades to directories instead of breaking.
_hs_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}" prev="" json names verbs
  [ "$COMP_CWORD" -gt 1 ] && prev="${COMP_WORDS[COMP_CWORD-1]}"
  verbs="s switch attach x stop k kill rm delete ls list -n -h"
  json="$(herdr session list --json 2>/dev/null)" || json=""
  if [ -n "$json" ]; then
    # `hs rm` only accepts a stopped session, so offer only those.
    case "$prev" in
      rm|delete) names="$(printf '%s' "$json" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print("\n".join(s.get("name","") for s in d.get("sessions",[]) if not s.get("running")))' 2>/dev/null)" ;;
      *)         names="$(printf '%s' "$json" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print("\n".join(s.get("name","") for s in d.get("sessions",[])))' 2>/dev/null)" ;;
    esac
  else
    names=""
  fi
  case "$prev" in
    rm|delete|s|switch|attach|x|stop|k|kill) verbs="" ;;
  esac
  mapfile -t COMPREPLY < <(printf '%s\n' \
    $(compgen -d -- "$cur") \
    $(compgen -W "$names" -- "$cur") \
    $(compgen -W "$verbs" -- "$cur") | awk 'NF && !seen[$0]++')
}
complete -o filenames -F _hs_complete hs
# <<< remote-vs-code auto-attach mux <<<
RC
chown "$DEV_USER:$DEV_USER" "$RC"
echo "installed VS-Code-only auto-attach block (+ cs completion) in $RC"

if [ -n "${HS_COMPLETE_COPY:-}" ]; then
  install -d -m 0755 "$(dirname "$HS_COMPLETE_COPY")"
  emit_hs_complete > "$HS_COMPLETE_COPY"
  echo "copied hs completion to $HS_COMPLETE_COPY"
fi
