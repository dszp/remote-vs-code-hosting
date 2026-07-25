#!/usr/bin/env bash
# The VS Code half of the reconnect story (65-auto-attach.sh is the shell half),
# plus the terminal PROFILES that let you pick a multiplexer per tab.
#
# THE RACE: after the laptop is off for hours the Remote-SSH link fully drops and the
# VS Code server / pty host on the VM is torn down. On reconnect VS Code *revives*
# (re-creates) the dead terminal processes; each revived shell re-runs ~/.bashrc, whose
# auto-attach (65-auto-attach.sh) grabs the base session '<folder>' FIRST — so the
# Claude-extension terminal, launching a beat later, hits the anti-hijack path and lands
# on '<folder>-2'. You then have to exit and `cs <folder>` back to the original.
#
# THE FIX: set `terminal.integrated.persistentSessionReviveProcess: never` so VS Code
# does NOT re-create a killed terminal process — the tab returns as static history
# instead of a fresh shell that re-runs .bashrc and races. This is deliberately the
# *soft* switch: `enablePersistentSessions` is left at its default (true), so the
# RECONNECT path (process still alive — a plain Reload Window, or a short blip where
# the server stayed up) still reattaches terminals to their live, multiplexer-backed
# shells. Only the REVIVE path (process was actually killed) is disabled — exactly the
# case that spawned the '-2'. Durable work lives in tmux/herdr, so it is unaffected.
#
# RIGHT-CLICK: `terminal.integrated.rightClickBehavior: nothing` passes right-click to
# the terminal app. herdr's tab context menu (New tab / Rename / Close) was being drawn
# UNDER VS Code's own Copy/Paste/Kill Terminal menu. Costs the VS Code terminal context
# menu in every integrated terminal; keyboard copy/paste is unaffected.
#
# THE PROFILES: four entries in `terminal.integrated.profiles.linux`, so the terminal
# "+" dropdown can override ~/.config/remote-vs-code/mux.env for ONE tab (a profile's
# env beats the file — see 65-auto-attach.sh):
#   shell (no tmux)       NO_AUTO_TMUX=1  -> a plain shell, no multiplexer
#   tmux: new session     runs `cs -n`    -> a new independent tmux session
#   herdr                 RVC_AUTO_MUX=herdr
#   tmux: folder session  RVC_AUTO_MUX=tmux
# The default "+" is untouched and still follows mux.env.
#
# TWO client surfaces, both MACHINE-scoped and both VM-side (these settings default to
# window scope, which is settable at machine level):
#   - native Remote-SSH server -> ~/.vscode-server/data/Machine/settings.json
#   - code-server (browser IDE) -> ~/.local/share/code-server/Machine/settings.json
#
# WHY NOT jq: these files are JSONC — VS Code allows `//` comments, and this repo puts
# real commentary in them (the files.watcherExclude rationale, for one). jq cannot parse
# that, and a jq rewrite would silently strip every comment. So this script parses a
# comment-STRIPPED copy only to decide what is missing, then inserts the missing keys
# TEXTUALLY into the original bytes. Existing content, formatting, and comments survive
# untouched. It merges per-profile, so hand-added profiles are never dropped.
#
# Idempotent & non-destructive: creates the file if absent; only inserts keys/profiles
# that are missing; leaves existing values alone (respects hand-edits); backs up before
# any write; validates the result parses as JSON before replacing the file, and refuses
# to write if it does not. Best run AFTER you've connected via each client at least
# once, so the data dirs already exist.
#
# RUN ON: the VM.
#   ./deploy/run-remote.sh __VM_NAME__ deploy/67-vscode-terminal-settings.sh DEV_USER=__DEV_USER__
#
# To VERIFY the revive setting: a plain Reload Window won't show a difference (that's the
# reconnect path). Fully CLOSE the VS Code window/app and reopen connected to the VM —
# closing is what triggers process shutdown, so the revive-vs-not path runs; the terminal
# should come back inert and the Claude extension should claim the base session, not '-2'.
# To verify the profiles: terminal "+" dropdown should list all four.
set -euo pipefail

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="${HOME_DIR:-/home/$DEV_USER}"   # overridable so the merge can be tested off to the side

command -v python3 >/dev/null 2>&1 || { echo "!! python3 not found — install python3 first" >&2; exit 1; }

FILES=(
  "$HOME_DIR/.vscode-server/data/Machine/settings.json"          # native Remote-SSH
  "$HOME_DIR/.local/share/code-server/Machine/settings.json"     # code-server (browser)
)

# What a from-scratch file looks like (comments included — VS Code reads JSONC).
FRESH_JSON=$(cat <<'JSONC'
{
  // Managed by remote-vs-code deploy/67-vscode-terminal-settings.sh. Safe to edit and
  // to add your own keys — the script only inserts what is missing and never rewrites
  // or strips what is already here.
  "terminal.integrated.persistentSessionReviveProcess": "never",
  // Pass right-click to the terminal app (herdr's own tab menu) instead of VS Code's.
  "terminal.integrated.rightClickBehavior": "nothing",
  "terminal.integrated.profiles.linux": {
    "shell (no tmux)": {
      "path": "bash",
      "args": ["-l"],
      "env": { "NO_AUTO_TMUX": "1" }
    },
    "tmux: new session": {
      "path": "/usr/local/bin/cs",
      "args": ["-n"]
    },
    "herdr": {
      "path": "bash",
      "args": ["-l"],
      "env": { "RVC_AUTO_MUX": "herdr" }
    },
    "tmux: folder session": {
      "path": "bash",
      "args": ["-l"],
      "env": { "RVC_AUTO_MUX": "tmux" }
    }
  }
}
JSONC
)

merge_settings() {
  local f="$1"
  python3 - "$f" <<'PY'
import json, pathlib, shutil, sys, time

path = pathlib.Path(sys.argv[1])
raw = path.read_text()

PROFILE_KEY = "terminal.integrated.profiles.linux"

# Top-level scalar settings this script owns.
WANT_TOP = {
    "terminal.integrated.persistentSessionReviveProcess": "never",
    # Pass right-click to the terminal app instead of showing VS Code's own context
    # menu. Required for a mouse-aware TUI like herdr: right-clicking a herdr tab opens
    # herdr's New tab / Rename / Close menu, but VS Code drew its Copy/Paste/Kill
    # Terminal menu on top of it. Tradeoff: no VS Code terminal context menu in ANY
    # integrated terminal (keyboard copy/paste still work). Revert by setting this to
    # "default".
    "terminal.integrated.rightClickBehavior": "nothing",
}

# Profile name -> the exact text inserted for it (4-space body indent to match VS Code's
# own formatting). Order here is the order they get inserted.
PROFILES = {
    "shell (no tmux)": '{\n      "path": "bash",\n      "args": ["-l"],\n      "env": { "NO_AUTO_TMUX": "1" }\n    }',
    "tmux: new session": '{\n      "path": "/usr/local/bin/cs",\n      "args": ["-n"]\n    }',
    "herdr": '{\n      "path": "bash",\n      "args": ["-l"],\n      "env": { "RVC_AUTO_MUX": "herdr" }\n    }',
    "tmux: folder session": '{\n      "path": "bash",\n      "args": ["-l"],\n      "env": { "RVC_AUTO_MUX": "tmux" }\n    }',
}


def strip_comments(s):
    """Remove // and /* */ comments, but never inside string literals."""
    out, i, n, instr, esc = [], 0, len(s), False, False
    while i < n:
        c = s[i]
        if instr:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                instr = False
            i += 1
            continue
        if c == '"':
            instr = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and s[i + 1] == "/":
            while i < n and s[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and s[i + 1] == "*":
            i += 2
            while i + 1 < n and not (s[i] == "*" and s[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def parse(text):
    return json.loads(strip_comments(text))


try:
    data = parse(raw)
except Exception as e:
    print(f"!! {path}: cannot parse even after stripping comments ({e}) — NOT modifying", file=sys.stderr)
    sys.exit(1)
if not isinstance(data, dict):
    print(f"!! {path}: top level is not an object — NOT modifying", file=sys.stderr)
    sys.exit(1)

existing_profiles = data.get(PROFILE_KEY) if isinstance(data.get(PROFILE_KEY), dict) else None
missing_profiles = [p for p in PROFILES if not (existing_profiles and p in existing_profiles)]
missing_top = [k for k in WANT_TOP if k not in data]
need_profile_key = PROFILE_KEY not in data

if not missing_top and not missing_profiles:
    print(f">> {path}: all {len(WANT_TOP)} settings + {len(PROFILES)} profiles already present — no change")
    sys.exit(0)


def insert_after_brace(text, at, block):
    """Insert block immediately after the '{' at index `at`."""
    return text[: at + 1] + block + text[at + 1 :]


new = raw

# 1. Missing whole profiles key, or missing individual profiles inside an existing one.
if need_profile_key:
    body = ",\n".join(f'    "{name}": {PROFILES[name]}' for name in PROFILES)
    block = f'\n  "{PROFILE_KEY}": {{\n{body}\n  }},'
    top = new.index("{")
    new = insert_after_brace(new, top, block)
    added_profiles = list(PROFILES)
elif missing_profiles:
    kpos = new.index(f'"{PROFILE_KEY}"')
    brace = new.index("{", kpos + len(PROFILE_KEY))
    body = ",\n".join(f'    "{name}": {PROFILES[name]}' for name in missing_profiles)
    new = insert_after_brace(new, brace, f"\n{body},")
    added_profiles = missing_profiles
else:
    added_profiles = []

# 2. Missing top-level scalar settings.
for k in missing_top:
    top = new.index("{")
    new = insert_after_brace(new, top, f'\n  "{k}": {json.dumps(WANT_TOP[k])},')

# 3. Validate before replacing anything.
try:
    check = parse(new)
except Exception as e:
    print(f"!! {path}: generated file does not parse ({e}) — NOT writing", file=sys.stderr)
    sys.exit(1)
if PROFILE_KEY not in check or any(k not in check for k in WANT_TOP):
    print(f"!! {path}: generated file missing expected keys — NOT writing", file=sys.stderr)
    sys.exit(1)
for name in PROFILES:
    if name not in check[PROFILE_KEY]:
        print(f"!! {path}: generated file missing profile {name!r} — NOT writing", file=sys.stderr)
        sys.exit(1)
# Nothing that already existed may have changed value.
for k, v in data.items():
    if k == PROFILE_KEY:
        continue
    if check.get(k) != v:
        print(f"!! {path}: key {k!r} would change value — NOT writing", file=sys.stderr)
        sys.exit(1)
if existing_profiles:
    for k, v in existing_profiles.items():
        if check[PROFILE_KEY].get(k) != v:
            print(f"!! {path}: profile {k!r} would change — NOT writing", file=sys.stderr)
            sys.exit(1)

bak = path.with_suffix(path.suffix + ".bak." + time.strftime("%Y%m%d%H%M%S"))
shutil.copy2(path, bak)
path.write_text(new)

what = []
for k in missing_top:
    what.append(f"{k}={WANT_TOP[k]}")
if added_profiles:
    what.append("profiles: " + ", ".join(repr(p) for p in added_profiles))
print(f">> {path}: added {'; '.join(what)} (backup: {bak.name})")
PY
}

ensure_setting() {
  local f="$1" dir
  dir="$(dirname "$f")"
  # Create any missing dirs owned by the dev user (existing ones are left untouched),
  # so we never leave a root-owned ~/.vscode-server that the VS Code server can't use.
  install -d -o "$DEV_USER" -g "$DEV_USER" "$dir"

  if [ ! -s "$f" ]; then
    printf '%s\n' "$FRESH_JSON" > "$f"
    chown "$DEV_USER:$DEV_USER" "$f"; chmod 644 "$f"
    echo ">> $f: created with 2 settings + 4 terminal profiles"
    return
  fi

  merge_settings "$f" || return 0
  chown "$DEV_USER:$DEV_USER" "$f"; chmod 644 "$f"
}

for f in "${FILES[@]}"; do ensure_setting "$f"; done
echo ">> done. Reload VS Code / reconnect for it to take effect (see header for how to verify)."
