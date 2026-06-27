#!/usr/bin/env bash
# Install the Claude Code "Notification" hook ON THE VM so that when Claude wants your
# attention it (1) raises a native macOS notification on your laptop via the notify
# bridge (mac/notify-bridge-setup.sh), and (2) falls back to a push service when the
# laptop is offline. Idempotent.
#
# RUN ON: the VM. run-remote sudo's; we write the dev user's home.
#   ./deploy/run-remote.sh __VM_NAME__ deploy/85-notify-hook.sh DEV_USER=__DEV_USER__
#
# Push is wired but DORMANT until you fill in ~/.notify/push.env (Pushover or ntfy) and
# register a device. NOTIFY_PUSH_MODE: off | always | fallback (default: push only when
# the desktop notification could not be delivered, i.e. the laptop is offline).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="/home/$DEV_USER"
NOTIFY_HOST="${NOTIFY_SSH_HOST:-autodev}"   # SSH host used to build the click-to-open VS Code URL

need jq; need socat   # the hook depends on both; fail loudly if the base image lacks them

install -d -o "$DEV_USER" -g "$DEV_USER" -m 700 "$HOME_DIR/.notify" "$HOME_DIR/.cache/pastes" "$HOME_DIR/.claude"

log "writing $HOME_DIR/.claude/notify-remote.sh"
cat > "$HOME_DIR/.claude/notify-remote.sh" <<HOOK
#!/bin/bash
# Claude Code Notification hook (runs on the VM). Desktop-first, push-on-offline.
input="\$(cat)"
msg="\$(printf '%s' "\$input" | jq -r '.message // empty' 2>/dev/null)"
dir="\$(printf '%s' "\$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "\$msg" ] && msg="Claude needs your attention"
name=""; [ -n "\$dir" ] && name="\$(basename "\$dir")"
host="\${NOTIFY_SSH_HOST:-$NOTIFY_HOST}"
url=""; [ -n "\$dir" ] && url="vscode://vscode-remote/ssh-remote+\${host}\${dir}"
title="Claude Code · $(hostname -s 2>/dev/null || echo devvm)"

SOCK="\$HOME/.notify/mac.sock"
b64() { printf '%s' "\$1" | base64 -w0 2>/dev/null || printf '%s' "\$1" | base64 | tr -d '\n'; }

desktop_ok=0
if [ -S "\$SOCK" ]; then
  line="\$(b64 "\$title") \$(b64 "\$name") \$(b64 "\$msg") \$(b64 "\$url")"
  printf '%s\n' "\$line" | socat -t2 - "UNIX-CONNECT:\$SOCK" 2>/dev/null && desktop_ok=1
fi

ENV_FILE="\$HOME/.notify/push.env"
# shellcheck disable=SC1090
[ -f "\$ENV_FILE" ] && . "\$ENV_FILE"
mode="\${NOTIFY_PUSH_MODE:-fallback}"   # off | always | fallback
want_push=0
case "\$mode" in
  always)   want_push=1 ;;
  fallback) [ "\$desktop_ok" -eq 1 ] || want_push=1 ;;
  *)        want_push=0 ;;
esac

if [ "\$want_push" -eq 1 ]; then
  ptitle="\$title"; [ -n "\$name" ] && ptitle="\$title · \$name"
  if [ -n "\${PUSHOVER_TOKEN:-}" ] && [ -n "\${PUSHOVER_USER:-}" ]; then
    curl -s --max-time 10 -F "token=\${PUSHOVER_TOKEN}" -F "user=\${PUSHOVER_USER}" \\
      -F "title=\${ptitle}" -F "message=\${msg}" \\
      \${url:+-F "url=\${url}"} \${url:+-F "url_title=Open in VS Code"} \\
      https://api.pushover.net/1/messages.json >/dev/null 2>&1 || true
  elif [ -n "\${NTFY_URL:-}" ]; then
    curl -s --max-time 10 -H "Title: \${ptitle}" \${url:+-H "Click: \${url}"} \\
      -d "\${msg}" "\${NTFY_URL}" >/dev/null 2>&1 || true
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

# --- Pushover (https://pushover.net; needs a registered device to deliver) ---
#PUSHOVER_TOKEN=your_app_api_token
#PUSHOVER_USER=your_user_key

# --- or ntfy (no account; pick a hard-to-guess topic, install the ntfy app) ---
#NTFY_URL=https://ntfy.sh/your-private-topic-here
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
