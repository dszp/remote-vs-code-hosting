#!/usr/bin/env bash
# herdr's own config: ~/.config/herdr/config.toml — keybindings and UI options.
#
# WHY THIS EXISTS: herdr ships several navigation actions UNBOUND (`menu` -> `keybinds`
# shows them as `unset`): previous/next workspace, switch workspace 1-9, previous/next
# agent, focus agent 1-9. On a box where every project gets its own space and several
# agents run at once, those are exactly the keys you need, and rebinding them by hand on
# a fresh VM is the kind of thing nobody remembers. This makes them reproducible.
#
# It also binds rename-workspace. There is deliberately NO rename-agent binding here:
# `keys.rename_agent` is not a real config key — `herdr config check` rejects it with
# "unknown config key keys.rename_agent; ignoring key" — so agent names are CLI-only.
# The `hn` helper from deploy/65-auto-attach.sh covers that gap.
#
# KEY CHOICES avoid what herdr already binds: c = new tab, shift+t = rename tab, p/n =
# prev/next tab, 1..9 = switch tab, shift+x = close tab, shift+d = close workspace,
# w = navigate mode. prefix stays the default ctrl+b. prefix+, for rename-workspace
# mirrors tmux's rename-window, which is already muscle memory.
#
# NON-DESTRUCTIVE, and it matters here: this file gets hand-edited (agent_panel_sort,
# theme choices, experiments). TOML also carries `#` comments that a naive rewrite would
# strip. So the script parses the file with tomllib ONLY to decide which of its own keys
# are absent, then inserts just those, textually, into the original bytes. Existing keys,
# values, ordering and comments are left exactly as they were — an existing value is never
# overwritten, so your edits win.
#
# SAFETY NET: herdr validates its own config, so we run `herdr config check` before and
# after writing (via HERDR_CONFIG_PATH, so it inspects THIS file rather than whatever the
# default path holds) and RESTORE THE BACKUP if our write is what broke it. Problems that
# predate the run are reported but not rolled back — reverting them would fix nothing.
#
# Takes effect via `herdr server reload-config`, which the script runs for every running
# session server (each named session has its own). Keybindings apply without a restart.
#
# RUN ON: the VM. run-remote sudo's; we write the dev user's config.
#   ./deploy/run-remote.sh __VM_NAME__ deploy/68-herdr-config.sh DEV_USER=__DEV_USER__
set -euo pipefail

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="${HOME_DIR:-/home/$DEV_USER}"   # overridable so the merge can be tested off to the side
HERDR_BIN="${HERDR_BIN:-$HOME_DIR/.local/bin/herdr}"
CONF_DIR="$HOME_DIR/.config/herdr"
CONF="$CONF_DIR/config.toml"

command -v python3 >/dev/null 2>&1 || { echo "!! python3 not found — install python3 first" >&2; exit 1; }
if [ ! -x "$HERDR_BIN" ]; then
  echo ">> herdr not installed at $HERDR_BIN — nothing to configure"
  exit 0
fi

install -d -o "$DEV_USER" -g "$DEV_USER" -m 0755 "$CONF_DIR"

# Was the config already unhappy before we touched it? If so a post-write complaint is
# not ours, and rolling back our (valid) additions would be the wrong call.
was_dirty=0
if [ -s "$CONF" ]; then
  if ! pre="$(sudo -u "$DEV_USER" HERDR_CONFIG_PATH="$CONF" "$HERDR_BIN" config check 2>&1)" || printf '%s' "$pre" | grep -q 'issues found'; then
    was_dirty=1
    echo "!! note: config.toml ALREADY has issues before this run:" >&2
    printf '%s\n' "$pre" | sed 's/^/     /' >&2
  fi
fi

# From-scratch file, comments included.
FRESH_TOML=$(cat <<'TOML'
# herdr configuration — managed by remote-vs-code deploy/68-herdr-config.sh.
# Safe to edit: the deploy script only ADDS keys it owns that are missing, and never
# overwrites a value you have changed. `herdr config check` validates; the script
# restores a backup if a write would break it.

[ui]
# Show agent names on pane borders, so `hn <name>` is visible where you're working.
show_agent_labels_on_pane_borders = true

[keys]
# prefix stays the default ctrl+b. These six ship UNSET; the rest of herdr's defaults
# already cover tabs (c, shift+t, p, n, 1..9, shift+x) and workspaces (shift+d, w).
next_workspace     = "prefix+l"
previous_workspace = "prefix+h"
switch_workspace   = "prefix+shift+1..9"
next_agent         = "prefix+]"
previous_agent     = "prefix+["
focus_agent        = "prefix+alt+1..9"
# prefix+, matches tmux rename-window. NOTE: there is no rename_agent key in herdr —
# `config check` rejects it. Use the `hn` helper (deploy/65-auto-attach.sh) instead.
rename_workspace   = "prefix+,"
TOML
)

if [ ! -s "$CONF" ]; then
  printf '%s\n' "$FRESH_TOML" > "$CONF"
  chown "$DEV_USER:$DEV_USER" "$CONF"; chmod 644 "$CONF"
  echo ">> $CONF: created with [ui] + 7 keybindings"
else
  python3 - "$CONF" <<'PY'
import pathlib, shutil, sys, time

try:
    import tomllib
except ModuleNotFoundError:  # python < 3.11
    print("!! python3 lacks tomllib (needs 3.11+) — NOT modifying config.toml", file=sys.stderr)
    sys.exit(1)

path = pathlib.Path(sys.argv[1])
raw = path.read_text()

# table -> {key: literal TOML value text}. Only these are owned; anything else in the
# file is somebody's deliberate choice and is never touched.
WANT = {
    "ui": {
        "show_agent_labels_on_pane_borders": "true",
    },
    "keys": {
        "next_workspace": '"prefix+l"',
        "previous_workspace": '"prefix+h"',
        "switch_workspace": '"prefix+shift+1..9"',
        "next_agent": '"prefix+]"',
        "previous_agent": '"prefix+["',
        "focus_agent": '"prefix+alt+1..9"',
        "rename_workspace": '"prefix+,"',
    },
}

try:
    data = tomllib.loads(raw)
except Exception as e:
    print(f"!! {path}: not valid TOML ({e}) — NOT modifying", file=sys.stderr)
    sys.exit(1)

missing = {
    table: [k for k in keys if k not in (data.get(table) or {})]
    for table, keys in WANT.items()
}
missing = {t: ks for t, ks in missing.items() if ks}

if not missing:
    print(f">> {path}: all owned keys already present — no change")
    sys.exit(0)

new = raw
for table, keys in missing.items():
    block = "\n".join(f"{k} = {WANT[table][k]}" for k in keys)
    header = f"[{table}]"
    idx = new.find(header)
    if idx == -1:
        # Table absent: append it whole at the end.
        if not new.endswith("\n"):
            new += "\n"
        new += f"\n{header}\n{block}\n"
    else:
        # Table present: insert right after its header line, so comments and existing
        # keys below stay put.
        eol = new.find("\n", idx)
        if eol == -1:
            new += f"\n{block}\n"
        else:
            new = new[: eol + 1] + block + "\n" + new[eol + 1 :]

# Must still parse, must now contain everything, and must not have altered any existing
# key's value.
try:
    check = tomllib.loads(new)
except Exception as e:
    print(f"!! {path}: generated TOML does not parse ({e}) — NOT writing", file=sys.stderr)
    sys.exit(1)
for table, keys in WANT.items():
    for k, v in keys.items():
        if k not in (check.get(table) or {}):
            print(f"!! {path}: generated file missing {table}.{k} — NOT writing", file=sys.stderr)
            sys.exit(1)
def flat(d):
    out = {}
    for k, v in d.items():
        if isinstance(v, dict):
            for k2, v2 in v.items():
                out[f"{k}.{k2}"] = v2
        else:
            out[k] = v
    return out
before, after = flat(data), flat(check)
for k, v in before.items():
    if after.get(k) != v:
        print(f"!! {path}: {k} would change value — NOT writing", file=sys.stderr)
        sys.exit(1)

bak = path.with_suffix(path.suffix + ".bak." + time.strftime("%Y%m%d%H%M%S"))
shutil.copy2(path, bak)
path.write_text(new)
added = "; ".join(f"{t}: {', '.join(ks)}" for t, ks in missing.items())
print(f">> {path}: added {added} (backup: {bak.name})")
PY
  chown "$DEV_USER:$DEV_USER" "$CONF"; chmod 644 "$CONF"
fi

# Let herdr judge its own config. Roll back only if WE broke it — a config that was
# already complaining keeps our additions, since reverting them would fix nothing.
if ! out="$(sudo -u "$DEV_USER" HERDR_CONFIG_PATH="$CONF" "$HERDR_BIN" config check 2>&1)" || printf '%s' "$out" | grep -q 'issues found'; then
  echo "!! herdr config check objected:" >&2
  printf '%s\n' "$out" | sed 's/^/     /' >&2
  if [ "$was_dirty" = 1 ]; then
    echo "!! these issues predate this run — keeping the additions; fix the flagged keys by hand" >&2
  else
    newest_bak="$(ls -1t "$CONF".bak.* 2>/dev/null | head -1 || true)"
    if [ -n "$newest_bak" ]; then
      cp -p "$newest_bak" "$CONF"; chown "$DEV_USER:$DEV_USER" "$CONF"
      echo "!! restored $newest_bak — config.toml is unchanged" >&2
    fi
    exit 1
  fi
else
  echo ">> herdr config check: ok"
fi

# Apply to every running session server (named sessions each have their own).
sudo -u "$DEV_USER" "$HERDR_BIN" server reload-config >/dev/null 2>&1 \
  && echo ">> reloaded: default session" || true
for s in $(sudo -u "$DEV_USER" "$HERDR_BIN" session list 2>/dev/null \
             | awk 'NR>1 && $2=="running" && $1!="default" && $1!="" {print $1}'); do
  sudo -u "$DEV_USER" "$HERDR_BIN" --session "$s" server reload-config >/dev/null 2>&1 \
    && echo ">> reloaded: $s" || true
done

echo ">> done. Check the bindings under herdr's  menu -> keybinds."
