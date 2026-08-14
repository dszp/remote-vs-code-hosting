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
# 2026-08-11: swap% ALONE PROVED BLIND. deploy/96 caps the user slice's memory.swap.max at
# 38% of RAM while rvc_swap_policy_gib sizes the swapfile at 100% of RAM, so the slice
# saturates its ENTIRE budget at ~38% global — below the 50% line at any RAM size, so the
# rule could never fire. The box ran 3.5 days of accumulated Claude sessions to load 247 with
# available memory at 9.8% and this alert stayed silent throughout. Two rules were added: the
# slice's own swap budget (percent OF THE CAP) and MemAvailable, the leading indicator.
# PSI (/proc/pressure/memory) would be the ideal signal and is NOT compiled in on this kernel.
#
# Idempotent. The check runs on swap-notify.timer (every 2 min) and is silent unless a rule
# crosses its threshold. Tunables live in the check script (SWAP_HIGH_PCT / SWAP_REARM_PCT /
# SLICE_SWAP_HIGH_PCT / SLICE_SWAP_REARM_PCT / MEM_LOW_PCT / MEM_REARM_PCT / SWAP_REMIND_SECS);
# override per-VM via an Environment= line in the service, or edit the script.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="/home/$DEV_USER"

install -d -o "$DEV_USER" -g "$DEV_USER" -m 700 "$HOME_DIR/.notify"

# The check script lives in /usr/local/bin, NOT under $HOME. SELinux is enforcing here and
# anything in a home directory is user_home_t, which init_t may not execute: a system unit
# pointed at ~/.notify/swap-check.sh dies at 203/EXEC before User= is ever applied. Running
# the same file by hand from a login shell (unconfined_t) works, so the breakage is silent
# unless you look at the unit — this failed every 2 min for 13 days before anyone noticed.
# /usr/local/bin resolves to bin_t. ~/.notify stays the bridge: sockets, push.env, state.
SWAP_CHECK="/usr/local/bin/swap-check.sh"
log "writing $SWAP_CHECK"
cat > "$SWAP_CHECK" <<'CHK'
#!/bin/bash
# Notify on memory pressure. THREE rules: global swap%, this user slice's own cgroup swap
# budget, and MemAvailable. Early warning for the pressure that OOM-killed the box (and every
# tmux session) on 2026-07-12, and that thrashed it to load 247 on 2026-08-11 without ever
# tripping the swap-only rule. Mirrors reboot-check.sh: try the Mac
# desktop notifier first over the SSH RemoteForward sockets (~/.notify/mac*.sock — present
# only while the laptop is connected, so all-failed == laptop offline), then fall back to a
# push (Pushover/ntfy) per NOTIFY_PUSH_MODE. Reuses ~/.notify/push.env. Runs every 2 min as
# the dev user from swap-notify.timer. Silent unless a rule crosses its threshold.
#
# Debounce: alert once on crossing, stay quiet while it holds (re-nag every REMIND_SECS), and
# re-arm only after it clears the far side of the band — hysteresis so a value hovering at the
# line can't flap. Each rule owns a state file ("high|ok <epoch>") — ~/.notify/swap-check.state,
# slice-swap-check.state, mem-check.state — so one rule clearing can't re-arm another that is
# still firing. A run that trips more than one rule still sends exactly ONE notification.
set -u
# An explicit NOTIFY_PUSH_MODE from the environment (a forced test, or an Environment=
# line in the unit) must win over push.env — capture it before sourcing, restore after.
_mode_override="${NOTIFY_PUSH_MODE:-}"
ENV_FILE="$HOME/.notify/push.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
[ -n "$_mode_override" ] && NOTIFY_PUSH_MODE="$_mode_override"

# __RVC_SWAP_FNS__   (spliced in below from deploy/lib.sh — do not hand-edit)

HIGH_PCT="${SWAP_HIGH_PCT:-50}"           # alert when global swap used% >= this
REARM_PCT="${SWAP_REARM_PCT:-25}"         # clear alert state when used% drops below this
# The user slice's OWN swap budget (deploy/96 sets memory.swap.max = 38% of RAM). Percent is
# OF THAT CAP, not of the swapfile — see the rule-2 comment for why global% cannot see it.
SLICE_HIGH_PCT="${SLICE_SWAP_HIGH_PCT:-75}"
SLICE_REARM_PCT="${SLICE_SWAP_REARM_PCT:-50}"
# MemAvailable is the leading indicator: it collapses before swap fills and long before load
# climbs, because page-cache starvation is upstream of both. On 2026-08-11 it was at 9.8%
# with the box at load 247; idle sits near 90%, so 15/25 leaves a usable warning window.
MEM_LOW_PCT="${MEM_LOW_PCT:-15}"          # alert when available% <= this
MEM_REARM_PCT="${MEM_REARM_PCT:-25}"      # clear when it climbs back above this
REMIND_SECS="${SWAP_REMIND_SECS:-1800}"   # re-nag interval while still high (30 min)
STATE="$HOME/.notify/swap-check.state"
SLICE_STATE="$HOME/.notify/slice-swap-check.state"
MEM_STATE="$HOME/.notify/mem-check.state"

# Debounce, shared by all three rules: alert once on crossing, stay quiet while it holds
# (re-nag every REMIND_SECS), and re-arm only after it clears — hysteresis so a value
# hovering at the line cannot flap. The CALLER passes both edge decisions already made, so
# one helper serves a "high is bad" rule (swap) and a "low is bad" one (available memory)
# without a direction flag. Each rule keeps its own state file ("high|ok <epoch>") so a
# clearing swap alert cannot silently re-arm a still-firing memory alert.
debounce() {
  local st="$1" bad="$2" clear="$3" state stamp now fire=0
  now="$(date +%s)"; state="ok"; stamp=0
  [ -f "$st" ] && read -r state stamp <"$st" 2>/dev/null
  if [ "$bad" -eq 1 ]; then
    if [ "$state" != "high" ] || [ $(( now - stamp )) -ge "$REMIND_SECS" ]; then
      fire=1; printf 'high %s\n' "$now"   >"$st"    # fresh crossing or re-nag due
    else
      printf 'high %s\n' "$stamp" >"$st"            # still high, inside the quiet window
    fi
  elif [ "$clear" -eq 1 ]; then
    printf 'ok %s\n' "$now" >"$st"                  # dropped clear — re-arm
  fi                                                # between the lines: leave state as-is
  printf '%s' "$fire"
}

# --- rule 1: global swap -------------------------------------------------------------------
sw_fire=0; sw_pct=0; sw_total=0; sw_used=0
read -r sw_total sw_used < <(free -m | awk '/^Swap:/ {print $2, $3}')
if [ "${sw_total:-0}" -gt 0 ]; then       # no swap configured — nothing to watch
  sw_pct=$(( sw_used * 100 / sw_total ))
  sw_fire="$(debounce "$STATE" \
    "$( [ "$sw_pct" -ge "$HIGH_PCT" ]  && echo 1 || echo 0 )" \
    "$( [ "$sw_pct" -lt "$REARM_PCT" ] && echo 1 || echo 0 )")"
fi

# --- rule 2: this user slice's own swap budget (the one that actually ran out) --------------
# Global swap% CANNOT see this. deploy/96 caps the slice at 38% of RAM while
# rvc_swap_policy_gib sizes the swapfile at 100% of RAM, so the slice saturates its entire
# budget at ~38% global — permanently below HIGH_PCT, at any RAM size. On 2026-08-11 it sat
# pinned at exactly 6.0 GiB of a 6.0 GiB cap while the global gauge read 37% and stayed
# silent. Saturation here is the thing that hurts: with no swap budget left the kernel
# reclaims PAGE CACHE instead, so every file read refaults from disk — that is what pinned
# the box at load 247 with 2.3 GB/s of block reads and 60% system time.
sl_fire=0; sl_pct=0; sl_cur=0; sl_max=0
sl_dir="/sys/fs/cgroup/user.slice/user-$(id -u).slice"
if [ -r "$sl_dir/memory.swap.max" ] && [ -r "$sl_dir/memory.swap.current" ]; then
  sl_max="$(cat "$sl_dir/memory.swap.max" 2>/dev/null || echo 0)"
  sl_cur="$(cat "$sl_dir/memory.swap.current" 2>/dev/null || echo 0)"
  # Literal "max" means uncapped: then rule 1 is the only meaningful swap signal.
  case "$sl_max" in ''|*[!0-9]*) sl_max=0 ;; esac
  case "$sl_cur" in ''|*[!0-9]*) sl_cur=0 ;; esac
  if [ "$sl_max" -gt 0 ]; then
    sl_pct=$(( sl_cur * 100 / sl_max ))
    sl_fire="$(debounce "$SLICE_STATE" \
      "$( [ "$sl_pct" -ge "$SLICE_HIGH_PCT" ]  && echo 1 || echo 0 )" \
      "$( [ "$sl_pct" -lt "$SLICE_REARM_PCT" ] && echo 1 || echo 0 )")"
  fi
fi

# --- rule 3: available memory (the leading indicator) ---------------------------------------
# Read from /proc/meminfo rather than free(1) column 7: the column order has moved between
# procps versions, and this file is the source free itself reads.
mem_fire=0; mem_pct=100
mem_total="$(awk '/^MemTotal:/{print int($2/1024)}'     /proc/meminfo 2>/dev/null)"
mem_avail="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
if [ "${mem_total:-0}" -gt 0 ] && [ "${mem_avail:-}" != "" ]; then
  mem_pct=$(( mem_avail * 100 / mem_total ))
  mem_fire="$(debounce "$MEM_STATE" \
    "$( [ "$mem_pct" -le "$MEM_LOW_PCT" ]   && echo 1 || echo 0 )" \
    "$( [ "$mem_pct" -gt "$MEM_REARM_PCT" ] && echo 1 || echo 0 )")"
fi

[ "$sw_fire" -eq 1 ] || [ "$sl_fire" -eq 1 ] || [ "$mem_fire" -eq 1 ] || exit 0

host="$(hostname -s 2>/dev/null || echo devvm)"
moshhost="${BLINK_MOSH_HOST:-__VM_NAME__}"
gib() { awk "BEGIN{printf \"%.1f\", $1/1024}"; }
# ONE notification per run, naming whichever rules fired — three separate pushes for a single
# event trains you to ignore all of them. Title leads with the most actionable rule.
if   [ "$mem_fire" -eq 1 ]; then title="Memory low · $host"
elif [ "$sl_fire"  -eq 1 ]; then title="Swap budget · $host"
else                             title="Swap high · $host"
fi

text=""
[ "$mem_fire" -eq 1 ] && text="Available memory ${mem_pct}% ($(gib "$mem_avail")/$(gib "$mem_total") GiB)."
[ "$sl_fire"  -eq 1 ] && text="$text This user slice has used ${sl_pct}% of its swap budget ($(gib $(( sl_cur / 1048576 )))/$(gib $(( sl_max / 1048576 ))) GiB); at 100% the kernel reclaims page cache instead and every file read refaults from disk."
[ "$sw_fire"  -eq 1 ] && text="$text Swap ${sw_pct}% used ($(gib "$sw_used")/$(gib "$sw_total") GiB)."
text="${text# }"   # a rule that fires without an earlier one leaves a leading space
text="$text Shed load — close idle claude sessions, or VS Code windows (each leaves a vscode-server behind)."
# Is the swapfile itself below policy? deploy/10-base.sh never resizes existing swap, so
# a RAM upgrade leaves it undersized with nothing to say so. Only mentioned when we are
# already alerting, so it adds no new nag of its own.
want_g="$(rvc_swap_policy_gib)"; have_g="$(rvc_swap_total_gib)"
if [ "${want_g:-0}" -gt 0 ] 2>/dev/null && [ "${have_g:-0}" -lt "${want_g:-0}" ] 2>/dev/null; then
  text="$text Swap is ${have_g}G but policy wants ${want_g}G for this box's RAM — add a second swapfile (safe) rather than swapoff (would page it all back into RAM)."
fi

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
# Splice in the SAME BYTES as deploy/lib.sh rather than a second copy of the rule: the
# provisioning policy (deploy/10) and this check must never be able to disagree.
fns="$(declare -f rvc_swap_policy_gib rvc_swap_total_gib)"
awk -v fns="$fns" '$0 == "# __RVC_SWAP_FNS__   (spliced in below from deploy/lib.sh — do not hand-edit)" { print fns; next } { print }' \
  "$SWAP_CHECK" > "$SWAP_CHECK.tmp" && mv "$SWAP_CHECK.tmp" "$SWAP_CHECK"
# Optional copy so the repo's test suite can diff these bytes against lib.sh.
if [ -n "${SWAP_CHECK_COPY:-}" ]; then
  install -d -m 0755 "$(dirname "$SWAP_CHECK_COPY")"
  install -m 0644 "$SWAP_CHECK" "$SWAP_CHECK_COPY"
  echo "copied swap-check to $SWAP_CHECK_COPY"
fi
chmod 755 "$SWAP_CHECK"
chown root:root "$SWAP_CHECK"
# New files inherit bin_t from the directory rule, but restore explicitly so a script that
# was moved here from $HOME does not keep a stale user_home_t label.
command -v restorecon >/dev/null 2>&1 && restorecon -F "$SWAP_CHECK" || :

# An earlier revision installed this check under $HOME, where the system unit could not
# execute it; a hand-made user-level timer was added as a workaround and never removed.
# Retire it, or both fire and every alert arrives twice.
# Drop the old home-directory copy too, or the tunables get edited in a file nothing runs.
rm -f "$HOME_DIR/.notify/swap-check.sh"
uid="$(id -u "$DEV_USER")"
for u in swap-notify.timer swap-notify.service; do
  f="$HOME_DIR/.config/systemd/user/$u"
  [ -e "$f" ] || continue
  runuser -u "$DEV_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
    systemctl --user disable --now "$u" >/dev/null 2>&1 || :
  rm -f "$f"
  log "removed stale user-level $u (superseded by the system unit)"
done
runuser -u "$DEV_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
  systemctl --user daemon-reload >/dev/null 2>&1 || :

# ---- system timer that runs the per-user check every 2 minutes --------------------------
log "installing swap-notify.service + .timer (runs as $DEV_USER, every 2 min)"
cat > /etc/systemd/system/swap-notify.service <<UNIT
[Unit]
Description=Notify when swap usage is high (memory-pressure early warning)

[Service]
Type=oneshot
User=$DEV_USER
Environment=HOME=$HOME_DIR
ExecStart=$SWAP_CHECK
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

ok "memory-pressure alert armed: checks every 2 min via the ~/.notify bridge. Rules:"
log "  global swap    >= ${SWAP_HIGH_PCT:-50}% of the swapfile"
log "  slice swap     >= ${SLICE_SWAP_HIGH_PCT:-75}% of this user slice's memory.swap.max (deploy/96)"
log "  available mem  <= ${MEM_LOW_PCT:-15}% of MemTotal   <- the one that would have caught 2026-08-11"
log "alert uses the same ~/.notify bridge as Claude: Mac desktop when connected, push when offline."
log "test now (forces a send regardless of current state, then clears all three state files):"
log "  sudo -u $DEV_USER HOME=$HOME_DIR MEM_LOW_PCT=100 NOTIFY_PUSH_MODE=always $SWAP_CHECK"
log "  rm -f $HOME_DIR/.notify/{swap,slice-swap,mem}-check.state"
log "NOTE the caps in deploy/96 and the swapfile in deploy/10 are both derived from RAM —"
log "re-run BOTH after any RAM change, or these thresholds measure a box that no longer exists."
