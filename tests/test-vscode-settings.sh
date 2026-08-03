#!/usr/bin/env bash
# deploy/67-vscode-terminal-settings.sh — the JSONC merge into the Machine settings.
# Focus: files.watcherExclude (the VS Code half of the ENOSPC fix; the kernel half is
# tests/test-inotify-sysctl.sh). Also pins the existing profile/scalar merge it rides on.
#
# Runs the REAL script against a throwaway HOME_DIR as the current user, so no root and
# nothing touches the real ~/.vscode-server.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SCRIPT="../deploy/67-vscode-terminal-settings.sh"
[ -r "$SCRIPT" ] || { printf 'missing %s\n' "$SCRIPT" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NATIVE_REL=".vscode-server/data/Machine/settings.json"
SERVER_REL=".local/share/code-server/Machine/settings.json"

# Run the script against a fresh fake home. $1 (optional) = seed content for the native file.
run_script() { # [seed_json]
  rm -rf "$TMP/home"
  mkdir -p "$TMP/home"
  if [ $# -ge 1 ]; then
    mkdir -p "$TMP/home/$(dirname "$NATIVE_REL")"
    printf '%s' "$1" > "$TMP/home/$NATIVE_REL"
  fi
  # ETC_ENV MUST be redirected: unset, the script writes the real /etc/environment.
  HOME_DIR="$TMP/home" DEV_USER="$(id -un)" ETC_ENV="$TMP/etcenv" \
    bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
}

NATIVE() { printf '%s' "$TMP/home/$NATIVE_REL"; }

# Read a value out of a JSONC file:  jget <file> [top-key] [sub-key]
# Missing key -> empty string. No args beyond the file -> parse-only (exit 1 if invalid).
jget() {
  python3 - "$@" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
# The script's own comment stripper is string-aware; this is enough for test fixtures.
out, i, n, instr, esc = [], 0, len(raw), False, False
while i < n:
    c = raw[i]
    if instr:
        out.append(c)
        if esc: esc = False
        elif c == "\\": esc = True
        elif c == '"': instr = False
        i += 1; continue
    if c == '"': instr = True; out.append(c); i += 1; continue
    if c == "/" and i + 1 < n and raw[i+1] == "/":
        while i < n and raw[i] != "\n": i += 1
        continue
    out.append(c); i += 1
d = json.loads("".join(out))
v = d
for key in sys.argv[2:]:
    v = v.get(key) if isinstance(v, dict) else None
print("" if v is None else (json.dumps(v) if isinstance(v, (dict, list)) else v))
PY
}

WE="files.watcherExclude"

# --- a fresh file gets the key with every glob --------------------------------------
run_script
is "fresh: node_modules excluded"  "$(jget "$(NATIVE)" "$WE" '**/node_modules/**')"   "True"
is "fresh: .git/objects excluded"  "$(jget "$(NATIVE)" "$WE" '**/.git/objects/**')"   "True"
is "fresh: dist excluded"          "$(jget "$(NATIVE)" "$WE" '**/dist/**')"           "True"
is "fresh: .next excluded"         "$(jget "$(NATIVE)" "$WE" '**/.next/**')"          "True"
is "fresh: build excluded"         "$(jget "$(NATIVE)" "$WE" '**/build/**')"          "True"
# Excluding all of .git kills live SCM decorations — the whole point of the narrower glob.
is "fresh: does NOT exclude all of .git" "$(jget "$(NATIVE)" "$WE" '**/.git/**')"     ""
# code-server is the second client surface and must get the same treatment.
is "fresh: code-server file too" \
   "$(jget "$TMP/home/$SERVER_REL" "$WE" '**/node_modules/**')" "True"

# --- an existing file without the key gets it inserted -------------------------------
run_script '{
  // a hand-written file
  "editor.fontSize": 14
}'
is "existing file: key inserted"      "$(jget "$(NATIVE)" "$WE" '**/node_modules/**')" "True"
is "existing file: own keys survive"  "$(jget "$(NATIVE)" 'editor.fontSize')"      "14"
like "existing file: comments survive" "$(cat "$(NATIVE)")" "a hand-written file"

# --- a hand-added glob is never dropped, and missing ones are filled in --------------
run_script '{
  "files.watcherExclude": {
    "**/my-huge-cache/**": true,
    "**/node_modules/**": true
  }
}'
is "partial: hand-added glob survives" "$(jget "$(NATIVE)" "$WE" '**/my-huge-cache/**')" "True"
is "partial: missing glob added"       "$(jget "$(NATIVE)" "$WE" '**/dist/**')"          "True"
is "partial: pre-existing glob kept"   "$(jget "$(NATIVE)" "$WE" '**/node_modules/**')"  "True"

# --- an existing glob set to false is a deliberate opt-out, never rewritten ----------
run_script '{
  "files.watcherExclude": {
    "**/dist/**": false
  }
}'
is "opt-out: false is left alone" "$(jget "$(NATIVE)" "$WE" '**/dist/**')" "False"
is "opt-out: others still added"  "$(jget "$(NATIVE)" "$WE" '**/build/**')" "True"
# A re-inserted entry would be a duplicate JSON key: the parser takes the last one, so
# the value check above still passes while the file quietly grows a shadowed dupe.
is "opt-out: glob is not inserted a second time" \
   "$(grep -c -F -- '"**/dist/**"' "$(NATIVE)")" "1"

# --- everything already present: reports no change ----------------------------------
run_script
before="$(cat "$(NATIVE)")"
HOME_DIR="$TMP/home" DEV_USER="$(id -un)" ETC_ENV="$TMP/etcenv" bash "$SCRIPT" >"$TMP/out2" 2>&1
is   "second run: file byte-for-byte unchanged" "$(cat "$(NATIVE)")" "$before"
like "second run: says no change"               "$(cat "$TMP/out2")" "no change"

# --- hideOnStartup: the panel must not come up on window open ------------------------
run_script
is "hideOnStartup inserted" "$(jget "$(NATIVE)" 'terminal.integrated.hideOnStartup')" "always"
# A hand-set value must survive, like every other key this script merges.
run_script '{ "terminal.integrated.hideOnStartup": "never" }'
is "hideOnStartup: hand-set value respected" \
   "$(jget "$(NATIVE)" 'terminal.integrated.hideOnStartup')" "never"

# --- server-env-setup: the reconnection grace time -----------------------------------
ENVF="$TMP/home/.vscode-server/server-env-setup"
run_script
if [ -f "$ENVF" ]; then ok "server-env-setup created"; else fail "server-env-setup created" "missing $ENVF"; fi
like "grace time is 16h in ms" "$(cat "$ENVF")" "VSCODE_RECONNECTION_GRACE_TIME=57600000"
# It is SOURCED by Remote-SSH before the server starts — anything on stdout corrupts
# the connection handshake, so silence is the load-bearing property here.
is "server-env-setup is silent on stdout" "$(bash -c ". '$ENVF'")" ""
is "it actually exports the variable" \
   "$(bash -c ". '$ENVF'; printf %s \"\$VSCODE_RECONNECTION_GRACE_TIME\"")" "57600000"
# Overridable, so a shorter window can be chosen without editing the script.
GRACE_MS=3600000 HOME_DIR="$TMP/home" DEV_USER="$(id -un)" ETC_ENV="$TMP/etcenv" bash "$SCRIPT" >/dev/null 2>&1
like "GRACE_MS override honored" "$(cat "$ENVF")" "GRACE_TIME=3600000"

# --- /etc/environment: the copy that ACTUALLY takes effect ---------------------------
# server-env-setup above is the documented hook, but the CLI server flow
# (code-<hash> command-shell -> cli/servers/…/bin/code-server) never sources it — a
# server started that way has the variable absent from its environment. The server
# inherits the SSH session env instead, so pam_env is the injection point that works.
rm -f "$TMP/etcenv"; run_script
like "etc/environment: variable written" "$(cat "$TMP/etcenv")" "VSCODE_RECONNECTION_GRACE_TIME=57600000"
# pam_env parses KEY=VALUE ONLY. An `export` prefix makes the line silently useless.
unlike "etc/environment: no shell syntax" "$(cat "$TMP/etcenv")" "export"
# Changing the value must REWRITE the line. Appending leaves two, and pam_env takes the
# first — so the new value would be silently shadowed by the old one.
GRACE_MS=3600000 HOME_DIR="$TMP/home" DEV_USER="$(id -un)" ETC_ENV="$TMP/etcenv" bash "$SCRIPT" >/dev/null 2>&1
is "etc/environment: rewritten, not appended" "$(grep -c RECONNECTION_GRACE "$TMP/etcenv")" "1"
like "etc/environment: new value took"        "$(cat "$TMP/etcenv")" "GRACE_TIME=3600000"
# It is a shared system file — unrelated entries must survive.
printf 'SOME_OTHER_VAR=keepme\nVSCODE_RECONNECTION_GRACE_TIME=1\n' > "$TMP/etcenv"
run_script
like "etc/environment: unrelated lines kept" "$(cat "$TMP/etcenv")" "SOME_OTHER_VAR=keepme"
is   "etc/environment: still only one entry" "$(grep -c RECONNECTION_GRACE "$TMP/etcenv")" "1"

# --- the result is always valid JSONC ------------------------------------------------
run_script '{ "editor.fontSize": 14 }'
if jget "$(NATIVE)" >/dev/null 2>&1; then ok "output parses as JSONC"
else fail "output parses as JSONC" "$(cat "$(NATIVE)")"; fi

printf '\n%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
