#!/usr/bin/env bash
# Daily UNATTENDED SECURITY updates, with NO automatic reboot — plus an alert when a reboot
# becomes pending (kernel / core libs / systemd updated). The alert mirrors the Claude
# attention hook (deploy/85-notify-hook.sh): it raises a native macOS notification on the
# laptop when you're connected, and falls back to a push (Pushover/ntfy) when you're offline.
# It reuses the SAME ~/.notify/ bridge + push.env, so no extra config. The push carries a
# Blink (iOS) `mosh <host>` terminal link when BLINK_URL_KEY is set.
#
# RUN ON: the VM. run-remote sudo's; the per-user check runs as $DEV_USER.
#   ./deploy/run-remote.sh __VM_NAME__ deploy/90-auto-updates.sh DEV_USER=__DEV_USER__
#
# Idempotent. Updates apply on dnf-automatic.timer (daily); the reboot check runs on its
# own daily timer (reboot-notify.timer). Nothing reboots on its own — that stays manual.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="/home/$DEV_USER"

# ---- 1) install + configure dnf-automatic (security only, apply, never reboot) ----------
rpm -q dnf-automatic >/dev/null 2>&1 || { log "installing dnf-automatic"; dnf -y install dnf-automatic; }
# `dnf needs-restarting -r` is a dnf-plugins-core subcommand (usually preinstalled); ensure it.
rpm -q dnf-plugins-core >/dev/null 2>&1 || dnf -y install dnf-plugins-core

log "writing /etc/dnf/automatic.conf (upgrade_type=security, apply, reboot=never)"
# NOTE: upgrade_type=security relies on AlmaLinux's updateinfo (errata) metadata — only
# packages with a security advisory are applied. emit_via=stdio keeps output in the journal
# (journalctl -u dnf-automatic.service); we do our own reboot notification below.
cat > /etc/dnf/automatic.conf <<'CONF'
[commands]
upgrade_type = security
random_sleep = 0
network_online_timeout = 60
download_updates = yes
apply_updates = yes
reboot = never

[emitters]
emit_via = stdio
system_name =

[base]
debuglevel = 1
CONF

log "enabling dnf-automatic.timer (daily)"
systemctl enable --now dnf-automatic.timer

# ---- 2) per-user reboot-pending notifier (reuses the ~/.notify bridge + push.env) -------
install -d -o "$DEV_USER" -g "$DEV_USER" -m 700 "$HOME_DIR/.notify"

log "writing $HOME_DIR/.notify/reboot-check.sh"
cat > "$HOME_DIR/.notify/reboot-check.sh" <<'CHK'
#!/bin/bash
# Notify when a reboot is pending after security updates. Mirrors the Claude attention hook:
# try the Mac desktop notifier first over the SSH RemoteForward socket (~/.notify/mac.sock —
# present only while the laptop is connected, so a failed attempt == laptop offline), then
# fall back to a push (Pushover/ntfy) per NOTIFY_PUSH_MODE. Reuses ~/.notify/push.env. Runs
# daily as the dev user from reboot-notify.timer. Silent when no reboot is needed.
set -u
ENV_FILE="$HOME/.notify/push.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

# dnf needs-restarting -r: exit 1 = reboot recommended (kernel/core libs/systemd), 0 = fine.
dnf needs-restarting -r >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] || exit 0

host="$(hostname -s 2>/dev/null || echo devvm)"
moshhost="${BLINK_MOSH_HOST:-__VM_NAME__}"
title="Reboot pending · $host"
text="Security updates need a reboot (kernel / core libs). Reboot when convenient — auto-reboot is off."

b64() { printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'; }

# --- 1) Mac desktop attempt (only if the forwarded socket exists == laptop online) ---
# Wire protocol (deploy mac/notify-bridge-setup.sh): one line of base64 fields —
# title subtitle message url [tmux-session]. No url or session here: it's an
# informational "go reboot" nudge (a missing 5th field keeps the plain-open click).
SOCK="$HOME/.notify/mac.sock"
desktop_ok=0
if [ -S "$SOCK" ]; then
  line="$(b64 "$title") $(b64 "security updates") $(b64 "$text") $(b64 "")"
  if printf '%s\n' "$line" | socat -t2 - "UNIX-CONNECT:$SOCK" 2>/dev/null; then
    desktop_ok=1
  fi
fi

# --- 2) push fallback per NOTIFY_PUSH_MODE: off | always | fallback (default) ---
mode="${NOTIFY_PUSH_MODE:-fallback}"
want_push=0
case "$mode" in
  always)   want_push=1 ;;
  fallback) [ "$desktop_ok" -eq 1 ] || want_push=1 ;;
  *)        want_push=0 ;;
esac
[ "$want_push" -eq 1 ] || exit 0

amp()  { printf '%s' "$1" | sed 's/&/\&amp;/g'; }
hesc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
enc()  { printf '%s' "$1" | jq -sRr @uri 2>/dev/null; }

body="<b>$(hesc "$text")</b>"
# Terminal in Blink (iOS): mosh the VM. Needs BLINK_URL_KEY (Blink URL actions, off by default).
if [ -n "${BLINK_URL_KEY:-}" ]; then
  blink="blinkshell://run?key=${BLINK_URL_KEY}&cmd=$(enc "mosh ${moshhost}")"
  body="${body}<br><a href=\"$(amp "$blink")\">▶ Terminal · Blink (mosh)</a>"
fi

if [ -n "${PUSHOVER_TOKEN:-}" ] && [ -n "${PUSHOVER_USER:-}" ]; then
  curl -sS --max-time 10 \
    --form-string "token=${PUSHOVER_TOKEN}" --form-string "user=${PUSHOVER_USER}" \
    ${PUSHOVER_DEVICE:+--form-string "device=${PUSHOVER_DEVICE}"} \
    --form-string "html=1" \
    --form-string "title=${title}" --form-string "message=${body}" \
    https://api.pushover.net/1/messages.json >/dev/null 2>&1 || true
elif [ -n "${NTFY_URL:-}" ]; then
  curl -sS --max-time 10 -H "Title: ${title}" -d "${text}" "${NTFY_URL}" >/dev/null 2>&1 || true
fi
exit 0
CHK
chmod 700 "$HOME_DIR/.notify/reboot-check.sh"
chown "$DEV_USER:$DEV_USER" "$HOME_DIR/.notify/reboot-check.sh"

# ---- 3) system timer that runs the per-user check daily ---------------------------------
log "installing reboot-notify.service + .timer (runs as $DEV_USER)"
cat > /etc/systemd/system/reboot-notify.service <<UNIT
[Unit]
Description=Notify when a reboot is pending after security updates

[Service]
Type=oneshot
User=$DEV_USER
Environment=HOME=$HOME_DIR
ExecStart=$HOME_DIR/.notify/reboot-check.sh
UNIT

cat > /etc/systemd/system/reboot-notify.timer <<'UNIT'
[Unit]
Description=Daily check for a pending reboot (security updates)

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now reboot-notify.timer

ok "auto-updates active: security updates daily (no auto-reboot); reboot-pending alert armed."
log "alert uses the same ~/.notify bridge as Claude: Mac desktop when connected, push when offline."
log "test now (only sends if a reboot is genuinely pending):  sudo -u $DEV_USER HOME=$HOME_DIR $HOME_DIR/.notify/reboot-check.sh"