#!/usr/bin/env bash
# Install /usr/local/bin/hs — a "herdr session" helper, sibling to `cs` (tmux).
#   hs             attach/create the session for the current folder
#   hs <dir>       name a session after a folder AND start it there (Tab-completes)
#   hs <name>      a plain named session, started in the current dir
#   hs -n [base]   a NEW independent session (suffixed -2/-3 if taken)
#   hs s [name]    attach              (bare -> fzf picker)
#   hs x [name]    stop  (hibernate; layout survives, processes die)
#   hs k [name]    stop AND delete     (prompts when running; -y skips)
#   hs rm [name]   delete a STOPPED session  (never herdr's default session)
#   hs ls          list name / status / directory
#
# Naming comes from /usr/local/lib/remote-vs-code/ws-name.sh (deploy/65), the same
# rule VS Code auto-attach uses, so `hs` never spawns a near-duplicate session.
#
# There is deliberately no `hs d`: unlike tmux, herdr renders per-client (two
# clients attach at different sizes without mirroring), so a stale client costs
# nothing — and the socket API exposes no kick-client request anyway.
#
# RUN ON: the VM.  ./deploy/run-remote.sh __VM_NAME__ deploy/71-hs-shortcut.sh
# Requires deploy/65-auto-attach.sh to have run (it installs the naming lib).
set -euo pipefail

BIN="${HS_BIN:-/usr/local/bin/hs}"
install -d -m 0755 "$(dirname "$BIN")"
cat > "$BIN" <<'HS'
#!/usr/bin/env bash
# hs — herdr session manager. Sibling to `cs`, which does this for tmux.
# Source of truth: deploy/71-hs-shortcut.sh. Overwritten on every redeploy.
set -euo pipefail

WS_LIB="${HS_WS_LIB:-/usr/local/lib/remote-vs-code/ws-name.sh}"
HERDR_DIR="${HS_HERDR_DIR:-$HOME/.config/herdr}"

die() { printf 'hs: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
hs — attach/create a persistent herdr session (sibling to `cs` for tmux)
  hs                  session for the current folder (home -> 'claude')
  hs .                same as `hs`
  hs <dir>            name a session after a folder AND start it there
  hs <name>           a plain named session (started in the current dir)
  hs -n [base]        a NEW independent session (suffixed -2/-3 if taken)
  hs s|switch|attach [name]   attach                    (bare -> fzf picker)
  hs x|stop          [name]   stop only (layout is kept on disk)
  hs k|kill     [-y] [name]   stop AND delete (prompts while running)
  hs rm|delete       [name]   delete a STOPPED session
  hs ls|list                  list name / status / directory
  hs -h | --help              this help
There is no `hs d`: herdr renders per-client, so a stale client costs nothing.
herdr's default session can be stopped but never deleted.
USAGE
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

command -v herdr >/dev/null 2>&1 || die "herdr is not installed"

# --- session enumeration ---------------------------------------------------
# `herdr session list --json` knows name/running/session_dir but NOT the working
# directory, so each session's session.json is read for its identity_cwd. That
# file survives a stop, so stopped sessions still show where they live.
# Output is TSV: name \t running|stopped \t cwd ('-' when unknown) \t default|-.
hs_sessions() {
  local json
  if ! json="$(herdr session list --json 2>&1)"; then
    printf '%s\n' "$json" >&2
    die "herdr session list failed"
  fi
  printf '%s' "$json" | HS_HD="$HERDR_DIR" python3 -c '
import json, os, sys
hd = os.environ["HS_HD"]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit("hs: could not parse `herdr session list --json`")
for s in data.get("sessions", []):
    name = s.get("name", "")
    if not name:
        continue
    status = "running" if s.get("running") else "stopped"
    sdir = s.get("session_dir")
    if not sdir:
        sdir = hd if s.get("default") else os.path.join(hd, "sessions", name)
    cwd = "-"
    try:
        with open(os.path.join(sdir, "session.json")) as fh:
            sj = json.load(fh)
        wss = sj.get("workspaces") or []
        idx = sj.get("active", 0)
        if not isinstance(idx, int) or not 0 <= idx < len(wss):
            idx = 0
        cwd = wss[idx].get("identity_cwd") or "-"
    except Exception:
        pass
    print("\t".join((name, status, cwd, "default" if s.get("default") else "-")))
'
}

# TSV on stdin -> aligned rows, $HOME abbreviated to ~.
hs_fmt() {
  HS_HOME="$HOME" python3 -c '
import os, sys
home = os.environ["HS_HOME"]
rows = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = (line.split("\t") + ["", "", ""])[:3]
    name, status, cwd = parts
    if cwd == home:
        cwd = "~"
    elif home and cwd.startswith(home + "/"):
        cwd = "~" + cwd[len(home):]
    rows.append((name, status, cwd))
if not rows:
    sys.exit(0)
w = max(len(r[0]) for r in rows)
try:
    for name, status, cwd in rows:
        dot = "●" if status == "running" else "○"
        print("%-*s  %s %-7s %s" % (w, name, dot, status, cwd))
    sys.stdout.flush()
except BrokenPipeError:
    # The reader went away — fzf exits the moment Esc is pressed. Point stdout at
    # /dev/null so the interpreter shutdown flush cannot print its own complaint.
    os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    sys.exit(0)
'
}

case "${1:-}" in
  ls|list|-l) hs_sessions | hs_fmt; exit 0 ;;
esac

# --- naming ----------------------------------------------------------------
if [ -r "$WS_LIB" ]; then
  . "$WS_LIB"
else
  printf 'hs: %s missing — falling back to basename naming\n' "$WS_LIB" >&2
  _rvc_ws_name() {
    local d="${1:-$PWD}" n
    if [ "$d" = "$HOME" ]; then n="claude"; else n="${d##*/}"; fi
    printf '%s' "${n//[^A-Za-z0-9._-]/_}"
  }
fi

# A herdr session name becomes a directory under ~/.config/herdr/sessions/, so
# path-traversal shapes and option-lookalikes are refused outright.
check_name() {
  case "${1:-}" in
    "")   die "empty session name" ;;
    .|..) die "refusing session name '$1'" ;;
    -*)   die "refusing session name starting with '-': '$1'" ;;
  esac
}

# herdr cannot nest. Launching would either fail confusingly or strand a server.
guard_nesting() {
  if [ -n "${HERDR_PANE_ID:-}" ] || [ -n "${RVC_MUX_ACTIVE:-}" ]; then
    die "already inside herdr — use the workspace_picker keybind (default prefix+w) to switch spaces"
  fi
}

run() {
  if [ -n "${HS_DRY_RUN:-}" ]; then printf 'EXEC: %s\n' "$*"; exit 0; fi
  exec "$@"
}

# RVC_MUX_ACTIVE mirrors what _mux_herdr sets, so the .bashrc auto-attach block
# does not re-trigger inside the panes this server spawns.
launch() { # $1 name, $2 startdir
  guard_nesting
  check_name "$1"
  cd "$2" || die "cannot cd to $2"
  run env RVC_MUX_ACTIVE=herdr herdr --session "$1"
}

hcmd() {
  if [ -n "${HS_DRY_RUN:-}" ]; then printf 'RUN: %s\n' "$*"; return 0; fi
  "$@"
}

session_status() { hs_sessions | awk -F'\t' -v n="$1" '$1==n {print $2; exit}'; }

# herdr's default session (the one at the root of ~/.config/herdr, with no
# sessions/<name>/ dir of its own) can be stopped but NOT deleted — the server
# answers `session delete` with session_delete_failed. Refuse before stopping
# anything, so `hs k` cannot half-succeed.
is_default() { [ "$(hs_sessions | awk -F'\t' -v n="$1" '$1==n {print $4; exit}')" = default ]; }
refuse_default_delete() {
  is_default "$1" || return 0
  die "$1 is herdr's default session — herdr cannot delete it; 'hs x $1' stops it instead"
}

require_session() { # prints the status, or explains and exits
  local st; st="$(session_status "$1")"
  if [ -z "$st" ]; then
    printf 'hs: no session named %s\n' "$1" >&2
    printf 'known sessions:\n' >&2
    hs_sessions | hs_fmt >&2
    exit 1
  fi
  printf '%s' "$st"
}

pick() { # $1 prompt, $2 filter -> selected name on stdout ('' if cancelled)
  local rows sel
  rows="$(hs_sessions)"
  # The default session is never offered for a delete: herdr would refuse it.
  case "$2" in
    stopped)   rows="$(printf '%s\n' "$rows" | awk -F'\t' '$2=="stopped" && $4!="default"')" ;;
    deletable) rows="$(printf '%s\n' "$rows" | awk -F'\t' '$4!="default"')" ;;
  esac
  if [ -z "$rows" ]; then
    case "$2" in
      stopped) die "no deletable stopped sessions to choose from" ;;
      *)       die "no sessions to choose from" ;;
    esac
  fi
  if ! command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$rows" | hs_fmt >&2
    die "picking needs fzf (sudo dnf install fzf), or pass a session name"
  fi
  # Names are [A-Za-z0-9._-] only, so field 1 of the formatted row is the name.
  sel="$(printf '%s\n' "$rows" | hs_fmt \
         | fzf --reverse --height=40% --prompt="$1> " | awk '{print $1}')" || true
  printf '%s' "${sel:-}"
}

confirm() { # $1 prompt — true when -y was given or the user says yes
  [ "${assume_yes:-0}" = 1 ] && return 0
  local reply
  printf '%s [y/N] ' "$1" >&2
  read -r reply || return 1
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Stopping the session you are sitting in works, but should never be a surprise.
warn_if_current() {
  local sock="${HERDR_SOCKET_PATH:-}"
  [ -n "$sock" ] || return 0
  case "$sock" in
    "$HERDR_DIR/sessions/$1/"*|"$HERDR_DIR/$1.sock")
      printf 'hs: note — %s is the session you are currently inside\n' "$1" >&2 ;;
  esac
}

case "${1:-}" in
  s|switch|select|attach|x|stop|k|kill|rm|delete)
    act="$1"; shift
    assume_yes=0; sel=""
    for a in "$@"; do
      case "$a" in
        -y|-f|--yes|--force) assume_yes=1 ;;
        *) [ -z "$sel" ] && sel="$a" ;;
      esac
    done
    if [ -z "$sel" ]; then
      case "$act" in
        s|switch|select|attach) sel="$(pick "attach to" all)" ;;
        x|stop)                 sel="$(pick "stop" all)" ;;
        k|kill)                 sel="$(pick "STOP AND DELETE" deletable)" ;;
        rm|delete)              sel="$(pick "delete" stopped)" ;;
      esac
      # An empty selection means the user pressed Esc. Silent success, like cs.
      [ -n "$sel" ] || exit 0
    fi
    check_name "$sel"
    st="$(require_session "$sel")"

    case "$act" in
      s|switch|select|attach)
        # `herdr --session` attaches a running session and revives a stopped one.
        launch "$sel" "$PWD" ;;
      x|stop)
        if [ "$st" = stopped ]; then
          printf 'hs: %s is already stopped\n' "$sel"; exit 0
        fi
        warn_if_current "$sel"
        hcmd herdr session stop "$sel" ;;
      rm|delete)
        refuse_default_delete "$sel"
        if [ "$st" = running ]; then
          die "$sel is running — stop it first with 'hs x $sel', or use 'hs k $sel' to do both"
        fi
        hcmd herdr session delete "$sel" ;;
      k|kill)
        refuse_default_delete "$sel"
        if [ "$st" = running ]; then
          # Unlike tmux, this discards saved layout as well as live processes.
          confirm "Stop AND delete running session '$sel'? Its saved layout is discarded." \
            || { printf 'hs: left %s alone\n' "$sel"; exit 0; }
          warn_if_current "$sel"
          hcmd herdr session stop "$sel"
        fi
        hcmd herdr session delete "$sel" ;;
    esac
    exit 0
    ;;
esac

new=0
case "${1:-}" in
  -n|--new) new=1; shift ;;
esac

arg="${1:-}"
startdir="$PWD"
if [ -z "$arg" ] || [ "$arg" = "." ]; then
  base="$(_rvc_ws_name "$PWD")"
elif [ -d "$arg" ]; then
  startdir="$(cd -- "$arg" && pwd)"
  base="$(_rvc_ws_name "$startdir")"
else
  check_name "$arg"
  base="${arg//[^A-Za-z0-9._-]/_}"
fi
check_name "$base"

name="$base"
if [ "$new" = 1 ]; then
  # A stopped session still owns its name, so match against every listed name.
  taken="$(hs_sessions | cut -f1)"
  i=2
  while printf '%s\n' "$taken" | grep -qxF "$name"; do
    name="${base}-$i"; i=$((i+1))
  done
fi
launch "$name" "$startdir"
HS
chmod 0755 "$BIN"
echo "installed $BIN"
