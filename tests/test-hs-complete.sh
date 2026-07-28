#!/usr/bin/env bash
# _hs_complete: directories + session names + verbs, degrading to dirs on failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SRC="$PWD/../deploy/build/complete.sh"   # extracted via HS_COMPLETE_COPY
[ -r "$SRC" ] || { printf 'missing %s\n' "$SRC" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export PATH="$TMP/bin:$PATH"
make_stub_herdr "$TMP/bin"
export HS_STUB_JSON="$TMP/sessions.json"
cat > "$HS_STUB_JSON" <<'JSON'
{"sessions":[
 {"default":false,"name":"Live","running":true},
 {"default":false,"name":"Dead","running":false}
]}
JSON

mkdir -p "$TMP/work/Litmus" "$TMP/work/Other"
cd "$TMP/work"
. "$SRC"

# Drive the completion the way bash would.
comp() { # $1 = current word, $2.. = preceding words
  local cur="$1"; shift
  COMP_WORDS=(hs "$@" "$cur")
  COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
  COMPREPLY=()
  _hs_complete
  printf '%s\n' "${COMPREPLY[@]:-}"
}

out="$(comp L)"
like "completes directories"   "$out" "Litmus"
like "completes session names" "$out" "Live"

out="$(comp "")"
like "offers verbs" "$out" "ls"
like "offers k"     "$out" "k"

# After `hs rm`, only stopped sessions make sense.
out="$(comp "" rm)"
like   "rm offers stopped" "$out" "Dead"
unlike "rm hides running"  "$out" "Live"

# No duplicate entries when a directory and a session share a name.
mkdir -p "$TMP/work/Live"
is "deduped" "$(comp Live | grep -cx 'Live')" "1"

# A broken herdr must not break Tab — directories still complete.
cat > "$TMP/bin/herdr" <<'BAD'
#!/usr/bin/env bash
echo "boom" >&2; exit 1
BAD
chmod +x "$TMP/bin/herdr"
out="$(comp L)"
like   "degrades to dirs"        "$out" "Litmus"
unlike "no sessions when broken" "$out" "Dead"

finish
