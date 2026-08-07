#!/usr/bin/env bash
# speak-phone (deploy/build/speak-phone) — the summary-to-audio tool behind the phone
# read-along page. The load-bearing behaviours are: what gets SPOKEN vs merely SHOWN,
# that markdown syntax never reaches the voice, that sessions cannot collide, that old
# summaries are pruned, and that the server refuses to serve anything outside its store.
#
# piper is stubbed. Real rendering is exercised by hand (and was, on the device); what
# needs pinning here is everything around it, which is where the bugs would hide.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SP="$(cd .. && pwd)/deploy/build/speak-phone"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/voices" "$TMP/bin"
: > "$TMP/voices/en_US-amy-medium.onnx"
: > "$TMP/voices/en_US-ryan-high.onnx"

# Stub piper: reads --json-input lines and writes a plausible wav to each output_file.
# Records its argv so the tests can assert on model and length_scale.
# Emits REAL wavs (a valid header and a length proportional to the text), because the
# tool joins the parts with the `wave` module to produce one continuous stream. A fake
# RIFF blob parses as garbage and the join fails.
cat > "$TMP/bin/piper" <<'STUB'
#!/usr/bin/env python3
import json, sys, pathlib, wave
pathlib.Path(sys.argv[0] + ".argv").write_text(" ".join(sys.argv[1:]))
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    j = json.loads(line)
    p = pathlib.Path(j["output_file"])
    p.parent.mkdir(parents=True, exist_ok=True)
    frames = max(1, len(j["text"])) * 100      # longer text -> longer audio
    with wave.open(str(p), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050)
        w.writeframes(b"\0\0" * frames)
STUB
chmod +x "$TMP/bin/piper"

export SPEAK_PIPER="$TMP/bin/piper"
export SPEAK_VOICES="$TMP/voices"
export SPEAK_STATE="$TMP/state"
export SPEAK_CONF="$TMP/speak.env"

sp() { "$SP" "$@"; }
meta() { # $1 = session slug -> newest meta.json
  ls -d "$TMP/state/$1"/*/ 2>/dev/null | sort -r | head -1 | sed 's|$|meta.json|'
}
field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2"; }

# ---- what is spoken, what is only shown ---------------------------------------------
# The single rule the whole design rests on: prose is spoken, fenced blocks and tables
# are shown. If this ever inverts, Claude starts reading shell commands out loud.
printf '%s\n' \
  'First sentence. Second one here.' '' \
  '```' 'rm -rf /nope' '```' '' \
  '| a | b |' '| 1 | 2 |' '' \
  'Third sentence.' | sp --session Blocks >/dev/null 2>&1

M="$(meta Blocks)"
SPOKEN="$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
print(' '.join(s for b in m['blocks'] if b['kind']=='prose' for s in b['sentences']))" "$M")"
SHOWN="$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
print(' '.join(b['text'] for b in m['blocks'] if b['kind']=='shown'))" "$M")"

is   "three sentences spoken"        "$(field "$M" sentences)" "3"
like "code block is shown"           "$SHOWN"  "rm -rf /nope"
unlike "code block is NOT spoken"    "$SPOKEN" "rm -rf"
like "table is shown"                "$SHOWN"  "| a | b |"
unlike "table is NOT spoken"         "$SPOKEN" "| a |"

# ---- option lists --------------------------------------------------------------------
# Bullets used to be flattened into one paragraph, which reads choices as a single
# breathless sentence. Each item must be its own audio segment, and a list ANSWERING A
# QUESTION gains a spoken "Option one" cue that the screen does not repeat (it numbers
# them visually already).
printf '%s\n' 'Which way do you want to go?' '' \
  '- Keep it local.' '- Add a push later.' '- Do nothing.' '' 'Tell me which.' \
  | sp --session Opts >/dev/null 2>&1
M="$(meta Opts)"
KINDS="$(python3 -c "
import json,sys;print(' '.join(b['kind'] for b in json.load(open(sys.argv[1]))['blocks']))" "$M")"
is "list is its own block kind" "$KINDS" "prose list prose"

SHOW="$(python3 -c "
import json,sys
b=[x for x in json.load(open(sys.argv[1]))['blocks'] if x['kind']=='list'][0]
print('|'.join(b['sentences']))" "$M")"
SAY="$(python3 -c "
import json,sys
b=[x for x in json.load(open(sys.argv[1]))['blocks'] if x['kind']=='list'][0]
print('|'.join(b['say']))" "$M")"
is     "three options kept separate" "$(printf '%s' "$SHOW" | tr -cd '|' | wc -c | tr -d ' ')" "2"
like   "speech announces the option" "$SAY"  "Option one. Keep it local."
like   "third option is numbered"    "$SAY"  "Option three."
unlike "screen does NOT repeat the number" "$SHOW" "Option one"
is "each option gets its own offset" \
   "$(python3 -c "
import json,sys
b=[x for x in json.load(open(sys.argv[1]))['blocks'] if x['kind']=='list'][0]
print(len([a for a in b['at'] if a is not None]))" "$M")" "3"

# A list that is NOT answering a question must not be numbered aloud -- "Option one" in
# front of a plain list of facts is nonsense.
printf '%s\n' 'Here is what changed today.' '' '- The voice got faster.' '- The page got a header.' \
  | sp --session Plain >/dev/null 2>&1
SAY2="$(python3 -c "
import json,sys
b=[x for x in json.load(open(sys.argv[1]))['blocks'] if x['kind']=='list'][0]
print('|'.join(b['say']))" "$(meta Plain)")"
unlike "plain list is not numbered aloud" "$SAY2" "Option"

# ---- links: tappable on screen, silent in the voice ----------------------------------
# A reference he cannot tap is one he has to retype on a phone; a URL read aloud is noise.
# So display and speech diverge — anchor on screen, label only in the audio.
printf '%s\n' \
  'See [the spec](https://example.com/n/abc) for detail. Raw one: https://example.com/raw here.' '' \
  '```' 'repo/docs/specs/thing.md' 'https://example.com/n/xyz' '```' \
  | sp --session Links >/dev/null 2>&1
LM="$(meta Links)"
LSAY="$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
print(' '.join(x for b in m['blocks'] if b['kind']=='prose' for x in b['say']))" "$LM")"
unlike "markdown link url is not spoken" "$LSAY" "example.com/n/abc"
like   "its label is spoken"             "$LSAY" "the spec"
unlike "bare url is not spoken"          "$LSAY" "example.com/raw"

LPAGE="$(curl -sf "http://127.0.0.1:$PORT/s/Links" 2>/dev/null || true)"

# ---- identity comes from the CALLING pane, never the focused one ----------------------
# `moshi-hook context` resolves herdr fields from whatever pane is on screen while taking
# cwd from the caller. That mixed provenance filed one agent's summaries into another
# agent's stream, so two agents interleaved and evicted each other under the retention cap.
# herdr exports the calling pane's own ids into its environment; those are authoritative
# regardless of focus, which is why they are the only thing consulted.
paneid() { # HERDR_* env -> the pane where() reports
  HERDR_SESSION="$1" HERDR_WORKSPACE_ID="$2" HERDR_TAB_ID="$3" HERDR_PANE_ID="$4" \
  python3 -c "
import importlib.util
s=importlib.util.spec_from_loader('sp',None); m=importlib.util.module_from_spec(s)
exec(open('$SP').read().split('if __name__')[0], m.__dict__)
w=m.where(); print(w.get('mux','')+'|'+w.get('pane','')+'|'+w.get('workspace',''))"
}
is "the calling pane's own id is used" \
   "$(paneid Sess w6 w6:t2 w6:p2)" "herdr|w6:p2|w6"
is "a different pane resolves differently" \
   "$(paneid Sess w1 w1:tB w1:pF)" "herdr|w1:pF|w1"

# ---- names survive a dead herdr API socket -------------------------------------------
# Detaching every client at once takes the API listener down on every long-running session
# and it does not come back when they are reattached. The servers keep running, so nothing
# looks broken -- but every name lookup returned nothing and the raw ids leaked into the
# slug, splitting a live stream in two (`NetSapiens--super-portal` became
# `NetSapiens--w1--w1-tC`). session.json is written by the server throughout, so these run
# with no `herdr` binary reachable at all.
HH="$TMP/herdrhome"
mkdir -p "$HH/.config/herdr/sessions/Fixture"
cat > "$HH/.config/herdr/sessions/Fixture/session.json" <<'JSON'
{"version":3,"workspaces":[
 {"id":"w1","custom_name":null,"identity_cwd":"/home/x/workspace/NetSapiens",
  "public_tab_numbers":[4,12,10],
  "tabs":[{"custom_name":"subscription-webhooks"},
          {"custom_name":"super-portal"},
          {"custom_name":"rt-custom"}]},
 {"id":"w6","custom_name":"Renamed","identity_cwd":"/home/x/workspace/OneBill",
  "public_tab_numbers":[1],
  "tabs":[{"custom_name":"OneBill"}]}]}
JSON

# No herdr on PATH: if the file is not consulted, every one of these falls back to ids.
names() { # session ws tab -> "<workspace>|<tab>"
  HOME="$HH" PATH="$TMP/bin:/usr/bin:/bin" python3 -c "
import importlib.util
s=importlib.util.spec_from_loader('sp',None); m=importlib.util.module_from_spec(s)
exec(open('$SP').read().split('if __name__')[0], m.__dict__)
print('|'.join(m._herdr_names('$1','$2','$3')))"
}

# Tab ids carry the public tab number in HEX. Read as decimal, `w1:tC` matches nothing and
# `w1:t12` matches the wrong tab -- both of which look like a rename rather than a bug.
is "a hex tab id resolves to its name" \
   "$(names Fixture w1 w1:tC)" "NetSapiens|super-portal"
is "a single-digit tab id resolves" \
   "$(names Fixture w1 w1:t4)" "NetSapiens|subscription-webhooks"
is "another hex tab id resolves" \
   "$(names Fixture w1 w1:tA)" "NetSapiens|rt-custom"
# A workspace usually has no name of its own; herdr labels it with its directory, and the
# overview has to agree with the tab bar or the two cannot be matched up by eye.
is "an unnamed workspace takes its directory" \
   "$(names Fixture w1 w1:t4 | cut -d'|' -f1)" "NetSapiens"
is "a named workspace keeps its name" \
   "$(names Fixture w6 w6:t1)" "Renamed|OneBill"
# Degrade to the id rather than to a wrong name.
is "an unknown tab id resolves to nothing" \
   "$(names Fixture w1 w1:tZ)" "NetSapiens|"
is "an unknown workspace resolves to nothing" \
   "$(names Fixture w9 w9:t1)" "|"
is "a missing session file resolves to nothing" \
   "$(names Absent w1 w1:t1)" "|"
# The session name is interpolated into a path. It comes from the environment, so it is
# not attacker-controlled, but it also must never leave the sessions directory.
is "a session name cannot traverse" \
   "$(names ../../../etc w1 w1:t1)" "|"

# End to end: the whole path from environment to slug, with nothing to query.
fullslug() { # session ws tab pane -> slug
  HOME="$HH" PATH="$TMP/bin:/usr/bin:/bin" \
  HERDR_SESSION="$1" HERDR_WORKSPACE_ID="$2" HERDR_TAB_ID="$3" HERDR_PANE_ID="$4" \
  python3 -c "
import importlib.util
s=importlib.util.spec_from_loader('sp',None); m=importlib.util.module_from_spec(s)
exec(open('$SP').read().split('if __name__')[0], m.__dict__)
print(m.identity(m.where(), '$1')[1])"
}
is "a named slug is produced with no herdr server" \
   "$(fullslug Fixture w1 w1:tC w1:pE)" "Fixture--NetSapiens--super-portal"

# ---- one stream per AGENT, not per session -------------------------------------------
# A herdr session holds several workspaces, each holding several tabs, each typically one
# agent. Keyed on the session alone, six agents in one workspace share a stream and evict
# each other under the retention cap. Tab alone is no better: `cli` exists in three
# different workspaces in the real layout this was built against.
ident() { # $1 = where() JSON, $2 = session -> "<display>|<slug>"
  python3 -c "
import importlib.util, json, sys
s=importlib.util.spec_from_loader('sp',None); m=importlib.util.module_from_spec(s)
exec(open('$SP').read().split('if __name__')[0], m.__dict__)
d,g=m.identity(json.loads(sys.argv[1]), sys.argv[2])
print(d+'|'+g)" "$1" "$2"
}
slug() { ident "$1" "$2" | cut -d'|' -f2; }

is "workspace named after its session collapses" \
   "$(slug '{"workspace":"NetSapiens","tab":"subscription-webhooks"}' NetSapiens)" \
   "NetSapiens--subscription-webhooks"
is "a second workspace is kept" \
   "$(slug '{"workspace":"OneBill","tab":"n8n-onebill"}' NetSapiens)" \
   "NetSapiens--OneBill--n8n-onebill"

# The case that matters: same tab name, three workspaces, three streams.
A="$(slug '{"workspace":"NetSapiens","tab":"cli"}' NetSapiens)"
B="$(slug '{"workspace":"Documo","tab":"cli"}' NetSapiens)"
C="$(slug '{"workspace":"OneBill","tab":"cli"}' NetSapiens)"
if [ "$A" != "$B" ] && [ "$B" != "$C" ] && [ "$A" != "$C" ]; then
  ok "same tab in three workspaces gets three slugs"
else
  fail "same tab in three workspaces gets three slugs" "$A / $B / $C"
fi

is "two tabs in one workspace differ" \
   "$(slug '{"workspace":"OneBill","tab":"cli"}' NetSapiens)" "NetSapiens--OneBill--cli"
# A tab named after its own workspace collapses the same way a workspace named after its
# session does. Safe, because only one tab in a workspace can carry that name -- and it
# keeps the common "OneBill/OneBill" case from reading as a stutter.
is "a tab named after its workspace collapses" \
   "$(slug '{"workspace":"OneBill","tab":"OneBill"}' NetSapiens)" "NetSapiens--OneBill"
is "an unnamed tab falls back to the pane" \
   "$(slug '{"workspace":"","tab":"","pane":"w1:p3"}' Solo)" "Solo--w1-p3"
# The overview shows the FULL identity: dropping the leading part made siblings from
# different sessions read identically, which is the collision this key exists to prevent.
is "display is the full identity" \
   "$(ident '{"workspace":"OneBill","tab":"cli"}' NetSapiens | cut -d'|' -f1)" \
   "NetSapiens / OneBill / cli"
is "and collapses the same way the slug does" \
   "$(ident '{"workspace":"Remote-VS-Code","tab":"speak-claude"}' Remote-VS-Code | cut -d'|' -f1)" \
   "Remote-VS-Code / speak-claude"

# Two agents publishing from different tabs must not touch each other's history.
SPEAK_TAB_TEST=1 printf 'Alpha agent speaking.\n' | sp --session A1 >/dev/null 2>&1
printf 'Beta agent speaking.\n' | sp --session B1 >/dev/null 2>&1
is "each forced session keeps its own store" \
   "$(ls -d "$TMP"/state/A1 "$TMP"/state/B1 2>/dev/null | wc -l | tr -d ' ')" "2"

# ---- session identity ----------------------------------------------------------------
# With a dozen sessions running, the project name alone identifies nothing. The path
# below the project is what tells two sessions in one repo apart.
is "subpath drops the duplicated project name" \
   "$(SPEAK_WORKSPACE=/w python3 -c "
import sys;sys.path.insert(0,'.')
import importlib.util
s=importlib.util.spec_from_loader('sp',None); m=importlib.util.module_from_spec(s)
exec(open('$SP').read().split('if __name__')[0], m.__dict__)
print(m.subpath('/w/Proj/repo/deploy','Proj'))")" "repo/deploy"

is "subpath is empty at the project root" \
   "$(SPEAK_WORKSPACE=/w python3 -c "
import importlib.util
s=importlib.util.spec_from_loader('sp',None); m=importlib.util.module_from_spec(s)
exec(open('$SP').read().split('if __name__')[0], m.__dict__)
print(repr(m.subpath('/w/Proj','Proj')))")" "''"

# NB: uses the REAL $HOME. Overriding it here looked tidier but python3 is wrapped by a
# shim (npm safe-chain) that writes to $HOME on startup and dies on a path it cannot
# create, so the test failed before reaching any of this code.
is "outside the workspace falls back to a home path" \
   "$(SPEAK_WORKSPACE=/w python3 -c "
import importlib.util, pathlib
s=importlib.util.spec_from_loader('sp',None); m=importlib.util.module_from_spec(s)
exec(open('$SP').read().split('if __name__')[0], m.__dict__)
print(m.subpath(str(pathlib.Path.home()/'scratch/thing'),'Proj'))")" "~/scratch/thing"

is "outside home entirely keeps the absolute path" \
   "$(SPEAK_WORKSPACE=/w python3 -c "
import importlib.util
s=importlib.util.spec_from_loader('sp',None); m=importlib.util.module_from_spec(s)
exec(open('$SP').read().split('if __name__')[0], m.__dict__)
print(m.subpath('/srv/thing','Proj'))")" "/srv/thing"

# ---- markdown never reaches the voice ------------------------------------------------
printf '%s\n' 'Run `speak-phone` for **this** and *that*. See [the spec](https://example.com/p).' \
  | sp --session Syntax >/dev/null 2>&1
S="$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
print(' '.join(s for b in m['blocks'] if b['kind']=='prose' for s in b['sentences']))" "$(meta Syntax)")"
unlike "backticks stripped"   "$S" '`'
unlike "bold markers stripped" "$S" '**'
unlike "url not spoken"        "$S" "example.com"
like   "link text kept"        "$S" "the spec"

# ---- sentence splitting --------------------------------------------------------------
printf '%s\n' 'We upgraded to version 2.0. It works, e.g. on this box. Done.' \
  | sp --session Split >/dev/null 2>&1
is "abbreviation does not split the sentence" "$(field "$(meta Split)" sentences)" "3"

# ---- ONE audio file, with per-sentence offsets ---------------------------------------
# A file per sentence stalled 2-3s between sentences on wireless CarPlay: every play() on
# an idle stream re-establishes the audio route. One continuous file pays that once, and
# the offsets keep the highlighting.
is "exactly one audio file" "$(ls "$TMP"/state/Split/*/*.wav | wc -l | tr -d ' ')" "1"
is "and it is the joined one" \
   "$(basename "$(ls "$TMP"/state/Split/*/*.wav | head -1)")" "audio.wav"
is "every sentence has a start offset" \
   "$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
print(len([x for b in m['blocks'] if b['kind']=='prose' for x in b['at'] if x is not None]))" \
   "$(meta Split)")" "3"
is "offsets increase" \
   "$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
a=[x for b in m['blocks'] if b['kind']=='prose' for x in b['at']]
print('yes' if a==sorted(a) and a[0]==0 else f'no {a}')" "$(meta Split)")" "yes"

# ---- voice selection and config ------------------------------------------------------
printf 'Hello there.\n' | sp --voice en_US-ryan-high --session Voice >/dev/null 2>&1
like "per-run voice reaches piper" "$(cat "$TMP/bin/piper.argv")" "en_US-ryan-high"
like "rate reaches piper"          "$(cat "$TMP/bin/piper.argv")" "--length_scale 0.595"

sp voice en_US-ryan-high >/dev/null 2>&1
like "voice subcommand writes config" "$(cat "$TMP/speak.env")" "VOICE=en_US-ryan-high"
printf 'Hello again.\n' | sp --session Voice2 >/dev/null 2>&1
is "config voice is used by default" "$(field "$(meta Voice2)" voice)" "en_US-ryan-high"

OUT="$(sp voice no-such-voice 2>&1)"; RC=$?
is   "unknown voice fails"          "$RC" "1"
like "unknown voice names what it has" "$OUT" "en_US-amy-medium"
sp voice en_US-amy-medium >/dev/null 2>&1

# ---- sessions do not collide ---------------------------------------------------------
printf 'Alpha summary here.\n' | sp --session Alpha >/dev/null 2>&1
printf 'Beta summary here.\n'  | sp --session Beta  >/dev/null 2>&1
like "alpha kept its own text" "$(cat "$(meta Alpha)")" "Alpha summary"
like "beta kept its own text"  "$(cat "$(meta Beta)")"  "Beta summary"

# A name that would escape its directory or the URL must not be able to.
printf 'Nasty name.\n' | sp --session '../../etc/passwd' >/dev/null 2>&1
is "path traversal in session name is neutralised" \
   "$(find "$TMP/state" -maxdepth 1 -name '*passwd*' | wc -l | tr -d ' ')" "1"
is "nothing escaped the store" "$(ls "$TMP" | grep -c passwd)" "0"

# ---- pruning -------------------------------------------------------------------------
printf 'KEEP=3\n' >> "$TMP/speak.env"
for i in 1 2 3 4 5; do
  printf 'Prune test %s.\n' "$i" | sp --session Prune >/dev/null 2>&1
  sleep 1.05   # timestamps are per-second; distinct dirs are the point
done
is "keeps only KEEP summaries" "$(ls -d "$TMP"/state/Prune/*/ | wc -l | tr -d ' ')" "3"
like "the newest survived" "$(cat "$(meta Prune)")" "Prune test 5"

# An agent that stops publishing leaves a stream behind. Its summaries age out like any
# other, but the empty directory used to outlive it forever -- and with the cap now per
# agent rather than shared, those accumulate instead of being evicted by newer work.
printf 'Abandoned agent.\n' | sp --session Gone >/dev/null 2>&1
python3 -c "
import json,glob,time,sys
p=glob.glob(sys.argv[1]+'/state/Gone/*/meta.json')[0]
m=json.load(open(p)); m['created']=time.time()-30*86400; json.dump(m,open(p,'w'))" "$TMP"
printf 'Someone else publishes.\n' | sp --session Still >/dev/null 2>&1
is "an abandoned stream is reaped entirely" \
   "$([ -e "$TMP/state/Gone" ] && echo present || echo gone)" "gone"
is "the live stream is untouched" \
   "$([ -d "$TMP/state/Still" ] && echo present || echo gone)" "present"

# ---- refuses input with nothing to say -----------------------------------------------
OUT="$(printf '```\nonly code\n```\n' | sp --session Empty 2>&1)"; RC=$?
is   "all-code input is refused"  "$RC" "1"
like "and says why"               "$OUT" "no prose"

OUT="$(printf '' | sp --session Empty2 2>&1)"; RC=$?
is "empty input is refused" "$RC" "1"

# ---- the server ----------------------------------------------------------------------
# A free port per run, and cleanup BY LISTENER rather than by the pid we backgrounded:
# python3 may be wrapped by a shim (npm safe-chain does this), so $! is the wrapper and
# killing it leaves the real server holding the port with a deleted state dir. That
# survivor then answers the next run's requests from a store that no longer exists, and
# every server assertion fails for reasons that have nothing to do with the code.
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
printf 'PORT=%s\n' "$PORT" >> "$TMP/speak.env"
sp serve >"$TMP/server.log" 2>&1 &
SRV=$!
kill_server() {
  local p
  p="$(ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
  [ -n "$p" ] && kill "$p" 2>/dev/null
  kill "$SRV" 2>/dev/null
  return 0
}
trap 'kill_server; rm -rf "$TMP"' EXIT
for _ in $(seq 30); do curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.2; done

# `/` is where the terminal app's server list lands you, so it should go straight to the
# newest summary rather than an index you have to tap through. The list stays at /all.
ROOT="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
is "root redirects to a summary" "$ROOT" "303"
LOC="$(curl -s -o /dev/null -D - "http://127.0.0.1:$PORT/" | grep -i '^location:' | tr -d '\r')"
like "and it points at a session page" "$LOC" "/s/"

INDEX="$(curl -sf "http://127.0.0.1:$PORT/all")"
like "index lists a session"        "$INDEX" "Alpha"
like "index is titled for the list" "$INDEX" "<title>Claude summaries</title>"
like "a summary links back to the list" "$(curl -sf "http://127.0.0.1:$PORT/s/Blocks")" "/all"

PAGE="$(curl -sf "http://127.0.0.1:$PORT/s/Blocks")"
like "summary page has a sentence"     "$PAGE" "First sentence."
like "sentences carry a time offset" "$PAGE" "data-at='"
# A whole sentence is a tap target, so an anchor inside one would otherwise bubble into
# seek() and start playing the paragraph as you navigate away.
like "a link inside a sentence does not seek" "$PAGE" "closest('a')"
# `var` is function-scoped: a second `paint` in the same script silently replaced the
# sentence highlighter, so playback stopped highlighting entirely. One definition only.
is "the page script defines paint once" \
   "$(printf '%s' "$PAGE" | grep -c 'function paint()')" "1"
is "and the heard painter has its own name" \
   "$(printf '%s' "$PAGE" | grep -c 'var paintHeard=')" "1"
like "page holds one audio element"  "$PAGE" "<audio id=au"
# Seeking exactly onto a boundary clips the first syllable, so the player starts early.
like "seeks land before the boundary" "$PAGE" "LEAD=0.35"
# Speed is applied at playback and labelled in absolute terms, derived from the rate the
# file was baked at -- so the labels stay honest if RATE changes.
like "speed control is present"   "$PAGE" "class=spd"
like "and knows the baked speed"  "$PAGE" "data-baked='1.681'"
like "shown block is rendered"         "$PAGE" "rm -rf /nope"
like "shown block is labelled"         "$PAGE" "shown, not spoken"

TS="$(basename "$(dirname "$(meta Blocks)")")"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/a/Blocks/$TS/audio.wav")"
is "joined audio is served" "$CODE" "200"

# Range requests are what make iOS scrubbing work; without 206 the scrubber is dead.
RANGE="$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-9' \
         "http://127.0.0.1:$PORT/a/Blocks/$TS/audio.wav")"
is "range request returns 206" "$RANGE" "206"

# These MUST use --path-as-is: curl normalises "..' out of a URL before sending, so
# without it the earlier version of this loop was testing nothing. The guard's character
# class permits "." and "-", so ".." matched it and `/a/../../x.wav` served a file from
# outside the store — 200, with bytes. Dot components are now rejected outright and every
# route re-checks that its resolved path is still inside the store.
for BAD in "/a/../../../etc/passwd" "/s/..%2f..%2fetc" "/a/Blocks/$TS/../../../../etc/passwd" \
           "/a/../../probe.wav" "/s/.." "/s/../.." "/r/../../x/1" "/a/./../probe.wav" \
           "/v/../../x/en_US-amy-medium"; do
  C="$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$BAD")"
  case "$C" in 400|404) ok "traversal refused: $BAD ($C)" ;;
               *) fail "traversal refused: $BAD" "got $C" ;; esac
done

# A four-segment audio URL is the shape that got through: it passed the length check and
# every component passed the alphabet check.
PLANT="$TMP/outside.wav"
python3 -c "
import wave,sys
w=wave.open(sys.argv[1],'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050)
w.writeframes(b'\0\0'*100); w.close()" "$PLANT"
C="$(curl -s --path-as-is -o /dev/null -w '%{http_code}' \
     "http://127.0.0.1:$PORT/a/../../outside.wav")"
is "the exact bug that was reported is closed" "$C" "400"

C="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/s/NoSuchSession")"
is "unknown session is 404" "$C" "404"

# ---- links on the page ---------------------------------------------------------------
LPAGE="$(curl -sf "http://127.0.0.1:$PORT/s/Links")"
like "markdown link renders as an anchor" "$LPAGE" "<a href='https://example.com/n/abc'>the spec</a>"
like "bare url in prose renders too"      "$LPAGE" "href='https://example.com/raw'"
like "url in a shown block is tappable"   "$LPAGE" "href='https://example.com/n/xyz'"
like "the path beside it stays plain"     "$LPAGE" "repo/docs/specs/thing.md"

# ---- option list and headings on the page --------------------------------------------
OPAGE="$(curl -sf "http://127.0.0.1:$PORT/s/Opts")"
like "options render as a list"    "$OPAGE" "<ol class=opts>"
like "option text is on screen"    "$OPAGE" "Keep it local."
unlike "screen omits the spoken cue" "$OPAGE" "Option one."

# ---- the voice strip and switching voices --------------------------------------------
VPAGE="$(curl -sf "http://127.0.0.1:$PORT/s/Voice")"
like "voice strip is present"       "$VPAGE" "class=voices"
# Voice and speed are both "change it" controls, so they sit together at the end rather
# than above the text.
# Transport sits between the lower back/heard row and the adjustments, in the flow.
# Pause must stay reachable partway down a long summary on a phone: tapping a sentence
# starts playback, but nothing else stops it.
like "transport pins on small screens" "$VPAGE" "@media(max-width:640px)"
# Once the header scrolls away nothing names the session, and matching it in the terminal
# app meant scrolling back to the top of a long summary.
like "the identity sticks to the top on phones" "$VPAGE" "class=mini"
is "the play bar precedes the speed row" \
   "$(python3 -c "
import sys
h=sys.stdin.read(); print('yes' if h.index('class=bar') < h.index('class=spd') else 'no')" \
     <<< "$VPAGE")" "yes"
is "voices sit below the speed row" \
   "$(python3 -c "
import sys
h=sys.stdin.read(); print('yes' if h.index('class=voices') > h.index('class=spd') else 'no')" \
     <<< "$VPAGE")" "yes"
like "current voice is marked"      "$VPAGE" "class='cur'"
like "alternate voice is offered"   "$VPAGE" "/v/Voice/"

TS="$(basename "$(dirname "$(meta Opts)")")"
BEFORE="$(field "$(meta Opts)" voice)"
C="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v/Opts/$TS/en_US-ryan-high")"
is "switching voice redirects back" "$C" "303"
is "summary was re-spoken"          "$(field "$(meta Opts)" voice)" "en_US-ryan-high"
unlike "and it actually changed"    "$(field "$(meta Opts)" voice)" "$BEFORE"
like "the new voice became default" "$(cat "$TMP/speak.env")" "VOICE=en_US-ryan-high"
is "re-speak leaves one joined file" \
   "$(ls "$TMP/state/Opts/$TS"/*.wav | wc -l | tr -d ' ')" "1"

C="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v/Opts/$TS/not-a-voice")"
is "unknown voice is rejected" "$C" "400"

# ---- heard state ---------------------------------------------------------------------
# Kept in the summary's own metadata, not in browser storage: the same state on the phone
# and in a desktop browser, and it dies with the summary rather than outliving it.
BTS="$(basename "$(dirname "$(meta Blocks)")")"
is "a summary starts unheard" \
   "$(python3 -c "
import json,sys;print(json.load(open(sys.argv[1])).get('read', False))" "$(meta Blocks)")" "False"
like "the page offers the checkbox" "$(curl -sf "http://127.0.0.1:$PORT/s/Blocks")" "class='heard"

C="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/r/Blocks/$BTS/1")"
is "marking heard succeeds" "$C" "200"
is "and it persisted" \
   "$(python3 -c "
import json,sys;print(json.load(open(sys.argv[1]))['read'])" "$(meta Blocks)")" "True"
like "the overview dims it"  "$(curl -sf "http://127.0.0.1:$PORT/all")" "card done"
# The tick is always rendered (it is the tap target); "done" is what colours it.
like "and the heard card keeps its toggle" \
     "$(curl -sf "http://127.0.0.1:$PORT/all")" "<button class=mark"

C="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/r/Blocks/$BTS/0")"
is "unmarking works too" \
   "$(python3 -c "
import json,sys;print(json.load(open(sys.argv[1]))['read'])" "$(meta Blocks)")" "False"
C="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/r/Nope/x/1")"
is "marking something absent is 404" "$C" "404"

# The page carries the control at BOTH ends, and a back link beside the title.
HPAGE="$(curl -sf "http://127.0.0.1:$PORT/s/Blocks")"
is "the checkbox appears twice" \
   "$(printf '%s' "$HPAGE" | grep -o "class='heard" | wc -l | tr -d ' ')" "2"
is "a back link sits beside each heard row" \
   "$(printf '%s' "$HPAGE" | grep -o "class=back" | wc -l | tr -d ' ')" "2"
# A third way back, inside the transport bar. When that bar is pinned on a phone it is the
# only one always on screen; the other two scroll away with the text.
like "the transport bar has its own way back" "$HPAGE" "class=allmini"

# Auto-mark on finishing, but a deliberate choice outranks it PERMANENTLY: unchecking
# something you have already heard means "come back to it", and re-marking erases that.
rd() { python3 -c "
import json,sys
m=json.load(open(sys.argv[1])); print(str(m.get('read',False))+'/'+str(m.get('manual',False)))" "$1"; }
printf 'A fresh untouched summary.\n' | sp --session Auto >/dev/null 2>&1
ATS="$(basename "$(dirname "$(meta Auto)")")"
curl -s -o /dev/null "http://127.0.0.1:$PORT/r/Auto/$ATS/auto"
is "auto marks an untouched summary" "$(rd "$(meta Auto)")" "True/False"

curl -s -o /dev/null "http://127.0.0.1:$PORT/r/Auto/$ATS/0"
is "a manual uncheck sticks and is recorded" "$(rd "$(meta Auto)")" "False/True"

curl -s -o /dev/null "http://127.0.0.1:$PORT/r/Auto/$ATS/auto"
is "auto no longer overrides that choice" "$(rd "$(meta Auto)")" "False/True"

curl -s -o /dev/null "http://127.0.0.1:$PORT/r/Auto/$ATS/1"
is "but the checkbox still works" "$(rd "$(meta Auto)")" "True/True"

# The overview tick toggles without opening the summary.
OPAGE2="$(curl -sf "http://127.0.0.1:$PORT/all")"
like "overview has a tap target"  "$OPAGE2" "class=mark"
like "and it knows where to post" "$OPAGE2" "data-url='/r/"
like "the card body still links"  "$OPAGE2" "class=body href='/s/"

# Surface anything the server logged: a traceback here explains a page assertion that
# failed for no visible reason.
if [ -s "$TMP/server.log" ]; then
  printf '\n--- server log ---\n'; sed -n '1,40p' "$TMP/server.log"
fi

finish
