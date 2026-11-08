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
#   hs --copy      copy a stopped hc session into herdr      (bare -> picker)
#
# hc backend. `hs -c …` — or `hsc …`, a symlink to hs — runs every verb above
# against hc (herdr-core) instead of herdr. hc has no saved sessions, so the
# backend (/usr/local/lib/remote-vs-code/hs-hc, embedded below) keeps its own
# records under ~/.local/state/hs/hc and restores Claude with `--resume <id>`.
# `hsc --copy` copies a stopped herdr session the other way.
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
HC_LIB="${HS_HC_LIB_COPY:-/usr/local/lib/remote-vs-code/hs-hc}"
install -d -m 0755 "$(dirname "$BIN")" "$(dirname "$HC_LIB")"
cat > "$BIN" <<'HS'
#!/usr/bin/env bash
# hs — herdr session manager. Sibling to `cs`, which does this for tmux.
# Source of truth: deploy/71-hs-shortcut.sh. Overwritten on every redeploy.
set -euo pipefail

WS_LIB="${HS_WS_LIB:-/usr/local/lib/remote-vs-code/ws-name.sh}"
HERDR_DIR="${HS_HERDR_DIR:-$HOME/.config/herdr}"
HC_LIB="${HS_HC_LIB:-/usr/local/lib/remote-vs-code/hs-hc}"

# Backend: herdr unless called as `hsc` or with -c first. Everything below that
# touches a multiplexer goes through the be_* functions.
HS_BACKEND=herdr
case "${0##*/}" in hsc) HS_BACKEND=hc ;; esac
if [ "${1:-}" = "-c" ]; then HS_BACKEND=hc; shift; fi
ME=hs; [ "$HS_BACKEND" = hc ] && ME=hsc

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
  hs --copy [name] [as]       copy a stopped hc session into herdr (bare -> picker)
  hs -h | --help              this help

hsc (same as `hs -c`) runs every verb on hc instead of herdr. Each session is its
own hc core: one entry in Moshi's HC picker, its workspaces in that sidebar.
  hsc [dir|name]              restore or create, resuming each tab's Claude session
  hsc <name> <dir>            add a workspace in that folder to the session
  hsc mv <src> <dest> [ws]    move a session's workspaces (or one) into another session
  hsc x [name]                stop: record each tab and end its terminal (works from inside)
  hsc r|restart [name]        stop and reopen; every Claude tab resumes (picks up a new claude)
  hsc <name> <workspace>      reopen a workspace closed in Moshi (its Claude tabs resume)
  hsc rm <name> <workspace>   delete one workspace from a session for good
  hsc --copy [name] [as] [ws] copy a stopped herdr session (or one workspace) into hc;
                              [as] may be an existing session, which it is added to
There is no `hs d`: herdr renders per-client, so a stale client costs nothing.
herdr's default session can be stopped but never deleted.
USAGE
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

hcb() { python3 "$HC_LIB" "$@"; }
if [ "$HS_BACKEND" = hc ]; then
  command -v hc >/dev/null 2>&1 || die "hc is not installed"
  [ -r "$HC_LIB" ] || die "$HC_LIB is missing — redeploy deploy/71-hs-shortcut.sh"
else
  command -v herdr >/dev/null 2>&1 || die "herdr is not installed"
fi

# --- session enumeration ---------------------------------------------------
# `herdr session list --json` knows name/running/session_dir but NOT the working
# directory, so each session's session.json is read for its identity_cwd. That
# file survives a stop, so stopped sessions still show where they live.
# Output is TSV: name \t running|stopped \t cwd ('-' when unknown) \t default|-.
hs_sessions() {
  if [ "$HS_BACKEND" = hc ]; then hcb sessions; return; fi
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
  check_name "$1"
  if [ "$HS_BACKEND" = hc ]; then
    # hc nests fine: from inside an hc terminal the backend starts the session
    # and tells you to switch from Moshi instead of attaching in place.
    cd "$2" || die "cannot cd to $2"
    exec python3 "$HC_LIB" open "$1" "$PWD" ${3:+"$3"}
  fi
  guard_nesting
  cd "$2" || die "cannot cd to $2"
  run env RVC_MUX_ACTIVE=herdr herdr --session "$1"
}

hcmd() {
  if [ -n "${HS_DRY_RUN:-}" ]; then printf 'RUN: %s\n' "$*"; return 0; fi
  "$@"
}

be_stop()   { if [ "$HS_BACKEND" = hc ]; then hcb stop "$1";   else hcmd herdr session stop "$1"; fi; }
be_delete() { if [ "$HS_BACKEND" = hc ]; then hcb delete "$1"; else hcmd herdr session delete "$1"; fi; }

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
    printf 'hs: no %s session named %s\n' "$HS_BACKEND" "$1" >&2
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

# --copy: take a STOPPED session from the other backend into this one. Stopped
# only, so one Claude session is never open in herdr and hc at the same time.
if [ "${1:-}" = "--copy" ]; then
  shift
  [ -r "$HC_LIB" ] || die "$HC_LIB is missing — redeploy deploy/71-hs-shortcut.sh"
  if [ "$HS_BACKEND" = hc ]; then other=herdr; else other=hc; fi
  src="${1:-}"; dest="${2:-}"; ws="${3:-}"
  if [ -z "$src" ]; then
    src="$(HS_BACKEND=$other pick "copy $other session into $HS_BACKEND" stopped)"
    [ -n "$src" ] || exit 0
  fi
  check_name "$src"; dest="${dest:-$src}"; check_name "$dest"
  st="$(HS_BACKEND=$other session_status "$src")"
  [ -n "$st" ] || die "no $other session named $src"
  if [ "$st" = running ]; then
    if [ "$other" = hc ]; then die "$src is running in hc; stop it first with 'hsc x $src'"
    else die "$src is running in herdr; stop it first with 'hs x $src'"; fi
  fi
  if [ "$HS_BACKEND" = hc ]; then hcb from-herdr "$src" "$dest" ${ws:+"$ws"}
  else hcb to-herdr "$src" "$dest"; fi
  exit $?
fi

# hsc mv SRC DEST [WORKSPACE]: regroup workspaces between sessions.
if [ "${1:-}" = mv ]; then
  [ "$HS_BACKEND" = hc ] || die "mv is hsc only"
  [ $# -ge 3 ] || die "usage: hsc mv <src> <dest> [workspace]"
  check_name "$2"; check_name "$3"
  hcb move "$2" "$3" ${4:+"$4"}
  exit $?
fi

case "${1:-}" in
  s|switch|select|attach|x|stop|k|kill|rm|delete|r|restart)
    act="$1"; shift
    assume_yes=0; sel=""; sub=""
    for a in "$@"; do
      case "$a" in
        -y|-f|--yes|--force) assume_yes=1 ;;
        *) if [ -z "$sel" ]; then sel="$a"; elif [ -z "$sub" ]; then sub="$a"; fi ;;
      esac
    done
    if [ -z "$sel" ]; then
      case "$act" in
        s|switch|select|attach) sel="$(pick "attach to" all)" ;;
        x|stop)                 sel="$(pick "stop" all)" ;;
        r|restart)              sel="$(pick "restart" all)" ;;
        k|kill)                 sel="$(pick "STOP AND DELETE" deletable)" ;;
        rm|delete)              sel="$(pick "delete" stopped)" ;;
      esac
      # An empty selection means the user pressed Esc. Silent success, like cs.
      [ -n "$sel" ] || exit 0
    fi
    check_name "$sel"
    st="$(require_session "$sel")"

    # hsc rm NAME WORKSPACE: drop one workspace, not the session.
    if [ -n "$sub" ]; then
      case "$act" in
        rm|delete) [ "$HS_BACKEND" = hc ] || die "deleting one workspace is hsc only; herdr closes it from its own UI"
                   hcb delete-ws "$sel" "$sub"; exit $? ;;
        *) die "unexpected argument '$sub'" ;;
      esac
    fi

    case "$act" in
      s|switch|select|attach)
        # `herdr --session` attaches a running session and revives a stopped one.
        launch "$sel" "$PWD" ;;
      r|restart)
        [ "$HS_BACKEND" = hc ] || die "restart is hsc only; for herdr use 'hs x $sel' then 'hs $sel'"
        hcb restart "$sel" ;;
      x|stop)
        if [ "$st" = stopped ]; then
          printf 'hs: %s is already stopped\n' "$sel"; exit 0
        fi
        warn_if_current "$sel"
        be_stop "$sel" ;;
      rm|delete)
        refuse_default_delete "$sel"
        if [ "$st" = running ]; then
          die "$sel is running — stop it first with '$ME x $sel', or use '$ME k $sel' to do both"
        fi
        be_delete "$sel" ;;
      k|kill)
        refuse_default_delete "$sel"
        if [ "$st" = running ]; then
          # Unlike tmux, this discards saved layout as well as live processes.
          confirm "Stop AND delete running session '$sel'? Its saved layout is discarded." \
            || { printf 'hs: left %s alone\n' "$sel"; exit 0; }
          warn_if_current "$sel"
          be_stop "$sel"
          # hc: the terminals are ending; the record is what gets deleted.
          [ "$HS_BACKEND" = hc ] && sleep 1
        fi
        be_delete "$sel" ;;
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
# hsc NAME WORKSPACE reopens one closed workspace; herdr takes no second word.
ws_arg=""
[ "$HS_BACKEND" = hc ] && ws_arg="${2:-}"
launch "$name" "$startdir" "$ws_arg"
HS
chmod 0755 "$BIN"
echo "installed $BIN"

# hsc = hs with the hc backend. A symlink, not an alias, so non-interactive
# shells (ssh __VM_NAME__ hsc web, a Moshi shortcut) get it too.
ln -sfn "$(basename "$BIN")" "$(dirname "$BIN")/hsc"
echo "linked $(dirname "$BIN")/hsc -> $(basename "$BIN")"

cat > "$HC_LIB" <<'PY'
#!/usr/bin/env python3
"""hs-hc — the hc (herdr-core) backend behind `hs -c` / `hsc`.

Called by `hs`; not meant to be run by hand. Source of truth:
deploy/71-hs-shortcut.sh, which installs it as /usr/local/lib/remote-vs-code/hs-hc.

Why this exists. herdr keeps a SESSION on disk whether or not its server runs, so
`hs x` hibernates it and a reboot loses nothing. hc has no such state: a terminal
lives only while its program runs. This file supplies the missing half. Each hsc
session is a record under $HS_HC_STATE/<name>.json:

  {"name": "web", "core": "web", "stopped": false,
   "workspaces": [{"name": "web", "cwd": "...", "space": "sp…", "closed": false,
                   "tabs": [{"name": "cli", "cwd": "...", "tab": "tb…",
                             "terminal": "t4" | null,
                             "claude": {"id": "<session uuid>", "cwd": "..."} | null}]}]}

The shape mirrors herdr's session.json (session > workspace > tab), so a session
can be copied either way without losing structure.

One session, one hc core. A session runs in its own core (HC_SESSION=<name>), so
Moshi's HC picker lists each session and its sidebar shows only that session's
workspaces; each workspace is a herdr-app SPACE in that core's `herdr-app`
document. Because everything in the core belongs to the session, workspaces and
tabs made in Moshi are adopted into the record too, and tabs or workspaces renamed
there keep their new names. Records written before this (no "core", or "default")
still run in hc's default core, side by side with nothing else of theirs adopted.

A workspace closed from Moshi ("Close workspace") disappears from the document and
its terminals end. hc keeps the document on disk across reboots, so a workspace in
a running record but missing from the document was closed on purpose: it is
marked "closed", stays closed through stops and reboots, keeps its Claude IDs, and
comes back with `hsc NAME WORKSPACE`. A tab closed in Moshi is dropped, as herdr does.

Claude session IDs are kept current by `hs-hc hook start|end`, wired as Claude
Code SessionStart/SessionEnd hooks. The record is correct at every moment, so a
reboot (which never runs `hsc x`) restores the same conversations with
`claude --resume <id>`.

`hc server status` STARTS a core that is down, so whether a core runs is read from
its socket, never by asking hc.

Subcommands (all output is for hs, not people, except errors):
  sessions                       TSV: name, running|stopped, cwd, '-'
  open NAME DIR [WORKSPACE|DIR]  restore or create (reopen or add a workspace), attach
  stop NAME                      record, drop the spaces, end the terminals and core
  delete NAME                    forget a stopped session
  delete-ws NAME WORKSPACE       forget one closed (or stopped) workspace
  move SRC DEST [WORKSPACE]      move SRC's workspaces (or one) into DEST, running or not
  status NAME                    running | stopped | (nothing: unknown)
  hook start|end                 Claude Code hook; JSON on stdin
  restore-all                    boot: reopen every session that was not stopped
  restart NAME                   stop, then reopen without attaching
  from-herdr SRC DEST [WS]       herdr session (or one workspace) -> new or existing hsc session
  to-herdr SRC DEST              stopped hsc record -> herdr session.json
"""
from __future__ import annotations

import fcntl
import json
import os
import pwd
import secrets
import shlex
import socket
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

HOME = Path.home()
STATE = Path(os.environ.get("HS_HC_STATE") or HOME / ".local/state/hs/hc")
HERDR_DIR = Path(os.environ.get("HS_HERDR_DIR") or HOME / ".config/herdr")
HC = os.environ.get("HS_HC_BIN") or "hc"
DRY = bool(os.environ.get("HS_DRY_RUN"))
DOC = "herdr-app"  # the document herdr-app and Moshi read spaces from
# The shell Claude drops back to when it exits, so a tab stays a usable terminal.
# systemd units may run without $SHELL, so fall back to the login shell.
SHELL = os.environ.get("SHELL") or pwd.getpwuid(os.getuid()).pw_shell or "/bin/bash"
# Inherited by every terminal started here. The .bashrc auto-attach block skips
# when this is set, and hs refuses herdr launches from inside a mux with it.
TERM_ENV = {"RVC_MUX_ACTIVE": "hc"}
# Tests put their cores under a prefix so they never touch real sessions.
PREFIX = os.environ.get("HS_HC_CORE_PREFIX", "")
# The core legacy ("default") records use: whatever HC_SESSION we were given.
BASE_CORE = os.environ.get("HC_SESSION")
RUN_DIR = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}") / "herdr-core"


def die(msg: str, code: int = 1) -> None:
    print(f"hs: {msg}", file=sys.stderr)
    sys.exit(code)


def new_id(prefix: str) -> str:
    return prefix + secrets.token_hex(16)


# --- cores ----------------------------------------------------------------
def core_of(rec: dict) -> str:
    return rec.get("core") or "default"


def dedicated(rec: dict) -> bool:
    return core_of(rec) != "default"


def hc_session_name(core: str) -> str | None:
    """The HC_SESSION value for a core; None is hc's default core."""
    return BASE_CORE if core == "default" else PREFIX + core


def use_core(rec: dict) -> None:
    """Point every hc call that follows at this record's core."""
    hs = hc_session_name(core_of(rec))
    if hs:
        os.environ["HC_SESSION"] = hs
    else:
        os.environ.pop("HC_SESSION", None)


def my_terminal(rec: dict) -> str | None:
    """The caller's hc terminal, if it is in this record's core. Addresses repeat
    across cores (t1c can exist in several), so the socket must match too."""
    me = os.environ.get("HC_TERMINAL_ID")
    if not me:
        return None
    sock = Path(os.environ.get("HC_TERMINAL_SOCKET") or "").name.removesuffix(".sock")
    want = hc_session_name(core_of(rec)) or "default"
    return me if sock == want else None


def core_up() -> bool:
    """Whether the current core runs, read from its socket (asking hc starts it)."""
    sock = RUN_DIR / f"{os.environ.get('HC_SESSION') or 'default'}.sock"
    if not sock.exists():
        return False
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(1)
    try:
        s.connect(str(sock))
        return True
    except OSError:
        return False
    finally:
        s.close()


def core_env() -> dict:
    """The environment a new core starts with. Every terminal in the core inherits
    it, so nothing of the caller's own session may leak in: hsc run from inside
    Claude would otherwise hand every restored Claude CLAUDE_CODE_CHILD_SESSION
    (which turns transcript saving off) and the caller's session and bridge IDs,
    and run from inside hc, the caller's terminal identity."""
    drop = {"HC_TERMINAL_ID", "HC_TERMINAL_SOCKET", "HC_SCOPE", "HS_HC_KILL_AFTER"}
    return {k: v for k, v in os.environ.items()
            if k not in drop and not k.startswith(("CLAUDE", "VSCODE_", "TERM_PROGRAM"))}


def ensure_core() -> bool:
    """Start the current core if it is down, and wait until it answers. Returns
    whether it was started here."""
    if DRY or core_up():
        return False
    subprocess.run([HC, "server", "start", "--json"], capture_output=True, text=True,
                   env=core_env())
    for _ in range(50):
        if core_up():
            # Kept terminals (tabs made in Moshi) come back a moment after the
            # core answers; let them, or they would be taken for gone.
            time.sleep(1.5)
            return True
        time.sleep(0.2)
    die("the hc core did not start; see `hc server status`")


def stop_core() -> None:
    if not DRY and core_up():
        subprocess.run([HC, "server", "stop"], capture_output=True, text=True)


# --- hc API ---------------------------------------------------------------
class HcError(Exception):
    pass


def rpc(calls: list[tuple[str, dict]]) -> list:
    """Run JSON-RPC calls over one `hc connect`, in order. Returns each result."""
    lines = [{"jsonrpc": "2.0", "id": 0, "method": "hello", "params": {}}]
    lines += [{"jsonrpc": "2.0", "id": i + 1, "method": m, "params": p}
              for i, (m, p) in enumerate(calls)]
    payload = "".join(json.dumps(x) + "\n" for x in lines)
    try:
        out = subprocess.run([HC, "connect"], input=payload, capture_output=True,
                             text=True, timeout=30)
    except FileNotFoundError:
        die("hc is not installed")
    except subprocess.TimeoutExpired:
        raise HcError("hc connect timed out")
    replies = {}
    for line in out.stdout.splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        replies[r.get("id")] = r
    results = []
    for i, (m, _) in enumerate(calls):
        r = replies.get(i + 1)
        if r is None:
            raise HcError(f"{m}: no reply ({out.stderr.strip() or 'connection closed'})")
        if "error" in r:
            e = r["error"]
            raise HcError(f"{m}: {e.get('message')} {json.dumps(e.get('data') or {})}")
        results.append(r["result"])
    return results


def live_terminals(rec: dict) -> list[dict]:
    """Live terminals of a session. In its own core that is every live terminal
    (Moshi-made tabs included); in the default core, the ones labelled for it."""
    use_core(rec)
    if not core_up():
        return []
    labels = {} if dedicated(rec) else {"hs.session": rec["name"]}
    try:
        res = rpc([("terminal.list", {"labels": labels})])[0]
    except HcError:
        return []
    return [t for t in res.get("terminals", []) if t.get("state") == "live"]


def doc_spaces() -> list[dict] | None:
    """Spaces in the current core's herdr-app document, or None if unreadable."""
    if DRY or not core_up():
        return None
    try:
        got = rpc([("doc.get", {"name": DOC})])[0]
    except HcError:
        return None
    return (got.get("value") or {}).get("spaces", [])


def doc_update(fn) -> None:
    """Read-modify-write the herdr-app document, retrying on version conflicts."""
    if DRY:
        return
    for _ in range(8):
        got = rpc([("doc.get", {"name": DOC})])[0]
        value = got.get("value") or {}
        value.setdefault("spaces", [])
        fn(value)
        try:
            rpc([("doc.set", {"name": DOC, "value": value, "version": got.get("version", 0)})])
            return
        except HcError as e:
            if "conflict" not in str(e):
                raise
    raise HcError("doc.set kept conflicting; another client is writing spaces")


def first_terminal(node) -> str | None:
    """The first terminal in a tab's pane tree."""
    if not isinstance(node, dict):
        return None
    term = (node.get("content") or {}).get("terminal")
    if term:
        return term
    for child in node.get("children") or []:
        found = first_terminal(child)
        if found:
            return found
    return None


# --- records --------------------------------------------------------------
def rec_path(name: str) -> Path:
    return STATE / f"{name}.json"


@contextmanager
def locked():
    """One lock for every record: the hook and hs may write at the same moment."""
    STATE.mkdir(parents=True, exist_ok=True)
    with open(STATE / ".lock", "w") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        yield


def load(name: str) -> dict | None:
    try:
        return json.loads(rec_path(name).read_text())
    except FileNotFoundError:
        return None
    except ValueError:
        die(f"{rec_path(name)} is not valid JSON; fix or remove it")


def save(rec: dict) -> None:
    if DRY:
        return
    STATE.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=STATE, prefix=".tmp-")
    with os.fdopen(fd, "w") as fh:
        json.dump(rec, fh, indent=1)
        fh.write("\n")
    os.replace(tmp, rec_path(rec["name"]))


def all_records() -> list[dict]:
    if not STATE.is_dir():
        return []
    out = []
    for f in sorted(STATE.glob("*.json"), key=lambda p: p.stem.lower()):
        try:
            out.append(json.loads(f.read_text()))
        except ValueError:
            continue
    return out


def tabs(rec: dict):
    for ws in rec["workspaces"]:
        for tab in ws["tabs"]:
            yield ws, tab


def space_name(rec: dict, ws: dict) -> str:
    if dedicated(rec):
        return ws["name"]  # the picker already names the session
    if len(rec["workspaces"]) == 1 or ws["name"].lower() == rec["name"].lower():
        return rec["name"]
    return f"{rec['name']} · {ws['name']}"


def running_spaces(rec: dict, live: list[dict]) -> set:
    addrs = {t["address"] for t in live}
    out = {(t.get("labels") or {}).get("herdr.space") for t in live}
    for ws in rec["workspaces"]:
        if any(t.get("terminal") in addrs for t in ws["tabs"]):
            out.add(ws.get("space"))
    return out


def sync(rec: dict, live: list[dict]) -> None:
    """Bring the record in line with what is really there.

    Drops terminal addresses that are no longer live (after a reboot hc hands
    out the same addresses again). For a session that was not stopped, marks
    workspaces closed in Moshi; in the session's own core it also adopts spaces
    and tabs made in Moshi, follows renames, and drops tabs closed there. Nothing
    is inferred when none of the open spaces is in the document: a missing or
    reset document says nothing about what the person closed."""
    by_addr = {t["address"]: t for t in live}
    for _, tab in tabs(rec):
        if tab.get("terminal") not in by_addr:
            tab["terminal"] = None
    if rec.get("stopped"):
        return
    use_core(rec)
    doc = doc_spaces()
    if doc is None:
        return
    ids = {s.get("id") for s in doc}
    open_ws = [ws for ws in rec["workspaces"] if not ws.get("closed") and ws.get("space")]
    if open_ws and not any(ws["space"] in ids for ws in open_ws):
        return
    running = running_spaces(rec, live)
    for ws in open_ws:
        if ws["space"] not in ids and ws["space"] not in running:
            ws["closed"] = True
            for t in ws["tabs"]:
                t["terminal"] = None
    if not dedicated(rec):
        return
    known = {ws.get("space"): ws for ws in rec["workspaces"]}
    for sp in doc:
        doc_tabs = [(t.get("id"), t.get("name"), first_terminal(t.get("root")))
                    for t in sp.get("tabs") or []]
        ws = known.get(sp.get("id"))
        if ws is None:
            if not doc_tabs:
                continue
            first = by_addr.get(doc_tabs[0][2]) or {}
            cwd = sp.get("folder") or first.get("cwd") or str(HOME)
            ws = {"name": sp.get("name") or Path(cwd).name or "workspace", "cwd": cwd,
                  "space": sp.get("id"), "tabs": []}
            rec["workspaces"].append(ws)
            known[ws["space"]] = ws
        elif sp.get("name"):
            ws["name"] = sp["name"]
        by_tab = {t.get("tab"): t for t in ws["tabs"]}
        kept = []
        for i, (tid, tname, term) in enumerate(doc_tabs, 1):
            tab = by_tab.get(tid)
            if tab is None:
                cwd = (by_addr.get(term) or {}).get("cwd") or ws["cwd"]
                tab = {"name": tname or f"tab {i}", "cwd": cwd, "tab": tid, "claude": None}
            if tname:
                tab["name"] = tname
            if term in by_addr:
                tab["terminal"] = term
            kept.append(tab)
        ws["tabs"] = kept


def find_ws(rec: dict, wsname: str) -> dict | None:
    for ws in rec["workspaces"]:
        if ws["name"].lower() == wsname.lower():
            return ws
    return None


def ws_names(rec: dict) -> str:
    return ", ".join(ws["name"] + (" (closed)" if ws.get("closed") else "")
                     for ws in rec["workspaces"])


# --- verbs ----------------------------------------------------------------
def cmd_sessions() -> None:
    for rec in all_records():
        status = "running" if live_terminals(rec) else "stopped"
        cwd = rec["workspaces"][0]["cwd"] if rec.get("workspaces") else "-"
        print("\t".join((rec["name"], status, cwd, "-")))


def cmd_status(name: str) -> None:
    rec = load(name)
    if rec is None:
        return
    print("running" if live_terminals(rec) else "stopped")


def tab_argv(tab: dict) -> list[str] | None:
    """What a restored tab runs: Claude resumed by ID, then a shell; else a shell."""
    c = tab.get("claude")
    if not c or not c.get("id"):
        return None  # hc starts the machine's own shell
    line = f"claude --resume {shlex.quote(c['id'])}; exec {shlex.quote(SHELL)} -l"
    return [SHELL, "-lc", line]


def existing_dir(path: str, label: str) -> str:
    """hc refuses to spawn in a missing folder, which would strand the tabs already
    started. A folder that moved or was deleted falls back to its nearest parent."""
    p = Path(path)
    if p.is_dir():
        return str(p)
    q = p
    while not q.is_dir() and q != q.parent:
        q = q.parent
    print(f"hs: tab {label}: {path} is gone; starting in {q}", file=sys.stderr)
    return str(q)


def start_tabs(rec: dict, which: list[dict]) -> None:
    """Start a terminal for every tab of the given workspaces, then publish
    their spaces for Moshi."""
    use_core(rec)
    calls = []
    order = []
    for wi, ws in enumerate(rec["workspaces"]):
        if not any(ws is w for w in which):
            continue
        ws.setdefault("space", new_id("sp"))
        for ti, tab in enumerate(ws["tabs"]):
            tab.setdefault("tab", new_id("tb"))
            if tab.get("terminal"):
                continue  # already running
            c = tab.get("claude") or {}
            params = {
                "cwd": existing_dir(c.get("cwd") or tab["cwd"], tab["name"]),
                "labels": {"hs.session": rec["name"], "hs.tab": f"{wi}.{ti}",
                           "herdr.space": ws["space"], "herdr.tab": tab["tab"]},
                "env": TERM_ENV, "no_parent": True, "no_notify": True,
            }
            argv = tab_argv(tab)
            if argv:
                params["argv"] = argv
            calls.append(("terminal.run", params))
            order.append(tab)
    if DRY:
        for _, p in calls:
            print("RUN:", p["cwd"], " ".join(p.get("argv") or ["<shell>"]))
        return
    if calls:
        for tab, res in zip(order, rpc(calls)):
            tab["terminal"] = res["address"]
    if which:
        publish_spaces(rec, which)


def publish_spaces(rec: dict, which: list[dict]) -> None:
    spaces = []
    for ws in which:
        spaces.append({
            "id": ws["space"], "name": space_name(rec, ws), "folder": ws["cwd"],
            "tabs": [{"id": t["tab"], "name": t["name"],
                      "root": {"id": t["tab"], "type": "row", "children": [
                          {"id": new_id("p"), "type": "block",
                           "content": {"terminal": t["terminal"]}}]}}
                     for t in ws["tabs"] if t.get("terminal")],
        })
    ids = {s["id"] for s in spaces}

    def upsert(doc):
        doc["spaces"] = [s for s in doc["spaces"] if s.get("id") not in ids] + spaces
    doc_update(upsert)


def unpublish_spaces(rec: dict, which: list[dict] | None = None) -> None:
    use_core(rec)
    if not DRY and not core_up():
        return
    ids = {ws.get("space") for ws in (rec["workspaces"] if which is None else which)}

    def drop(doc):
        doc["spaces"] = [s for s in doc["spaces"] if s.get("id") not in ids]
    doc_update(drop)


def attach(rec: dict, address: str) -> None:
    if os.environ.get("HC_TERMINAL_ID"):
        # Attaching from inside an hc terminal nests one screen in another.
        print(f"hs: started; you are inside hc, so open {rec['name']} from Moshi's HC "
              f"picker", file=sys.stderr)
        return
    if DRY or os.environ.get("HS_HC_NO_ATTACH"):  # tests: no tty to attach with
        print(f"EXEC: {HC} attach {address}")
        return
    use_core(rec)
    os.execvp(HC, [HC, "attach", address])


def cmd_open(name: str, cwd: str, wsname: str | None = None) -> None:
    rec, target, closed = open_session(name, cwd, wsname)
    if closed:
        print(f"hs: closed in {name}: {', '.join(closed)}; reopen one with "
              f"'hsc {name} <workspace>'", file=sys.stderr)
    attach(rec, target or "t?")


def new_workspace(path: str) -> dict:
    p = str(Path(path).resolve())
    name = Path(p).name or "home"
    return {"name": name, "cwd": p, "tabs": [{"name": name, "cwd": p}]}


def open_session(name: str, cwd: str, wsname: str | None = None):
    """Restore or create a session without attaching; with wsname, reopen that
    workspace, or add one if wsname is a folder. Returns the record, the terminal
    to attach to, and the names of its closed workspaces."""
    with locked():
        rec = load(name)
        if rec is None:
            if name == "default":
                die("'default' is hc's own core; pick another session name")
            first = wsname if wsname and Path(cwd, wsname).is_dir() else cwd
            rec = {"name": name, "core": name, "stopped": False,
                   "workspaces": [new_workspace(str(Path(cwd, first)))]}
            wsname = None
        use_core(rec)
        started = ensure_core()
        live = live_terminals(rec)
        # Right after this core started, anything already live is a kept tab
        # that hc brought back on its own (with a shell where Claude was).
        global KEPT
        KEPT = {t["address"] for t in live} if started else set()
        sync(rec, live)
        rec["stopped"] = False
        running = running_spaces(rec, live)
        def missing(ws):  # sync cleared every terminal that is not live
            return any(not t.get("terminal") for t in ws["tabs"])
        if wsname:
            focus = find_ws(rec, wsname)
            if focus is None:
                folder = Path(cwd, wsname)
                if not folder.is_dir():
                    die(f"{name} has no workspace named {wsname}, and it is not a folder; "
                        f"it has: {ws_names(rec)}")
                focus = new_workspace(str(folder))
                rec["workspaces"].append(focus)
            focus["closed"] = False
            todo = [focus] if missing(focus) else []
        else:
            # Open workspaces with a tab not running: after a reboot, all of them,
            # less the tabs hc kept alive itself.
            todo = [ws for ws in rec["workspaces"] if not ws.get("closed") and missing(ws)]
            if not todo and not live:
                # Every workspace was closed: bring the whole session back.
                for ws in rec["workspaces"]:
                    ws["closed"] = False
                todo = list(rec["workspaces"])
            focus = next((ws for ws in rec["workspaces"] if not ws.get("closed")), None)
        start_tabs(rec, todo)
        save(rec)
        target = None
        if focus is not None:
            target = next((t["terminal"] for t in focus["tabs"] if t.get("terminal")), None)
        if target is None and live:
            target = live[0]["address"]
        closed = [ws["name"] for ws in rec["workspaces"] if ws.get("closed")]
    return rec, target, closed


def kill_and_wait(rec: dict, addrs: list[str]) -> None:
    """End terminals and wait until hc no longer lists them as live."""
    if not addrs or DRY:
        return
    use_core(rec)
    rpc([("terminal.kill", {"terminal": a}) for a in addrs])
    for _ in range(50):
        if not {t["address"] for t in live_terminals(rec)} & set(addrs):
            break
        time.sleep(0.2)
    try:
        rpc([("terminal.rm", {"terminal": a}) for a in addrs])
    except HcError:
        pass


def outlive_terminal(argv: list[str], log: str, env: dict) -> None:
    """Run argv so it survives the caller's hc terminal being killed. hc ends a
    terminal by killing its whole process scope, setsid or not, so the job runs
    as its own transient systemd unit; setsid is the fallback without systemd."""
    keep = ("PATH", "HOME", "SHELL", "LANG", "HC_SESSION", "XDG_RUNTIME_DIR")
    pass_env = {k: v for k, v in env.items() if k in keep or k.startswith("HS_")}
    line = "exec " + " ".join(shlex.quote(a) for a in argv) + f" >>{shlex.quote(log)} 2>&1"
    sysrun = ["systemd-run", "--user", "--collect", "--quiet"]
    sysrun += [f"--setenv={k}={v}" for k, v in pass_env.items()]
    try:
        r = subprocess.run(sysrun + ["--", "/bin/sh", "-c", line],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            return
    except (OSError, subprocess.SubprocessError):
        pass
    subprocess.Popen(["setsid", "-f", "/bin/sh", "-c", line], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, env=env)


def end_terminals(rec: dict, addresses: list[str]) -> None:
    """Kill then remove, then stop a session's own core. The caller's own terminal
    goes last, from a detached process: killing it kills this process too."""
    me = my_terminal(rec)
    others = [a for a in addresses if a != me]
    if DRY:
        for a in addresses:
            print(f"END: {a}")
        return
    kill_and_wait(rec, others)
    q = shlex.quote
    if me in addresses:
        script = f"sleep 0.3; {q(HC)} kill {q(me)} >/dev/null 2>&1; sleep 1; "
        script += f"{q(HC)} rm {q(me)} >/dev/null 2>&1"
        if dedicated(rec):
            script += f"; {q(HC)} server stop >/dev/null 2>&1"
        outlive_terminal(["/bin/sh", "-c", script], "/dev/null", dict(os.environ))
    elif dedicated(rec):
        stop_core()  # nothing of the session is left; Moshi stops listing it


def cmd_stop(name: str) -> None:
    with locked():
        rec = load(name)
        if rec is None:
            die(f"no hsc session named {name}")
        live = live_terminals(rec)
        if not live:
            print(f"hs: {name} is already stopped")
            return
        # Capture what changed in Moshi before the spaces are unpublished.
        sync(rec, live)
        rec["stopped"] = True
        save(rec)
        unpublish_spaces(rec)
    if my_terminal(rec) in {t["address"] for t in live}:
        print(f"hs: stopping {name}, including this terminal", file=sys.stderr)
    end_terminals(rec, [t["address"] for t in live])


def run_detached(sub: str, args: list[str], log: Path, me: str) -> None:
    """Hand a job that ends the caller's own terminal to a process that outlives it."""
    env = dict(os.environ)
    env.pop("HC_TERMINAL_ID", None)
    env["HS_HC_KILL_AFTER"] = me
    log.write_text("")
    outlive_terminal([sys.executable, os.path.abspath(__file__), sub, *args], str(log), env)


def inside(rec: dict) -> str | None:
    me = my_terminal(rec)
    if me and not DRY and me in {t["address"] for t in live_terminals(rec)}:
        return me
    return None


def take_down(rec: dict) -> bool:
    """Unpublish and end a session's terminals (plus the caller's, when a detached
    job was handed one). Returns whether anything was running."""
    with locked():
        live = live_terminals(rec)
        sync(rec, live)  # a workspace closed in Moshi stays closed
        save(rec)
    addrs = [t["address"] for t in live]
    extra = os.environ.get("HS_HC_KILL_AFTER")
    if extra and extra not in addrs:
        addrs.append(extra)
    if live:
        unpublish_spaces(rec)
    kill_and_wait(rec, addrs)
    return bool(live)


def cmd_restart(name: str) -> None:
    """Stop then reopen, so every Claude tab starts again on the current claude."""
    rec = load(name)
    if rec is None:
        die(f"no hsc session named {name}")
    me = inside(rec)
    if me:
        log = STATE / f"{name}.restart.log"
        run_detached("restart-detached", [name], log, me)
        print(f"hs: restarting {name}, including this terminal; it reappears in Moshi "
              f"in a few seconds (log: {log})", file=sys.stderr)
        return
    restart(name)


def restart(name: str) -> None:
    rec = load(name)
    take_down(rec)
    _, _, closed = open_session(name, rec["workspaces"][0]["cwd"])
    note = f" (closed: {', '.join(closed)})" if closed else ""
    print(f"hs: restarted {name}{note}")


def cmd_move(src: str, dest: str, wsname: str | None = None) -> None:
    """Move SRC's workspaces (or just WORKSPACE) into DEST; SRC is deleted once
    empty. Either may be running: the moved workspaces' terminals end and they
    reopen in DEST's core, with their Claude tabs resumed."""
    if src == dest:
        die("source and destination are the same session")
    if dest == "default":
        die("'default' is hc's own core; pick another session name")
    rec = load(src)
    if rec is None:
        die(f"no hsc session named {src}")
    if wsname and find_ws(rec, wsname) is None:
        die(f"{src} has no workspace named {wsname}; it has: {ws_names(rec)}")
    me = my_terminal(rec)
    if me and not DRY:
        live = live_terminals(rec)
        sync(rec, live)
        # A whole-session move ends every terminal in it, the caller's included.
        whole = not wsname or len(rec["workspaces"]) == 1
        doomed = ({t["address"] for t in live} if whole else
                  {t.get("terminal") for t in find_ws(rec, wsname)["tabs"]})
        if me in doomed:
            log = STATE / f"{src}.move.log"
            run_detached("move-detached", [src, dest] + ([wsname] if wsname else []), log, me)
            print(f"hs: moving into {dest}, including this terminal; it reappears in "
                  f"Moshi under {dest} in a few seconds (log: {log})", file=sys.stderr)
            return
    move(src, dest, wsname)


def move(src: str, dest: str, wsname: str | None = None) -> None:
    rec = load(src)
    whole = not wsname or len(rec["workspaces"]) == 1
    if whole:
        was_running = take_down(rec)
        if dedicated(rec):
            use_core(rec)
            stop_core()
    else:
        with locked():
            rec = load(src)
            live = live_terminals(rec)
            sync(rec, live)
            save(rec)
        ws = find_ws(rec, wsname)
        live_addrs = {t["address"] for t in live}
        addrs = [t["terminal"] for t in ws["tabs"] if t.get("terminal") in live_addrs]
        extra = os.environ.get("HS_HC_KILL_AFTER")
        if extra and extra not in addrs:
            addrs.append(extra)
        was_running = bool(live_addrs & set(addrs))
        if was_running:
            unpublish_spaces(rec, [ws])
        kill_and_wait(rec, addrs)
    with locked():
        rec = load(src)
        moving = rec["workspaces"] if whole else [find_ws(rec, wsname)]
        target = load(dest)
        dest_running = bool(target and live_terminals(target))
        if target is None:
            target = {"name": dest, "core": dest, "stopped": True, "workspaces": []}
        add_workspaces(target, moving, src)
        save(target)
        rec["workspaces"] = [w for w in rec["workspaces"] if not any(w is m for m in moving)]
        if DRY:
            pass
        elif rec["workspaces"]:
            save(rec)
        else:
            rec_path(src).unlink()
    n = len(moving)
    what = moving[0]["name"] if wsname else f"{n} workspace{'s' if n != 1 else ''}"
    print(f"hs: moved {what} from {src} into {dest}")
    if was_running or dest_running:
        _, _, closed = open_session(dest, target["workspaces"][0]["cwd"])
        print(f"hs: {dest} is running" + (f" (closed: {', '.join(closed)})" if closed else ""))


def add_workspaces(target: dict, moving: list[dict], src: str) -> None:
    """Append workspaces to a record. They get new ids in the new core: an id the
    destination's document has never seen would read as "closed in Moshi"."""
    taken = {ws["name"].lower() for ws in target["workspaces"]}
    for ws in moving:
        ws.pop("space", None)
        for t in ws["tabs"]:
            t["terminal"] = None
            t.pop("tab", None)
        if ws["name"].lower() in taken:
            ws["name"] = f"{src} · {ws['name']}"
        taken.add(ws["name"].lower())
        target["workspaces"].append(ws)


def cmd_delete(name: str) -> None:
    with locked():
        rec = load(name)
        if rec is None:
            die(f"no hsc session named {name}")
        if live_terminals(rec):
            die(f"{name} is running; stop it first with 'hsc x {name}'")
        if DRY:
            print(f"DELETE: {name}")
            return
        rec_path(name).unlink()


def cmd_delete_ws(name: str, wsname: str) -> None:
    with locked():
        rec = load(name)
        if rec is None:
            die(f"no hsc session named {name}")
        live = live_terminals(rec)
        sync(rec, live)
        ws = find_ws(rec, wsname)
        if ws is None:
            die(f"{name} has no workspace named {wsname}; it has: {ws_names(rec)}")
        if len(rec["workspaces"]) == 1:
            die(f"{ws['name']} is the only workspace in {name}; use 'hsc rm {name}' instead")
        if ws.get("space") in running_spaces(rec, live):
            die(f"{ws['name']} is open; close it in Moshi or stop {name} with 'hsc x {name}' first")
        if DRY:
            print(f"DELETE: {name} / {ws['name']}")
            return
        rec["workspaces"] = [w for w in rec["workspaces"] if w is not ws]
        save(rec)
    print(f"hs: deleted workspace {ws['name']} from {name}")


KEPT: set = set()  # set by open_session: terminals hc revived when the core started


def resume_in_shells(rec: dict) -> int:
    """Tabs made in Moshi are "kept": after a reboot hc brings them back on
    their own, with a plain shell where Claude was. hsc sees them running and
    starts nothing, so type the resume into each such shell. Only at boot, when
    nobody has touched them yet."""
    n = 0
    for _, tab in tabs(rec):
        c, addr = tab.get("claude") or {}, tab.get("terminal")
        if not c.get("id") or addr not in KEPT:
            continue
        line = f"cd {shlex.quote(c.get('cwd') or tab['cwd'])} && claude --resume {shlex.quote(c['id'])}"
        if not DRY:
            # Until its new shell is up, hc answers "lost, waiting for its new
            # shell" and drops what is sent, so retry for up to 30 s.
            for _ in range(60):
                r = subprocess.run([HC, "send", addr, line], capture_output=True, text=True)
                if r.returncode == 0 and "unavailable" not in r.stdout + r.stderr:
                    break
                time.sleep(0.5)
        n += 1
    return n


def cmd_restore_all() -> None:
    """Run at boot by hs-hc-restore.service. Reopens every session that was
    running when the machine went down; sessions stopped with `hsc x` and
    workspaces closed in Moshi stay as they were. Safe to run again: a session
    that already has terminals is left alone."""
    recs = [r for r in all_records() if not r.get("stopped")]
    if not recs:
        print("hs: no running hsc sessions to restore")
        return
    failed = 0
    for rec in recs:
        name = rec["name"]
        if live_terminals(rec):
            print(f"hs: {name} is already running")
            continue
        try:
            _, _, closed = open_session(name, rec["workspaces"][0]["cwd"])
        except (HcError, KeyError, IndexError) as e:
            print(f"hs: could not restore {name}: {e}", file=sys.stderr)
            failed += 1
            continue
        resumed = resume_in_shells(load(name))
        note = f" (closed: {', '.join(closed)})" if closed else ""
        note += f" ({resumed} kept tab{'s' if resumed != 1 else ''} resumed)" if resumed else ""
        print(f"hs: restored {name}{note}")
    if failed:
        sys.exit(1)


# --- Claude Code hook ------------------------------------------------------
def cmd_hook(kind: str) -> None:
    """Keep each tab's Claude session ID current. Silent and fast outside hc."""
    term = os.environ.get("HC_TERMINAL_ID")
    if not term:
        return
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    # The terminal's socket names its core: <runtime>/herdr-core/<core>.sock.
    core = Path(os.environ.get("HC_TERMINAL_SOCKET") or "").name.removesuffix(".sock")
    if core:
        if core == "default":
            os.environ.pop("HC_SESSION", None)
        else:
            os.environ["HC_SESSION"] = core
    try:
        info = json.loads(subprocess.run([HC, "get", term, "--json"], capture_output=True,
                                         text=True, timeout=5).stdout)
    except (ValueError, subprocess.SubprocessError, OSError):
        return
    labels = info.get("labels") or {}
    name = labels.get("hs.session")
    if not name and core and core != "default" and core.startswith(PREFIX):
        name = core[len(PREFIX):]  # a Moshi-made tab in a session's own core
    if not name:
        return
    with locked():
        rec = load(name)
        if rec is None or (labels.get("hs.session") is None and not dedicated(rec)):
            return

        def find():
            tid = labels.get("herdr.tab")
            for _, t in tabs(rec):
                if (tid and t.get("tab") == tid) or t.get("terminal") == term:
                    return t
            return None
        tab = find()
        if tab is None and dedicated(rec):
            sync(rec, live_terminals(rec))  # adopt the tab Moshi just made
            tab = find()
        if tab is None:
            return
        if kind == "start" and data.get("session_id"):
            tab["claude"] = {"id": data["session_id"], "cwd": data.get("cwd") or tab["cwd"]}
        elif kind == "end" and data.get("reason") in ("prompt_input_exit", "logout"):
            # A deliberate /exit: the tab should come back as a shell. A kill from
            # `hsc x` or a reboot ends with another reason and keeps the ID.
            tab["claude"] = None
        else:
            return
        save(rec)


# --- copying between herdr and hsc ----------------------------------------
def herdr_session_file(name: str) -> Path:
    return HERDR_DIR / "sessions" / name / "session.json"


def cmd_from_herdr(src: str, dest: str, wsname: str | None = None) -> None:
    """Copy a stopped herdr session, or one of its workspaces, into DEST. DEST may
    already exist: the workspaces are added to it, and started if it is running."""
    try:
        data = json.loads(herdr_session_file(src).read_text())
    except FileNotFoundError:
        die(f"no herdr session named {src}")
    if dest == "default":
        die("'default' is hc's own core; pick another session name")
    workspaces = []
    for w in data.get("workspaces") or []:
        wcwd = w.get("identity_cwd") or str(HOME)
        wname = w.get("custom_name") or Path(wcwd).name or src
        if wsname and wname.lower() != wsname.lower():
            continue
        wtabs = []
        for i, t in enumerate(w.get("tabs") or [], 1):
            panes = t.get("panes") or {}
            pane = panes.get(str(t.get("root_pane"))) or next(iter(panes.values()), {})
            agent = pane.get("agent_session") or {}
            claude = None
            if agent.get("agent") == "claude" and agent.get("kind") == "id":
                claude = {"id": agent["value"], "cwd": pane.get("cwd") or wcwd}
            wtabs.append({"name": t.get("custom_name") or f"tab {i}",
                          "cwd": pane.get("cwd") or wcwd, "claude": claude})
        if wtabs:
            workspaces.append({"name": wname, "cwd": wcwd, "tabs": wtabs})
    if not workspaces:
        names = ", ".join(w.get("custom_name") or Path(w.get("identity_cwd") or "").name
                          for w in data.get("workspaces") or [])
        die(f"herdr session {src} has no workspace named {wsname}; it has: {names}"
            if wsname else f"herdr session {src} has no tabs to copy")
    if DRY:
        print(json.dumps(workspaces, indent=1))
        return
    with locked():
        target = load(dest)
        existed = target is not None
        running = bool(existed and live_terminals(target))
        if target is None:
            target = {"name": dest, "core": dest, "stopped": True, "workspaces": []}
        add_workspaces(target, workspaces, src)
        save(target)
    n = sum(len(w["tabs"]) for w in workspaces)
    what = workspaces[0]["name"] if wsname else f"{len(workspaces)} workspaces, {n} tabs"
    verb = "added to" if existed else "copied to"
    print(f"hs: herdr {src} ({what}) {verb} hsc {dest}")
    if running:
        open_session(dest, target["workspaces"][0]["cwd"])
        print(f"hs: started in {dest}, which was running")
    else:
        print(f"hs: start it with 'hsc {dest}'")


def cmd_to_herdr(src: str, dest: str) -> None:
    rec = load(src)
    if rec is None:
        die(f"no hsc session named {src}")
    if live_terminals(rec):
        die(f"{src} is running in hc; stop it first with 'hsc x {src}' so the same "
            f"Claude session is never open in both")
    target = herdr_session_file(dest)
    if target.parent.exists():
        die(f"a herdr session named {dest} already exists; give another name")
    workspaces = []
    pane_no = 0
    for wi, ws in enumerate(rec["workspaces"], 1):
        wtabs, numbers = [], {}
        for t in ws["tabs"]:
            pane_no += 1
            pane = {"cwd": (t.get("claude") or {}).get("cwd") or t["cwd"]}
            if (t.get("claude") or {}).get("id"):
                pane["agent_session"] = {"source": "herdr:claude", "agent": "claude",
                                         "kind": "id", "value": t["claude"]["id"]}
            numbers[str(pane_no)] = len(numbers) + 1
            wtabs.append({"custom_name": t["name"], "layout": {"Pane": pane_no},
                          "panes": {str(pane_no): pane}, "zoomed": False,
                          "focused": pane_no, "root_pane": pane_no})
        workspaces.append({
            "id": f"w{wi}", "custom_name": None, "identity_cwd": ws["cwd"],
            "public_pane_numbers": numbers, "next_public_pane_number": len(numbers) + 1,
            "public_tab_numbers": list(range(1, len(wtabs) + 1)),
            "next_public_tab_number": len(wtabs) + 1, "tabs": wtabs, "active_tab": 0})
    data = {"version": 3, "workspaces": workspaces, "active": 0, "selected": 0,
            "sidebar_width": None, "sidebar_section_split": None,
            "collapsed_space_keys": []}
    if DRY:
        print(json.dumps(data, indent=1))
        return
    target.parent.mkdir(parents=True)
    target.write_text(json.dumps(data, indent=1) + "\n")
    print(f"hs: copied hsc {src} to herdr {dest}; start it with 'hs {dest}'")


def main(argv: list[str]) -> None:
    if not argv:
        die("hs-hc: missing subcommand (this is hs's backend; run hsc instead)")
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "sessions":
            cmd_sessions()
        elif cmd == "status" and len(args) == 1:
            cmd_status(args[0])
        elif cmd == "open" and len(args) in (2, 3):
            cmd_open(*args)
        elif cmd == "stop" and len(args) == 1:
            cmd_stop(args[0])
        elif cmd == "delete" and len(args) == 1:
            cmd_delete(args[0])
        elif cmd == "delete-ws" and len(args) == 2:
            cmd_delete_ws(*args)
        elif cmd == "move" and len(args) in (2, 3):
            cmd_move(*args)
        elif cmd == "move-detached" and len(args) in (2, 3):
            move(*args)
        elif cmd == "restart" and len(args) == 1:
            cmd_restart(args[0])
        elif cmd == "restart-detached" and len(args) == 1:
            restart(args[0])
        elif cmd == "restore-all" and not args:
            cmd_restore_all()
        elif cmd == "hook" and len(args) == 1:
            cmd_hook(args[0])
        elif cmd == "from-herdr" and len(args) in (2, 3):
            cmd_from_herdr(*args)
        elif cmd == "to-herdr" and len(args) == 2:
            cmd_to_herdr(*args)
        else:
            die(f"hs-hc: bad arguments: {' '.join(argv)}")
    except HcError as e:
        die(f"hc: {e}")


if __name__ == "__main__":
    main(sys.argv[1:])
PY
chmod 0755 "$HC_LIB"
echo "installed $HC_LIB"
