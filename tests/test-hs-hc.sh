#!/usr/bin/env bash
# hsc / hs -c: the hc backend, against REAL but isolated hc cores. Each session
# runs in its own core, named hst<pid>-<session> here (HS_HC_CORE_PREFIX), and
# legacy records use the base core hstest-<pid> (HC_SESSION), so the live cores
# and Moshi's spaces are untouched.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

HS="../deploy/build/hs"; LIB="../deploy/build/hs-hc"
[ -x "$HS" ] && [ -r "$LIB" ] || { printf 'missing build artifacts\n' >&2; exit 1; }
command -v hc >/dev/null || { printf 'hc not installed; skipping\n'; exit 0; }
HSABS="$PWD/$HS"; LIBABS="$PWD/$LIB"

TMP="$(mktemp -d)"
export HC_SESSION="hstest-$$" HS_HC_CORE_PREFIX="hst$$-"
PFX="$HS_HC_CORE_PREFIX"
RUN="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/herdr-core"
unset HC_TERMINAL_ID HC_SCOPE HC_TERMINAL_SOCKET
HOME_REAL="$HOME"
cleanup() {
  for s in "$RUN/$PFX"*.sock "$RUN/$HC_SESSION.sock"; do
    [ -S "$s" ] || continue
    c="$(basename "$s" .sock)"; HC_SESSION="$c" hc server stop >/dev/null 2>&1
  done
  rm -rf "$HOME_REAL/.local/state/herdr-core/$HC_SESSION" "$HOME_REAL/.local/state/herdr-core/$PFX"* "$TMP"
}
trap cleanup EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/proj"
export HS_HC_STATE="$HOME/state" HS_HC_LIB="$LIBABS" HS_HC_NO_ATTACH=1
export HS_HERDR_DIR="$HOME/.config/herdr" HS_WS_LIB="$PWD/../deploy/build/ws-name.sh"
export PATH="$TMP/bin:$PATH"
make_stub_herdr "$TMP/bin"
# Tabs run "$SHELL -lc 'claude --resume …'". A fake shell records that line and
# idles, so no real Claude ever starts.
cat > "$TMP/bin/fakesh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HS_FAKESH_LOG"; exec sleep 300
SH
chmod +x "$TMP/bin/fakesh"
export SHELL="$TMP/bin/fakesh" HS_FAKESH_LOG="$TMP/fakesh.log"

hsc() { ( cd "$HOME/proj" && CLAUDE_CODE_CHILD_SESSION=1 CLAUDECODE=1 bash "$HSABS" -c "$@" 2>&1 ); }
core_on() { [ -S "$RUN/$PFX$1.sock" ] && echo up || echo down; }
# Terminals and spaces of one session's core. Only called while the core is up:
# asking a stopped core anything starts it.
terms() { HC_SESSION="$PFX$1" hc ls --json | python3 -c 'import json,sys
for t in json.load(sys.stdin)["terminals"]: print(t["address"])'; }
spaces() { printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"hello","params":{}}' \
  '{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"herdr-app"}}' \
  | HC_SESSION="${2:-$PFX$1}" hc connect | python3 -c 'import json,sys
for l in sys.stdin:
  r=json.loads(l)
  if r.get("id")==1:
    v=(r["result"].get("value") or {}).get("spaces",[])
    print(" ".join(s["name"]+":"+",".join(x["root"]["children"][0]["content"]["terminal"] for x in s["tabs"]) for s in v))'; }
rec() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$HS_HC_STATE/$1.json" "$2"; }
hook() { # kind core terminal json
  printf '%s' "$4" | HC_TERMINAL_ID="$3" HC_TERMINAL_SOCKET="$RUN/$PFX$2.sock" python3 "$LIBABS" hook "$1"; }
# Moshi's "Close workspace": drop the space from the doc and end its terminals.
drop_space() { HC_SESSION="$PFX$1" python3 - "$2" <<'DROP'
import json, subprocess, sys
def rpc(calls):
    lines = [{"jsonrpc":"2.0","id":0,"method":"hello","params":{}}] + \
            [{"jsonrpc":"2.0","id":i+1,"method":m,"params":p} for i,(m,p) in enumerate(calls)]
    out = subprocess.run(["hc","connect"], input="".join(json.dumps(x)+"\n" for x in lines),
                         capture_output=True, text=True).stdout
    return {json.loads(l)["id"]: json.loads(l) for l in out.splitlines()}
name = sys.argv[1]
got = rpc([("doc.get", {"name":"herdr-app"})])[1]["result"]
v = got["value"]; gone = [s for s in v["spaces"] if s["name"] == name]
v["spaces"] = [s for s in v["spaces"] if s["name"] != name]
rpc([("doc.set", {"name":"herdr-app","value":v,"version":got["version"]})])
for s in gone:
    for t in s["tabs"]:
        rpc([("terminal.kill", {"terminal": t["root"]["children"][0]["content"]["terminal"]})])
DROP
sleep 0.5; }
kill_all() { for a in $(terms "$1"); do HC_SESSION="$PFX$1" hc kill "$a" >/dev/null 2>&1; done; sleep 0.5; }

is "empty ls" "$(hsc ls)" ""

# Create: its own core, one workspace, one tab, a shell (no Claude ID yet).
out="$(hsc)"
like "create attaches" "$out" "EXEC: hc attach t"
is   "record names its core" "$(rec proj 'r["core"]')" "proj"
is   "core is up" "$(core_on proj)" "up"
t1="$(rec proj 'r["workspaces"][0]["tabs"][0]["terminal"]')"
like "ls shows running" "$(hsc ls)" "running"
is   "space published, named after the workspace" "$(spaces proj)" "proj:$t1"

# A core started from inside Claude must not hand Claude's session markers to
# its terminals: CLAUDE_CODE_CHILD_SESSION turns transcript saving off.
pid="$(HC_SESSION="${PFX}proj" hc get "$t1" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])')"
is "no Claude env leaks into the core" "$(tr '\0' '\n' < /proc/$pid/environ | grep -c '^CLAUDE')" "0"

# Re-open attaches to the live terminal instead of starting another.
like "reopen attaches same" "$(hsc proj)" "attach $t1"
is   "no second terminal"   "$(terms proj | wc -l)" "1"

# The SessionStart hook records Claude's session ID against this tab.
hook start proj "$t1" "{\"session_id\":\"sid-1\",\"cwd\":\"$HOME/proj\"}"
is "hook records id" "$(rec proj 'r["workspaces"][0]["tabs"][0]["claude"]["id"]')" "sid-1"
hook end proj "$t1" '{"reason":"other"}'
is "end(other) keeps id" "$(rec proj 'r["workspaces"][0]["tabs"][0]["claude"]["id"]')" "sid-1"
printf '{"session_id":"zzz"}' | python3 "$LIBABS" hook start
is "hook outside hc is a no-op" "$(rec proj 'r["workspaces"][0]["tabs"][0]["claude"]["id"]')" "sid-1"

# Stop: record kept, terminals gone, and the core stops so Moshi drops it.
is   "x stops quietly" "$(hsc x proj)" ""
like "ls shows stopped" "$(hsc ls)" "stopped"
is   "core stopped" "$(core_on proj)" "down"
like "x again explains" "$(hsc x proj)" "already stopped"
is   "ls does not start a stopped core" "$(core_on proj)" "down"

# Restore resumes the recorded Claude session.
: > "$HS_FAKESH_LOG"
hsc proj >/dev/null; sleep 0.5
like "restore resumes claude" "$(cat "$HS_FAKESH_LOG")" "claude --resume sid-1"

# A deliberate /exit clears the ID, so the next restore is a plain shell.
t2="$(rec proj 'r["workspaces"][0]["tabs"][0]["terminal"]')"
hook end proj "$t2" '{"reason":"prompt_input_exit"}'
is "exit clears id" "$(rec proj 'r["workspaces"][0]["tabs"][0]["claude"]')" "None"

# rm refuses a running session; x from INSIDE its own terminal still finishes.
like "rm refuses running" "$(hsc rm proj)" "running"
# The same address in ANOTHER core is not this terminal: nothing detaches.
out="$( (cd "$HOME/proj" && HC_TERMINAL_ID="$t2" HC_TERMINAL_SOCKET="$RUN/${PFX}other.sock" bash "$HSABS" -c r proj) 2>&1 )"
like "same address, other core: not inside" "$out" "restarted proj"
t2="$(rec proj 'r["workspaces"][0]["tabs"][0]["terminal"]')"
out="$( (cd "$HOME/proj" && HC_TERMINAL_ID="$t2" HC_TERMINAL_SOCKET="$RUN/${PFX}proj.sock" bash "$HSABS" -c x proj) 2>&1 )"
like "x from inside warns" "$out" "including this terminal"
sleep 3
is "self-stop ended the core" "$(core_on proj)" "down"
is "rm deletes stopped" "$(hsc rm proj; hsc ls)" ""
is "record gone" "$(ls "$HS_HC_STATE"/*.json 2>/dev/null | wc -l)" "0"
like "default is not a session name" "$(hsc default)" "hc's own core"

# --- copying ---
mkdir -p "$HS_HERDR_DIR/sessions/web"
cat > "$HS_HERDR_DIR/sessions/web/session.json" <<JSON
{"version":3,"workspaces":[
 {"id":"w1","custom_name":null,"identity_cwd":"$HOME/proj","tabs":[
   {"custom_name":"EmDash","panes":{"1":{"cwd":"$HOME/proj"}},"root_pane":1},
   {"custom_name":"cli","panes":{"2":{"cwd":"$HOME/proj"}},"root_pane":2}]},
 {"id":"w2","custom_name":null,"identity_cwd":"$HOME/proj/site","tabs":[
   {"custom_name":"site","panes":{"3":{"cwd":"$HOME/proj/site","agent_session":
     {"source":"herdr:claude","agent":"claude","kind":"id","value":"sid-web"}}},"root_pane":3}]}]}
JSON
export HS_STUB_JSON="$TMP/sessions.json"
printf '{"sessions":[{"default":false,"name":"web","running":true}]}' > "$HS_STUB_JSON"
like "copy refuses running herdr" "$(hsc --copy web)" "hs x web"
printf '{"sessions":[{"default":false,"name":"web","running":false}]}' > "$HS_STUB_JSON"
like "copy herdr -> hc" "$(hsc --copy web)" "2 workspaces, 3 tabs"
is   "copied claude id" "$(rec web 'r["workspaces"][1]["tabs"][0]["claude"]["id"]')" "sid-web"
# One workspace into an existing session: added, renamed on a clash.
like "copy one workspace into existing" "$(hsc --copy web web site)" "added to hsc web"
is   "clashing name prefixed" "$(rec web 'r["workspaces"][2]["name"]')" "web · site"
like "copy unknown workspace" "$(hsc --copy web web nope)" "no workspace named nope"

out="$(hsc web)"; sleep 0.5; like "copied opens" "$out" "EXEC: hc attach"
like "missing folder falls back" "$out" "is gone; starting in"
like "copied session restores claude" "$(cat "$HS_FAKESH_LOG")" "claude --resume sid-web"
like "spaces published" "$(spaces web)" "site:"
like "hs --copy refuses running hc" "$(bash "$HSABS" --copy web web2 2>&1)" "hsc x web"
hsc x web >/dev/null
out="$(bash "$HSABS" --copy web web2 2>&1)"
like "copy hc -> herdr" "$out" "hs web2"
is "herdr file has agent" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["workspaces"][1]["tabs"][0]["panes"]["3"]["agent_session"]["value"])' "$HS_HERDR_DIR/sessions/web2/session.json")" "sid-web"
like "copy refuses existing herdr" "$(bash "$HSABS" --copy web web2 2>&1)" "already exists"
hsc rm web >/dev/null

# --- workspaces closed in Moshi ---
mkdir -p "$HOME/proj/a" "$HOME/proj/b"
cat > "$HS_HC_STATE/multi.json" <<JSON
{"name":"multi","core":"multi","stopped":true,"workspaces":[
 {"name":"a","cwd":"$HOME/proj/a","tabs":[{"name":"a","cwd":"$HOME/proj/a","claude":{"id":"sid-a","cwd":"$HOME/proj/a"}}]},
 {"name":"b","cwd":"$HOME/proj/b","tabs":[{"name":"b","cwd":"$HOME/proj/b","claude":{"id":"sid-b","cwd":"$HOME/proj/b"}}]}]}
JSON
hsc multi >/dev/null
like "both workspaces open" "$(spaces multi)" "b:"
drop_space multi b
like "rm refuses an open workspace" "$(hsc rm multi a)" "is open"
# A reboot: every terminal ends and nothing runs hsc x. The doc survives it.
kill_all multi
: > "$HS_FAKESH_LOG"
out="$(hsc multi)"; sleep 0.5
like "closed workspace is reported" "$out" "closed in multi: b"
like "open workspace restored" "$(cat "$HS_FAKESH_LOG")" "claude --resume sid-a"
is   "closed workspace stays closed" "$(grep -c sid-b "$HS_FAKESH_LOG")" "0"
is   "record marks it closed" "$(rec multi 'r["workspaces"][1].get("closed")')" "True"
is   "closed keeps its claude id" "$(rec multi 'r["workspaces"][1]["tabs"][0]["claude"]["id"]')" "sid-b"
hsc x multi >/dev/null; : > "$HS_FAKESH_LOG"; hsc multi >/dev/null 2>&1; sleep 0.5
is   "closed survives stop/start" "$(grep -c sid-b "$HS_FAKESH_LOG")" "0"
out="$(hsc multi B)"; sleep 0.5
like "reopen resumes claude" "$(cat "$HS_FAKESH_LOG")" "claude --resume sid-b"
like "reopen attaches to it" "$out" "EXEC: hc attach"
like "reopened space published" "$(spaces multi)" "b:"
is   "reopened is not closed" "$(rec multi 'r["workspaces"][1].get("closed")')" "False"
like "unknown workspace lists names" "$(hsc multi zzz)" "it has: a, b"
drop_space multi b
like "rm one workspace" "$(hsc rm multi b)" "deleted workspace b"
is   "workspace gone from record" "$(rec multi 'len(r["workspaces"])')" "1"
like "rm refuses the last workspace" "$(hsc rm multi a)" "only workspace"

# --- made in Moshi: adopted ---
# Moshi adds a tab: a terminal of its own plus a tab in the space, no hs labels.
ta="$(rec multi 'r["workspaces"][0]["tabs"][0]["terminal"]')"
tm="$(cd "$HOME/proj/a" && HC_SESSION="${PFX}multi" hc run --bg --json sleep 300 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["address"])')"
HC_SESSION="${PFX}multi" python3 - "$tm" <<'ADD'
import json, subprocess, sys
def rpc(calls):
    lines = [{"jsonrpc":"2.0","id":0,"method":"hello","params":{}}] + \
            [{"jsonrpc":"2.0","id":i+1,"method":m,"params":p} for i,(m,p) in enumerate(calls)]
    out = subprocess.run(["hc","connect"], input="".join(json.dumps(x)+"\n" for x in lines),
                         capture_output=True, text=True).stdout
    return {json.loads(l)["id"]: json.loads(l) for l in out.splitlines()}
got = rpc([("doc.get", {"name":"herdr-app"})])[1]["result"]; v = got["value"]
v["spaces"][0]["tabs"].append({"id":"tbmoshi","name":"notes","root":{"id":"tbmoshi","type":"row",
  "children":[{"id":"pm","type":"block","content":{"terminal":sys.argv[1]}}]}})
v["spaces"][0]["name"] = "a-renamed"
rpc([("doc.set", {"name":"herdr-app","value":v,"version":got["version"]})])
ADD
hook start multi "$tm" '{"session_id":"sid-moshi"}'
is "Moshi tab adopted with its claude" "$(rec multi '[t["claude"]["id"] for t in r["workspaces"][0]["tabs"] if t["name"]=="notes"][0]')" "sid-moshi"
is "Moshi rename followed" "$(rec multi 'r["workspaces"][0]["name"]')" "a-renamed"
# The hook finds hsc's own tab by id even after the record changed shape.
hook start multi "$ta" '{"session_id":"sid-a2"}'
is "hook by tab id" "$(rec multi 'r["workspaces"][0]["tabs"][0]["claude"]["id"]')" "sid-a2"
: > "$HS_FAKESH_LOG"
like "restart" "$(hsc r multi)" "restarted multi"
sleep 0.5
like "adopted tab resumes after restart" "$(cat "$HS_FAKESH_LOG")" "claude --resume sid-moshi"
is   "restart: two terminals" "$(terms multi | wc -l)" "2"

# --- adding and moving workspaces ---
mkdir -p "$HOME/proj/c"
like "add a workspace by folder" "$(hsc multi "$HOME/proj/c")" "EXEC: hc attach"
like "added workspace published" "$(spaces multi)" "c:"
# One workspace into a new session, while both run: it ends here, resumes there.
hook start multi "$(rec multi '[t["terminal"] for w in r["workspaces"] if w["name"]=="c" for t in w["tabs"]][0]')" '{"session_id":"sid-c"}'
: > "$HS_FAKESH_LOG"
like "mv one workspace" "$(hsc mv multi meta c)" "moved c from multi into meta"
sleep 0.5
is   "gone from source" "$(rec multi '[w["name"] for w in r["workspaces"]]')" "['a-renamed']"
like "resumed in destination" "$(cat "$HS_FAKESH_LOG")" "claude --resume sid-c"
is   "destination has its own core" "$(core_on meta)" "up"
like "space now in meta" "$(spaces meta)" "c:"
like "space gone from multi" "$(spaces multi)" "a-renamed:"
# A whole session into another: the source is deleted and its core stopped.
like "mv whole session" "$(hsc mv multi meta)" "moved 1 workspace from multi into meta"
is   "source record deleted" "$(ls "$HS_HC_STATE/multi.json" 2>/dev/null | wc -l)" "0"
is   "source core stopped" "$(core_on multi)" "down"
is   "meta has both" "$(rec meta 'sorted(w["name"] for w in r["workspaces"])')" "['a-renamed', 'c']"
like "mv from inside detaches" "$( (cd "$HOME/proj" && HC_TERMINAL_ID="$(rec meta '[t["terminal"] for w in r["workspaces"] if w["name"]=="c" for t in w["tabs"]][0]')" HC_TERMINAL_SOCKET="$RUN/${PFX}meta.sock" bash "$HSABS" -c mv meta meta2 c) 2>&1 )" "including this terminal"
sleep 4
like "detached mv finished" "$(cat "$HS_HC_STATE/meta.move.log")" "moved c from meta into meta2"
is   "meta2 running" "$(core_on meta2)" "up"
hsc x meta >/dev/null; hsc x meta2 >/dev/null

# --- legacy records (no core) keep using the default core ---
mkdir -p "$HOME/proj/old"
cat > "$HS_HC_STATE/old.json" <<JSON
{"name":"old","stopped":true,"workspaces":[
 {"name":"old","cwd":"$HOME/proj/old","tabs":[{"name":"old","cwd":"$HOME/proj/old"}]}]}
JSON
hsc old >/dev/null
like "legacy publishes in the base core" "$(spaces x "$HC_SESSION")" "old:"
is   "legacy got no core of its own" "$(core_on old)" "down"
hsc x old >/dev/null; hsc rm old >/dev/null

# --- boot restore ---
cat > "$HS_HC_STATE/boot.json" <<JSON
{"name":"boot","core":"boot","stopped":false,"workspaces":[
 {"name":"c","cwd":"$HOME/proj/c","tabs":[{"name":"c","cwd":"$HOME/proj/c","claude":{"id":"sid-boot","cwd":"$HOME/proj/c"}}]}]}
JSON
: > "$HS_FAKESH_LOG"
out="$(python3 "$LIBABS" restore-all 2>&1)"; sleep 0.5
like "boot restores a running session" "$out" "restored boot"
is   "boot starts its core" "$(core_on boot)" "up"
like "boot resumes its claude" "$(cat "$HS_FAKESH_LOG")" "claude --resume sid-boot"
is   "boot leaves stopped sessions" "$(core_on meta)" "down"
like "boot publishes its space" "$(spaces boot)" "c:"
out="$(python3 "$LIBABS" restore-all 2>&1)"
like "boot again skips live" "$out" "boot is already running"
is   "boot again starts nothing" "$(terms boot | wc -l)" "1"

# --- restart ---
old="$(rec boot 'r["workspaces"][0]["tabs"][0]["terminal"]')"
: > "$HS_FAKESH_LOG"
out="$( (cd "$HOME/proj" && HC_TERMINAL_ID="$old" HC_TERMINAL_SOCKET="$RUN/${PFX}boot.sock" bash "$HSABS" -c r boot) 2>&1 )"
like "restart from inside detaches" "$out" "including this terminal"
sleep 4
like "inside restart resumes claude" "$(cat "$HS_FAKESH_LOG")" "claude --resume sid-boot"
is   "inside restart: one live terminal" "$(terms boot | wc -l)" "1"
like "inside restart logged" "$(cat "$HS_HC_STATE/boot.restart.log")" "restarted boot"
hsc x boot >/dev/null
like "nothing to restore" "$(python3 "$LIBABS" restore-all 2>&1)" "no running hsc sessions"

# --- really from inside: hsc runs IN one of the session's terminals ---
# hc kills a terminal's whole process scope, so a job that only setsid's away
# dies with it. Run `hsc r` from inside a terminal of the session itself.
mkdir -p "$HOME/proj/inn"
cat > "$HS_HC_STATE/inn.json" <<JSON
{"name":"inn","core":"inn","stopped":true,"workspaces":[
 {"name":"inn","cwd":"$HOME/proj/inn","tabs":[{"name":"inn","cwd":"$HOME/proj/inn","claude":{"id":"sid-inn","cwd":"$HOME/proj/inn"}}]}]}
JSON
hsc inn >/dev/null; sleep 0.5
: > "$HS_FAKESH_LOG"
HC_SESSION="${PFX}inn" hc run --bg --json -- /bin/bash -c "bash '$HSABS' -c r inn; sleep 30" >/dev/null 2>&1
sleep 6
like "real inside restart finished" "$(cat "$HS_HC_STATE/inn.restart.log" 2>/dev/null)" "restarted inn"
like "real inside restart resumed claude" "$(cat "$HS_FAKESH_LOG")" "claude --resume sid-inn"
# And a real inside move: the whole session into another, from its own terminal.
HC_SESSION="${PFX}inn" hc run --bg --json -- /bin/bash -c "bash '$HSABS' -c mv inn inn2; sleep 30" >/dev/null 2>&1
sleep 6
like "real inside move finished" "$(cat "$HS_HC_STATE/inn.move.log" 2>/dev/null)" "moved 1 workspace from inn into inn2"
is   "moved session running" "$(core_on inn2)" "up"
is   "source core stopped" "$(core_on inn)" "down"
hsc x inn2 >/dev/null

# --- kept tabs (made in Moshi) come back as shells after a reboot ---
cat > "$TMP/bin/claude" <<'SH'
#!/bin/sh
printf 'claude %s\n' "$*" >> "$HS_FAKESH_LOG"; exec sleep 300
SH
chmod +x "$TMP/bin/claude"
mkdir -p "$HOME/proj/kept"
cat > "$HS_HC_STATE/kept.json" <<JSON
{"name":"kept","core":"kept","stopped":true,"workspaces":[
 {"name":"kept","cwd":"$HOME/proj/kept","tabs":[{"name":"kept","cwd":"$HOME/proj/kept"}]}]}
JSON
hsc kept >/dev/null; sleep 0.5
tk="$(cd "$HOME/proj/kept" && HC_SESSION="${PFX}kept" hc run --bg --keep --json -- /bin/bash 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["address"])')"
HC_SESSION="${PFX}kept" python3 - "$tk" <<'ADD'
import json, subprocess, sys
def rpc(calls):
    lines = [{"jsonrpc":"2.0","id":0,"method":"hello","params":{}}] + \
            [{"jsonrpc":"2.0","id":i+1,"method":m,"params":p} for i,(m,p) in enumerate(calls)]
    out = subprocess.run(["hc","connect"], input="".join(json.dumps(x)+"\n" for x in lines),
                         capture_output=True, text=True).stdout
    return {json.loads(l)["id"]: json.loads(l) for l in out.splitlines()}
got = rpc([("doc.get", {"name":"herdr-app"})])[1]["result"]; v = got["value"]
v["spaces"][0]["tabs"].append({"id":"tbkept","name":"k","root":{"id":"tbkept","type":"row",
  "children":[{"id":"pk","type":"block","content":{"terminal":sys.argv[1]}}]}})
rpc([("doc.set", {"name":"herdr-app","value":v,"version":got["version"]})])
ADD
hook start kept "$tk" "{\"session_id\":\"sid-kept\",\"cwd\":\"$HOME/proj/kept\"}"
# The reboot: the core stops without hsc x; kept terminals are parked.
HC_SESSION="${PFX}kept" hc server stop >/dev/null 2>&1; sleep 0.5
: > "$HS_FAKESH_LOG"
out="$(SHELL=/bin/bash python3 "$LIBABS" restore-all 2>&1)"; sleep 3  # hc revives a kept tab with $SHELL
like "boot resumes claude in a kept tab" "$out" "1 kept tab resumed"
like "kept tab runs the resume" "$(cat "$HS_FAKESH_LOG")" "claude --resume sid-kept"
hsc x kept >/dev/null

finish
