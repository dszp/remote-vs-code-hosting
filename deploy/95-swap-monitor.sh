#!/usr/bin/env bash
# High-swap early-warning alert. On 2026-07-12 this VM (7.7 GiB RAM, no swap) ran itself out
# of memory under a stack of concurrent Claude Code sessions; the kernel OOM-killer culled the
# user systemd + tmux server, dropping every session. deploy/10-base.sh now provisions a
# swapfile so pressure PAGES instead of killing — this step adds the WARNING so you can shed
# load before swap fills. Mirrors the reboot-pending alert (deploy/90-auto-updates.sh): a
# native macOS notification on the laptop when connected, falling back to a push (Pushover/
# ntfy) when offline, reusing the SAME ~/.notify bridge + push.env — no extra config.
#
# RUN ON: the VM. run-remote sudo's; the per-user check runs as $DEV_USER.
#   ./deploy/run-remote.sh __VM_NAME__ deploy/95-swap-monitor.sh DEV_USER=__DEV_USER__
#
# Idempotent. The check runs on swap-notify.timer (every 2 min) and is silent unless swap
# crosses the threshold. Tunables live in the check script (SWAP_HIGH_PCT / SWAP_REARM_PCT /
# SWAP_REMIND_SECS); override per-VM via an Environment= line in the service, or edit the script.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="/home/$DEV_USER"

install -d -o "$DEV_USER" -g "$DEV_USER" -m 700 "$HOME_DIR/.notify"

log "writing $HOME_DIR/.notify/swap-check.sh"
cat > "$HOME_DIR/.notify/swap-check.sh" <<'CHK'
#!/bin/bash
# Notify when swap usage is high — an early warning for the memory pressure that OOM-killed
# the box (and every tmux session) on 2026-07-12. Mirrors reboot-check.sh: try the Mac
# desktop notifier first over the SSH RemoteForward sockets (~/.notify/mac*.sock — present
# only while the laptop is connected, so all-failed == laptop offline), then fall back to a
# push (Pushover/ntfy) per NOTIFY_PUSH_MODE. Reuses ~/.notify/push.env. Runs every 2 min as
# the dev user from swap-notify.timer. Silent unless swap crosses the threshold.
#
# Debounce: alert once on crossing HIGH_PCT, stay quiet while it holds (re-nag every
# REMIND_SECS), and re-arm only after it falls below REARM_PCT — hysteresis so a value
# hovering at the line can't flap. State in ~/.notify/swap-check.state ("high|ok <epoch>").
set -u
ENV_FILE="$HOME/.notify/push.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

HIGH_PCT="${SWAP_HIGH_PCT:-50}"           # alert when used% >= this
REARM_PCT="${SWAP_REARM_PCT:-25}"         # clear alert state when used% drops below this
REMIND_SECS="${SWAP_REMIND_SECS:-1800}"   # re-nag interval while still high (30 min)
STATE="$HOME/.notify/swap-check.state"

read -r sw_total sw_used < <(free -m | awk '/^Swap:/ {print $2, $3}')
[ "${sw_total:-0}" -gt 0 ] || exit 0      # no swap configured — nothing to watch
pct=$(( sw_used * 100 / sw_total ))

now="$(date +%s)"
state="ok"; stamp=0
[ -f "$STATE" ] && read -r state stamp <"$STATE" 2>/dev/null

# Decide whether this run fires, and persist the next state.
fire=0
if [ "$pct" -ge "$HIGH_PCT" ]; then
  if [ "$state" != "high" ] || [ $(( now - stamp )) -ge "$REMIND_SECS" ]; then
    fire=1; printf 'high %s\n' "$now"   >"$STATE"   # fresh crossing or re-nag due
  else
    printf 'high %s\n' "$stamp" >"$STATE"           # still high, inside the quiet window
  fi
elif [ "$pct" -lt "$REARM_PCT" ]; then
  printf 'ok %s\n' "$now" >"$STATE"                 # dropped clear — re-arm
fi                                                  # in the REARM..HIGH band: leave state as-is
[ "$fire" -eq 1 ] || exit 0

host="$(hostname -s 2>/dev/null || echo devvm)"
moshhost="${BLINK_MOSH_HOST:-__VM_NAME__}"
gib() { awk "BEGIN{printf \"%.1f\", $1/1024}"; }
title="Swap high · $host"
text="Swap ${pct}% used ($(gib "$sw_used")/$(gib "$sw_total") GiB). Memory pressure building — close some claude sessions before it OOMs."

b64() { printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'; }

# --- 1) Mac desktop attempt (forwarded sockets exist only while the laptop is on) ---
# Wire protocol (deploy mac/notify-bridge-setup.sh): one line of base64 fields —
# title subtitle message url [tmux-session]. No url/session here: an informational nudge.
# Per-connection sockets mac-<hash>.sock, newest first, prune dead ones — same loop as
# ~/.claude/notify-remote.sh (deploy/85) and reboot-check.sh (deploy/90).
desktop_ok=0
line="$(b64 "$title") $(b64 "memory pressure") $(b64 "$text") $(b64 "")"
for s in $(ls -1t "$HOME/.notify/"mac*.sock 2>/dev/null); do
  [ -S "$s" ] || continue
  if printf '%s\n' "$line" | socat -t2 - "UNIX-CONNECT:$s" 2>/dev/null; then
    desktop_ok=1; break
  fi
  rm -f "$s"
done

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
chmod 700 "$HOME_DIR/.notify/swap-check.sh"
chown "$DEV_USER:$DEV_USER" "$HOME_DIR/.notify/swap-check.sh"

# ---- system timer that runs the per-user check every 2 minutes --------------------------
log "installing swap-notify.service + .timer (runs as $DEV_USER, every 2 min)"
cat > /etc/systemd/system/swap-notify.service <<UNIT
[Unit]
Description=Notify when swap usage is high (memory-pressure early warning)

[Service]
Type=oneshot
User=$DEV_USER
Environment=HOME=$HOME_DIR
ExecStart=$HOME_DIR/.notify/swap-check.sh
UNIT

cat > /etc/systemd/system/swap-notify.timer <<'UNIT'
[Unit]
Description=Poll swap usage and alert on high memory pressure

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now swap-notify.timer

ok "high-swap alert armed: checks every 2 min; pushes at >= ${SWAP_HIGH_PCT:-50}% swap via the ~/.notify bridge."
log "alert uses the same ~/.notify bridge as Claude: Mac desktop when connected, push when offline."
log "test now (forces a send regardless of current swap, then clears state):"
log "  sudo -u $DEV_USER HOME=$HOME_DIR SWAP_HIGH_PCT=0 NOTIFY_PUSH_MODE=always $HOME_DIR/.notify/swap-check.sh; rm -f $HOME_DIR/.notify/swap-check.state"
