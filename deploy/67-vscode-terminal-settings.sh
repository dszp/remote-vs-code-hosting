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
# THE GRACE TIME: this script raises VSCODE_RECONNECTION_GRACE_TIME from its 3h default
# to 16h, via /etc/environment (pam_env) AND ~/.vscode-server/server-env-setup. Past the
# grace window the server disposes the parked session and the client can only offer
# "Reload Window" — so every overnight lid-close cost a reload. server-env-setup is the
# documented hook but the CLI server flow ignores it; /etc/environment is what actually
# works. A reboot does NOT count as applying it — only a server that starts after the
# change picks it up. See the section at the bottom for the full rationale and how to
# verify against the process table.
#
# NO PANEL ON STARTUP: `terminal.integrated.hideOnStartup: always`. Note this does NOT
# govern an extension force-revealing its own Output channel — some-extension does that on
# every activation when it can't reach n8n on 127.0.0.1:5678, and no setting suppresses
# it (it contributes only n8n.agent.* / n8n.tls.*). Disable that extension for the
# workspace, or give it an n8n to talk to.
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
  // Don't bring the panel up on window open/reload. Sessions live in Ghostty/Moshi
  // against herdr, so a terminal should appear only when asked for. Pairs with
  // RVC_AUTO_MUX=off, which stops the terminal that DOES open from auto-attaching.
  "terminal.integrated.hideOnStartup": "always",
  // Pass right-click to the terminal app (herdr's own tab menu) instead of VS Code's.
  "terminal.integrated.rightClickBehavior": "nothing",
  // Cap what the file watcher tracks — the VS Code half of the ENOSPC fix. The other
  // half raises fs.inotify.max_user_watches (deploy/10-base.sh). NOTE the glob is
  // "**/.git/objects/**", NOT "**/.git/**": excluding all of .git kills live SCM
  // decorations in the editor. Add your own globs freely; the deploy script only
  // inserts the ones below when they are missing and never rewrites yours.
  "files.watcherExclude": {
    "**/node_modules/**": true,
    "**/.git/objects/**": true,
    "**/dist/**": true,
    "**/.next/**": true,
    "**/build/**": true
  },
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
WATCH_KEY = "files.watcherExclude"

# Top-level scalar settings this script owns.
WANT_TOP = {
    "terminal.integrated.persistentSessionReviveProcess": "never",
    # Don't open the panel on window open/reload. Note this does NOT stop an
    # extension force-revealing its own Output channel (some-extension does exactly
    # that when it can't reach n8n) — no setting governs that; disable the
    # extension for the workspace instead.
    "terminal.integrated.hideOnStartup": "always",
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

# Glob -> inserted value text. The VS Code half of the ENOSPC fix (the kernel half is
# rvc_ensure_inotify_limits in deploy/lib.sh). "**/.git/objects/**" is deliberately
# narrower than "**/.git/**": excluding all of .git kills live SCM decorations.
WATCH_GLOBS = {
    "**/node_modules/**": "true",
    "**/.git/objects/**": "true",
    "**/dist/**": "true",
    "**/.next/**": "true",
    "**/build/**": "true",
}

# Every key whose VALUE is an object we merge into entry-by-entry, rather than a scalar
# we either set or leave alone. Entries missing from an existing object are inserted;
# entries already there — including hand-added ones — are never touched.
NESTED = {PROFILE_KEY: PROFILES, WATCH_KEY: WATCH_GLOBS}
NESTED_LABEL = {PROFILE_KEY: "terminal profiles", WATCH_KEY: "watcher excludes"}


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

# Present-and-an-object, per nested key. A key present but NOT an object is somebody's
# deliberate override of the whole thing (or a mistake); either way this script must not
# try to splice entries into it, so it is skipped and reported.
existing_nested = {}
unmergeable = []
for key in NESTED:
    if key not in data:
        existing_nested[key] = None
    elif isinstance(data[key], dict):
        existing_nested[key] = data[key]
    else:
        unmergeable.append(key)
for key in unmergeable:
    print(f"!! {path}: {key!r} is not an object — leaving it alone", file=sys.stderr)

mergeable = [k for k in NESTED if k not in unmergeable]
missing_nested = {
    k: [n for n in NESTED[k] if not (existing_nested[k] and n in existing_nested[k])]
    for k in mergeable
}
missing_top = [k for k in WANT_TOP if k not in data]

if not missing_top and not any(missing_nested.values()):
    counts = " + ".join(f"{len(NESTED[k])} {NESTED_LABEL[k]}" for k in NESTED)
    print(f">> {path}: all {len(WANT_TOP)} settings + {counts} already present — no change")
    sys.exit(0)


def insert_after_brace(text, at, block):
    """Insert block immediately after the '{' at index `at`."""
    return text[: at + 1] + block + text[at + 1 :]


new = raw

# 1. For each nested key: add the whole key if absent, else splice the missing entries
#    into the object that is already there.
added_nested = {}
for key in mergeable:
    miss = missing_nested[key]
    if not miss:
        continue
    body = ",\n".join(f'    "{name}": {NESTED[key][name]}' for name in miss)
    if existing_nested[key] is None:
        new = insert_after_brace(new, new.index("{"), f'\n  "{key}": {{\n{body}\n  }},')
    else:
        kpos = new.index(f'"{key}"')
        brace = new.index("{", kpos + len(key))
        new = insert_after_brace(new, brace, f"\n{body},")
    added_nested[key] = miss

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
if any(k not in check for k in WANT_TOP):
    print(f"!! {path}: generated file missing expected keys — NOT writing", file=sys.stderr)
    sys.exit(1)
for key in mergeable:
    if not isinstance(check.get(key), dict):
        print(f"!! {path}: generated file missing {key!r} — NOT writing", file=sys.stderr)
        sys.exit(1)
    for name in NESTED[key]:
        if name not in check[key]:
            print(f"!! {path}: generated file missing {key} entry {name!r} — NOT writing", file=sys.stderr)
            sys.exit(1)
# Nothing that already existed may have changed value. Nested keys are compared
# entry-by-entry below, since adding an entry legitimately changes the object.
for k, v in data.items():
    if k in NESTED:
        continue
    if check.get(k) != v:
        print(f"!! {path}: key {k!r} would change value — NOT writing", file=sys.stderr)
        sys.exit(1)
for key in mergeable:
    for k, v in (existing_nested[key] or {}).items():
        if check[key].get(k) != v:
            print(f"!! {path}: {key} entry {k!r} would change — NOT writing", file=sys.stderr)
            sys.exit(1)

bak = path.with_suffix(path.suffix + ".bak." + time.strftime("%Y%m%d%H%M%S"))
shutil.copy2(path, bak)
path.write_text(new)

what = []
for k in missing_top:
    what.append(f"{k}={WANT_TOP[k]}")
for key, names in added_nested.items():
    what.append(f"{key}: " + ", ".join(repr(n) for n in names))
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
    echo ">> $f: created with 3 settings + 5 watcher excludes + 4 terminal profiles"
    return
  fi

  merge_settings "$f" || return 0
  chown "$DEV_USER:$DEV_USER" "$f"; chmod 644 "$f"
}

for f in "${FILES[@]}"; do ensure_setting "$f"; done

# ---- reconnection grace time ----------------------------------------------
# Close the laptop and the SSH socket dies. The server parks the extension host and
# terminals for a grace period, then DISPOSES them — after which the client has
# nothing to reattach to and can only offer "Reload Window". The default is 3h, so
# any overnight sleep loses the session. remoteagent.log records it verbatim as:
#   "The reconnection grace time of 3h has expired, so the connection will be disposed."
#
# 16h covers a lid closed overnight while still reclaiming the extension hosts when
# the machine is genuinely abandoned for a day — the grace window is exactly what
# keeps those processes (and their RAM) alive, so this trades against the swap
# pressure from long-lived VS Code server processes (deploy/95-swap-monitor.sh).
#
# WHERE THE VARIABLE HAS TO GO — /etc/environment, NOT server-env-setup alone.
# `server-env-setup` is the documented hook and is sourced by the LEGACY bootstrap
# (~/.vscode-server/bin/<hash>/server.sh). This host gets the CLI flow instead —
# `code-<hash> command-shell` -> cli/servers/Stable-<hash>/server/bin/code-server —
# which never reads it: nothing under ~/.vscode-server so much as mentions the file,
# and a server started that way has the variable absent from its environment while
# handing its own 10800000 default down to the extension hosts. Measured, not assumed:
#     for p in $(pgrep -f '\.vscode-server'); do
#       tr '\0' '\n' < /proc/$p/environ | grep RECONNECTION_GRACE; done
# The server inherits the SSH session's environment, so the injection point that works
# is pam_env — sshd here is `usepam yes` / `permituserenvironment no`, which rules out
# ~/.ssh/environment without loosening the hardening in config/sshd_hardening.conf.
# Both are written: /etc/environment is what actually takes effect today, and
# server-env-setup costs nothing and starts working for free if VS Code ever wires it
# into the CLI flow.
#
# IT ONLY APPLIES TO A SERVER THAT STARTS AFTERWARDS. A reconnect reuses a running
# server ("Found running server (pid=…)" in ~/.vscode-server/.cli.<hash>.log), and
# "Kill VS Code Server on Host" is a no-op while another window is still attached, so
# the old grace time can survive several apparent restarts. Verify against the process
# table, never against the file.
GRACE_MS="${GRACE_MS:-57600000}"   # 16h. VS Code default is 10800000 (3h).

# pam_env parses KEY=VALUE only — no `export`, no shell syntax. Rewrite in place so a
# changed GRACE_MS updates rather than appending a second, shadowed line.
ETC_ENV="${ETC_ENV:-/etc/environment}"
touch "$ETC_ENV"
if grep -q '^VSCODE_RECONNECTION_GRACE_TIME=' "$ETC_ENV"; then
  sed -i "s|^VSCODE_RECONNECTION_GRACE_TIME=.*|VSCODE_RECONNECTION_GRACE_TIME=$GRACE_MS|" "$ETC_ENV"
else
  printf 'VSCODE_RECONNECTION_GRACE_TIME=%s\n' "$GRACE_MS" >> "$ETC_ENV"
fi
echo ">> $ETC_ENV: VSCODE_RECONNECTION_GRACE_TIME=$GRACE_MS (pam_env; needs a NEW server)"

# server-env-setup must stay SILENT: anything on stdout corrupts the connection
# handshake. It lives under ~/.vscode-server, which is exactly what a "delete it and
# let it reinstall" fix wipes — hence managing it here rather than leaving it hand-made.
ENV_SETUP="$HOME_DIR/.vscode-server/server-env-setup"
install -d -o "$DEV_USER" -g "$DEV_USER" "$(dirname "$ENV_SETUP")"
install -o "$DEV_USER" -g "$DEV_USER" -m 0644 /dev/stdin "$ENV_SETUP" <<ENVSETUP
# Managed by remote-vs-code deploy/67-vscode-terminal-settings.sh.
# Sourced by VS Code Remote-SSH before the server starts. Keep it SILENT —
# anything written to stdout here can corrupt the connection handshake.
export VSCODE_RECONNECTION_GRACE_TIME=$GRACE_MS
ENVSETUP
if out="$(bash -c ". '$ENV_SETUP'" 2>&1)" && [ -z "$out" ]; then
  echo ">> $ENV_SETUP: grace time ${GRACE_MS}ms ($((GRACE_MS/3600000))h), silent on stdout"
else
  echo "!! $ENV_SETUP produced output or failed — Remote-SSH may not connect: $out" >&2
  exit 1
fi

echo ">> done. Reload VS Code / reconnect for it to take effect (see header for how to verify)."
echo ">> NOTE: the grace time applies at SERVER start, not window reload — run"
echo "   'Remote-SSH: Kill VS Code Server on Host' to pick it up now."
