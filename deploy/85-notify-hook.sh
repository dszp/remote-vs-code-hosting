#!/usr/bin/env bash
# Install the Claude Code "Notification" hook ON THE VM so that when Claude wants your
# attention it (1) raises a native macOS notification on your laptop via the notify
# bridge (mac/notify-bridge-setup.sh), and (2) falls back to a push when the laptop is
# offline. The push (Pushover) is an html message with up to THREE tappable links for
# the cwd: Code (code-server in Blink), Terminal (mosh + attach the folder's tmux
# session in Blink), and Web (plain https code-server in the browser). Idempotent.
#
# RUN ON: the VM. run-remote sudo's; we write the dev user's home.
#   ./deploy/run-remote.sh __VM_NAME__ deploy/85-notify-hook.sh DEV_USER=__DEV_USER__
#
# Push is wired but DORMANT until you fill in ~/.notify/push.env (Pushover or ntfy).
# NOTIFY_PUSH_MODE: off | always | fallback (default: push only when the desktop
# notification could not be delivered, i.e. the laptop is offline).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="/home/$DEV_USER"

need jq; need socat   # the hook depends on both; fail loudly if the base image lacks them

install -d -o "$DEV_USER" -g "$DEV_USER" -m 700 "$HOME_DIR/.notify" "$HOME_DIR/.cache/pastes" "$HOME_DIR/.claude"

log "writing $HOME_DIR/.claude/notify-remote.sh"
cat > "$HOME_DIR/.claude/notify-remote.sh" <<'HOOK'
#!/bin/bash
# Claude Code Notification hook — runs ON the VM.
# 1) Tries the Mac desktop notifier over the SSH RemoteForward socket (only present
#    while the laptop is connected, so a failed attempt == laptop offline).
# 2) Else pushes per NOTIFY_PUSH_MODE: Pushover (html, up to 3 tappable links) or ntfy.
#    Dormant until ~/.notify/push.env is filled in.
input="$(cat)"
msg="$(printf '%s' "$input" | jq -r '.message // empty' 2>/dev/null)"
dir="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$msg" ] && msg="Claude needs your attention"
name=""; [ -n "$dir" ] && name="$(basename "$dir")"
host="${NOTIFY_SSH_HOST:-__VM_SSH_ALIAS__}"
url=""; [ -n "$dir" ] && url="vscode://vscode-remote/ssh-remote+${host}${dir}"   # desktop: native VS Code
title="Claude Code · $(hostname -s 2>/dev/null || echo devvm)"
# tmux session Claude runs in — sent to the Mac (5th wire field) so the click handler
# can focus a matching Ghostty tab (title "<session> · <host>", per config/tmux.conf
# set-titles) before falling back to the vscode:// url. Reused for the push Terminal link.
sess=""; [ -n "${TMUX:-}" ] && sess="$(tmux display-message -p '#S' 2>/dev/null)"

b64() { printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'; }

# --- desktop attempt ---
# Each Mac SSH connection binds its OWN forwarded socket ~/.notify/mac-<alias>.sock
# (RemoteForward with ssh's %n token — the alias as typed — config/ssh-config.snippet),
# so try them newest-bind-first and deliver via the first live one: the bridge survives any
# one connection dying, which neither the old single shared mac.sock NOR %C did (last bind
# wins the path; when THAT connection died, delivery broke even with other connections
# alive — and %C, hashing HostName, collides across aliases that share one like __VM_SSH_ALIAS__/__VM_NAME__).
# A refused connect == a dead forward left the file behind: prune it. The legacy
# mac.sock still matches the glob, so unmigrated ssh configs keep working.
desktop_ok=0
line="$(b64 "$title") $(b64 "$name") $(b64 "$msg") $(b64 "$url") $(b64 "$sess")"
for s in $(ls -1t "$HOME/.notify/"mac*.sock 2>/dev/null); do
  [ -S "$s" ] || continue
  if printf '%s\n' "$line" | socat -t2 - "UNIX-CONNECT:$s" 2>/dev/null; then
    desktop_ok=1; break
  fi
  rm -f "$s"
done

# --- push (optional / dormant until configured) ---
ENV_FILE="$HOME/.notify/push.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

# Build up to three tap actions for the cwd (needs push.env):
#   web_url  -> https code-server URL        (opens in the browser; always available)
#   code_url -> `code <web_url>` in Blink     (Blink Code editor; needs BLINK_URL_KEY)
#   term_url -> `mosh <host> "cs '<folder>'"` in Blink (attach the cwd's tmux session)
# Blink only intercepts vscode:// (path-only, can't carry an https URL), so the in-Blink
# launchers use blinkshell://run?key=<KEY>&cmd=<jq @uri-encoded> — Blink's command runner.
# Quoting on term: outer "…" groups the remote command for mosh; inner '…' groups the
# session name for the remote shell, so folder names with spaces survive both layers.
csbase="${CODE_SERVER_URL:-https://__CODE_HOSTNAME__}"
moshhost="${BLINK_MOSH_HOST:-__VM_NAME__}"
enc() { printf '%s' "$1" | jq -sRr @uri; }
# Folder for the Web/Code links: the project dir directly under ~/workspace. Fall back to
# ~/workspace itself when the cwd is outside workspace, empty, or gone (subfolder depth and
# -2 session suffixes don't matter — code-server still opens a sensible project root).
ws="${WORKSPACE_DIR:-$HOME/workspace}"
case "$dir" in
  "$ws"/*) rel="${dir#"$ws"/}"; folder="$ws/${rel%%/*}" ;;
  *)       folder="$ws" ;;
esac
[ -d "$folder" ] || folder="$ws"
# Terminal link targets the tmux SESSION Claude runs in (computed above; cwd basename
# can differ — e.g. a git subfolder), falling back to the always-present 'claude' session.
psess="${sess:-claude}"

web_url="${csbase}/?folder=${folder}"
code_url=""; term_url=""
if [ -n "${BLINK_URL_KEY:-}" ]; then
  code_url="blinkshell://run?key=${BLINK_URL_KEY}&cmd=$(enc "code ${web_url}")"
  term_url="blinkshell://run?key=${BLINK_URL_KEY}&cmd=$(enc "mosh ${moshhost} \"cs '${psess}'\"")"
fi

mode="${NOTIFY_PUSH_MODE:-fallback}"   # off | always | fallback
want_push=0
case "$mode" in
  always)   want_push=1 ;;
  fallback) [ "$desktop_ok" -eq 1 ] || want_push=1 ;;
  *)        want_push=0 ;;
esac

if [ "$want_push" -eq 1 ]; then
  ptitle="$title"; [ -n "$name" ] && ptitle="$title · $name"
  if [ -n "${PUSHOVER_TOKEN:-}" ] && [ -n "${PUSHOVER_USER:-}" ]; then
    # One push, all actions as tappable html body links (Pushover html=1) — pick per click,
    # same to every device. Inside an href, & must be &amp;; escape <>& in the text.
    # NOTE: use --form-string (not -F): a value starting with < or @ makes curl read a file.
    amp()  { printf '%s' "$1" | sed 's/&/\&amp;/g'; }
    hesc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
    body="<b>$(hesc "$msg")</b>"
    [ -n "$code_url" ] && body="${body}<br><a href=\"$(amp "$code_url")\">▶ Code · Blink</a>"
    [ -n "$term_url" ] && body="${body}<br><a href=\"$(amp "$term_url")\">▶ Terminal · Blink (mosh)</a>"
    [ -n "$web_url" ]  && body="${body}<br><a href=\"$(amp "$web_url")\">▶ Web · Safari</a>"
    curl -sS --max-time 10 \
      --form-string "token=${PUSHOVER_TOKEN}" --form-string "user=${PUSHOVER_USER}" \
      ${PUSHOVER_DEVICE:+--form-string "device=${PUSHOVER_DEVICE}"} \
      --form-string "html=1" \
      --form-string "title=${ptitle}" --form-string "message=${body}" \
      https://api.pushover.net/1/messages.json >/dev/null 2>&1 || true
  elif [ -n "${NTFY_URL:-}" ]; then
    curl -sS --max-time 10 \
      -H "Title: ${ptitle}" ${web_url:+-H "Click: ${web_url}"} \
      -d "${msg}" "${NTFY_URL}" >/dev/null 2>&1 || true
  fi
fi
exit 0
HOOK
chmod 700 "$HOME_DIR/.claude/notify-remote.sh"
chown "$DEV_USER:$DEV_USER" "$HOME_DIR/.claude/notify-remote.sh"

# Dormant push config template (only if absent — never clobber real creds).
if [ ! -f "$HOME_DIR/.notify/push.env" ]; then
  log "writing dormant $HOME_DIR/.notify/push.env template"
  cat > "$HOME_DIR/.notify/push.env" <<'PUSHENV'
# Remote Claude push notifications — fill in ONE provider to activate.
# NOTIFY_PUSH_MODE: off | always | fallback
#   fallback (default) = push ONLY when the Mac desktop notification could not be
#   delivered (laptop offline/disconnected).
NOTIFY_PUSH_MODE=fallback

# --- Pushover (https://pushover.net) ---
#PUSHOVER_TOKEN=your_app_api_token
#PUSHOVER_USER=your_user_key
# Optional: target specific device(s), comma-separated (empty = all devices on the account).
#PUSHOVER_DEVICE=ipad,iphone

# --- or ntfy (no account; pick a hard-to-guess topic, install the ntfy app) ---
#NTFY_URL=https://ntfy.sh/your-private-topic-here

# --- code-server / Blink deep links in the push (optional) ---
# CODE_SERVER_URL: base for the "Web" link and the in-Blink `code <url>` command.
#CODE_SERVER_URL=https://code.example.com
# BLINK_URL_KEY: Blink (iOS) URL-action key — enables the "Code" and "Terminal" links that
# run inside Blink via blinkshell://run. SECRET; enable callbacks in Blink settings (off by
# default). Without it the push offers only the plain https "Web" link.
#BLINK_URL_KEY=xxxxxx
# BLINK_MOSH_HOST: Blink host alias for the Terminal link's `mosh <host>` (default: VM name).
#BLINK_MOSH_HOST=__VM_NAME__
PUSHENV
  chmod 600 "$HOME_DIR/.notify/push.env"; chown "$DEV_USER:$DEV_USER" "$HOME_DIR/.notify/push.env"
fi

# Inject the Notification hook into the dev user's ~/.claude/settings.json (idempotent).
log "registering the Notification hook in ~/.claude/settings.json"
SETTINGS="$HOME_DIR/.claude/settings.json"
[ -f "$SETTINGS" ] || { echo '{}' > "$SETTINGS"; chown "$DEV_USER:$DEV_USER" "$SETTINGS"; }
cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
python3 - "$SETTINGS" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
home = os.path.dirname(os.path.dirname(p))            # .../.claude -> home dir
cmd = os.path.join(home, ".claude", "notify-remote.sh")
hooks = d.setdefault("hooks", {})
nf = hooks.setdefault("Notification", [])
if not any(any(h.get("command") == cmd for h in e.get("hooks", [])) for e in nf):
    nf.append({"hooks": [{"type": "command", "command": cmd}]})
json.dump(d, open(p, "w"), indent=2)
print("Notification hook ->", cmd)
PY
chown "$DEV_USER:$DEV_USER" "$SETTINGS"
ok "notify hook installed. Pair with mac/notify-bridge-setup.sh on the laptop."
