#!/usr/bin/env bash
# herdr-title.py — the Ghostty tab-title renderer and its snapshot/event view builder.
# Exercises the EXACT bytes deploy/69-herdr-title.sh installs (extracted via
# HERDR_TITLE_COPY; see tests/README.md), never the socket and never a live session.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

BIN="../deploy/build/herdr-title.py"
[ -r "$BIN" ] || { printf 'missing %s — build it first (see tests/README.md)\n' "$BIN" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/herdr-title.toml"
: > "$CFG"

# render <view-json> -> title.  Config comes from $CFG unless $CFG_OVERRIDE is set.
render() { printf '%s' "$1" | python3 "$BIN" --render-once --config "${CFG_OVERRIDE:-$CFG}" 2>"$TMP/err"; }
# build+render straight from a herdr snapshot (+ optional events)
render_snap() { printf '%s' "$1" | python3 "$BIN" --render-snapshot --config "${CFG_OVERRIDE:-$CFG}" 2>"$TMP/err"; }

# A focused view with everything populated; override fields per case.
view() { # key=value ...
  python3 -c '
import json, sys
v = {"session":"Remote-VS-Code","host":"__VM_NAME__","workspace":"Remote-VS-Code",
     "tab":"1","agent":"claude","status":"working",
     "title":"Display herdr session info","cwd":"/home/__DEV_USER__/workspace/Remote-VS-Code"}
for a in sys.argv[1:]:
    k, _, val = a.partition("=")
    v[k] = val
print(json.dumps(v))' "$@"
}

# --- the default format ------------------------------------------------------------
is "default: icon + session + agent title" \
   "$(render "$(view)")" "⚡ Remote-VS-Code · Display herdr session info"

# --- session_path collapses when the space is named after the session ---------------
is "session_path: collapses when equal" \
   "$(render "$(view)")" "⚡ Remote-VS-Code · Display herdr session info"
is "session_path: expands when the space differs" \
   "$(render "$(view workspace=sv-portal-pro)")" \
   "⚡ Remote-VS-Code/sv-portal-pro · Display herdr session info"

# --- {a|b} fallback ----------------------------------------------------------------
is "fallback: uses host when the agent title is empty" \
   "$(render "$(view title=)")" "⚡ Remote-VS-Code · __VM_NAME__"
printf 'format = "{agent|status}"\nensure_session_token = false\n' > "$CFG"
is "fallback: left side wins when set"   "$(render "$(view)")"          "claude"
is "fallback: right side used when empty" "$(render "$(view agent=)")"  "working"
: > "$CFG"

# --- status icons ------------------------------------------------------------------
printf 'format = "{icon}"\nensure_session_token = false\n' > "$CFG"
is "icon: working" "$(render "$(view status=working)")" "⚡"
is "icon: blocked" "$(render "$(view status=blocked)")" "❓"
is "icon: idle"    "$(render "$(view status=idle)")"    "○"
is "icon: done"    "$(render "$(view status=done)")"    "✓"
is "icon: unknown" "$(render "$(view status=unknown)")" "·"
is "icon: unrecognised status falls back to unknown" "$(render "$(view status=wat)")" "·"
: > "$CFG"

# --- every documented token renders -------------------------------------------------
printf 'format = "{session}|{workspace}|{tab}|{agent}|{status}|{host}"\nensure_session_token = false\n' > "$CFG"
is "tokens: all render" "$(render "$(view)")" \
   "Remote-VS-Code|Remote-VS-Code|1|claude|working|__VM_NAME__"
printf 'format = "{cwd}"\nensure_session_token = false\n' > "$CFG"
is "tokens: cwd abbreviates \$HOME to ~" \
   "$(HOME=/home/__DEV_USER__ render "$(view)")" "~/workspace/Remote-VS-Code"
printf 'format = "{nope}x"\nensure_session_token = false\n' > "$CFG"
is "tokens: unknown token renders empty, does not crash" "$(render "$(view)")" "x"
: > "$CFG"

# --- no-agent panes: the shell's own title is not an agent task ----------------------
printf 'format = "{agent_title}"\nensure_session_token = false\n' > "$CFG"
is "agent_title: is the terminal title when an agent is detected" \
   "$(render "$(view)")" "Display herdr session info"
is "agent_title: empty with no agent, so the shell prompt never leaks in" \
   "$(render "$(view agent= title=__DEV_USER__@__VM_NAME__:~/workspace)")" ""

printf 'format = "{tab_name}"\nensure_session_token = false\n' > "$CFG"
is "tab_name: a named tab is used"        "$(render "$(view tab=subscription-webhooks)")" "subscription-webhooks"
is "tab_name: herdr's auto-number is not a name" "$(render "$(view tab=1)")"  ""
is "tab_name: multi-digit auto-number too"       "$(render "$(view tab=12)")" ""
is "tab_name: a name containing digits survives" "$(render "$(view tab=rt-refresh2)")" "rt-refresh2"
: > "$CFG"

# --- the default format across all three shapes --------------------------------------
is "default: agent running -> its task" \
   "$(render "$(view)")" "⚡ Remote-VS-Code · Display herdr session info"
is "default: no agent, named tab -> the tab name" \
   "$(render "$(view agent= status=idle tab=cli title=__DEV_USER__@__VM_NAME__:~/workspace)")" \
   "○ Remote-VS-Code · cli"
is "default: no agent, unnamed tab -> the host, never the shell prompt" \
   "$(render "$(view agent= status=unknown tab=1 title=__DEV_USER__@__VM_NAME__:~/workspace)")" \
   "· Remote-VS-Code · __VM_NAME__"

# --- truncation ---------------------------------------------------------------------
printf 'format = "{title}"\nmax_length = 10\nensure_session_token = false\n' > "$CFG"
is "truncate: long title is ellipsised to max_length" \
   "$(render "$(view title=abcdefghijklmnop)")" "abcdefghi…"
is "truncate: exactly at the limit is untouched" \
   "$(render "$(view title=abcdefghij)")" "abcdefghij"
is "truncate: under the limit is untouched" \
   "$(render "$(view title=abc)")" "abc"
: > "$CFG"

# --- ensure_session_token: click-to-focus depends on the session being greppable -----
printf 'format = "{title}"\n' > "$CFG"
is "ensure: prepends the session when the format drops it" \
   "$(render "$(view)")" "Remote-VS-Code · Display herdr session info"
printf 'format = "{session} · {title}"\n' > "$CFG"
is "ensure: no double prefix when already present" \
   "$(render "$(view)")" "Remote-VS-Code · Display herdr session info"
printf 'format = "{session}/{workspace} {title}"\n' > "$CFG"
is "ensure: slash form counts as present" \
   "$(render "$(view workspace=other)")" "Remote-VS-Code/other Display herdr session info"
printf 'format = "{title}"\nensure_session_token = false\n' > "$CFG"
is "ensure: disabled means disabled" \
   "$(render "$(view)")" "Display herdr session info"
: > "$CFG"

# --- config robustness ---------------------------------------------------------------
printf 'format = "{icon} oops\n' > "$TMP/broken.toml"    # unterminated string
is "config: unparseable falls back to the default format" \
   "$(CFG_OVERRIDE="$TMP/broken.toml" render "$(view)")" \
   "⚡ Remote-VS-Code · Display herdr session info"
is "config: missing file falls back to the default format" \
   "$(CFG_OVERRIDE="$TMP/does-not-exist.toml" render "$(view)")" \
   "⚡ Remote-VS-Code · Display herdr session info"

# --- building the view from a real herdr snapshot --------------------------------------
SNAP='{"session":"Remote-VS-Code","host":"__VM_NAME__","snapshot":{
 "focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1",
 "workspaces":[{"workspace_id":"w1","label":"Remote-VS-Code","focused":true},
               {"workspace_id":"w2","label":"other","focused":false}],
 "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1","focused":true}],
 "panes":[{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","focused":false,
           "agent":"claude","agent_status":"idle","terminal_title_stripped":"NOT this one",
           "cwd":"/tmp"},
          {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,
           "agent":"claude","agent_status":"working",
           "terminal_title_stripped":"Display herdr session info",
           "cwd":"/home/__DEV_USER__/workspace/Remote-VS-Code"}]}}'
is "snapshot: renders the FOCUSED pane, not the first one" \
   "$(render_snap "$SNAP")" "⚡ Remote-VS-Code · Display herdr session info"

# A pane_updated event for the focused pane must move the title and the status.
SNAP_EV="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
d["events"] = [{"event":"pane_updated","data":{"type":"pane_updated","pane":{
    "pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":True,
    "agent":"claude","agent_status":"blocked",
    "terminal_title_stripped":"Bash command needs approval",
    "cwd":"/home/__DEV_USER__/workspace/Remote-VS-Code"}}}]
print(json.dumps(d))' "$SNAP")"
is "events: pane_updated moves title and status" \
   "$(render_snap "$SNAP_EV")" "❓ Remote-VS-Code · Bash command needs approval"

# Focus moving to another space must change what is rendered.
SNAP_WS="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
d["events"] = [{"event":"workspace_focused","data":{"type":"workspace_focused","workspace_id":"w2"}},
               {"event":"pane_updated","data":{"type":"pane_updated","pane":{
                   "pane_id":"w2:p1","workspace_id":"w2","tab_id":"w2:t1","focused":True,
                   "agent":"claude","agent_status":"working",
                   "terminal_title_stripped":"Fix JWT refresh loop","cwd":"/tmp"}}}]
print(json.dumps(d))' "$SNAP")"
is "events: focusing another space re-targets the title" \
   "$(render_snap "$SNAP_WS")" "⚡ Remote-VS-Code/other · Fix JWT refresh loop"

# No attached agent at all: the shell title is not an agent title, but must still render.
SNAP_IDLE="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for p in d["snapshot"]["panes"]:
    if p["focused"]:
        p["agent"] = None; p["agent_status"] = "unknown"; p["terminal_title_stripped"] = ""
print(json.dumps(d))' "$SNAP")"
is "snapshot: no agent falls back to the host" \
   "$(render_snap "$SNAP_IDLE")" "· Remote-VS-Code · __VM_NAME__"

# --- stderr stays clean on the happy path ----------------------------------------------
render "$(view)" >/dev/null
is "no stderr noise on a normal render" "$(cat "$TMP/err")" ""

printf '\n%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
