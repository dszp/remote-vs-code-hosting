#!/usr/bin/env bash
# Bound how much memory a runaway can take, with cgroup v2 limits on two nested slices.
#
# WHY THIS EXISTS: deploy/10-base.sh provisions swap so pressure PAGES instead of killing,
# and deploy/95-swap-monitor.sh warns when swap fills. Both were defeated on 2026-08-03:
# two runaway `claude.exe` processes (the Bun-compiled binary inside @anthropic-ai/claude-code)
# reached ~10.5 GiB of charged memory EACH, drove global swap from 91% to 0kB in ~60 seconds,
# and the kernel OOM-killer fired box-wide. The 95 alert fired 63 seconds ahead of the kill —
# correct, but far too late to act on. A warning cannot outrun a leak; only a limit can.
#
# Neither process held a large conversation — the biggest transcript on the box was 20.4 MB —
# so treat this as a leak that recurs, not a workload to tune away.
#
# The sizing rule is rvc_mem_cap_gib() in deploy/lib.sh (percentages of RAM, so this scales
# to any box); read the comment there for why swap is the load-bearing cap and why only the
# inner slice gets a MemoryHigh.
#
# RUN ON: the VM. run-remote sudo's.
#   ./deploy/run-remote.sh __VM_NAME__ deploy/96-memory-caps.sh DEV_USER=__DEV_USER__
#
# Idempotent. Safe to re-run: the drop-ins are rewritten from the policy each time, and the
# live apply is SKIPPED (loudly) for any slice already over the cap it would be given, since
# lowering a limit below current usage asks the kernel to OOM-kill immediately.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="/home/$DEV_USER"
uid="$(id -u "$DEV_USER")"

need systemctl

# cgroup v1 has no memory.swap.max and its memory.limit_in_bytes semantics differ enough that
# a half-applied cap would be worse than none — refuse rather than pretend.
fstype="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
[ "$fstype" = "cgroup2fs" ] || die "need cgroup v2 (unified); /sys/fs/cgroup is $fstype"

# ---- the policy, resolved for this box -------------------------------------------------
HERDR_HIGH="$(rvc_mem_cap_gib herdr-high)"
HERDR_MAX="$(rvc_mem_cap_gib herdr-max)"
HERDR_SWAP="$(rvc_mem_cap_gib herdr-swap)"
USER_MAX="$(rvc_mem_cap_gib user-max)"
USER_SWAP="$(rvc_mem_cap_gib user-swap)"
for v in "$HERDR_HIGH" "$HERDR_MAX" "$HERDR_SWAP" "$USER_MAX" "$USER_SWAP"; do
  [ "$v" -gt 0 ] 2>/dev/null || die "could not read MemTotal — refusing to guess memory caps"
done
log "policy for $(awk '/^MemTotal:/{printf "%.1f GiB", $2/1048576}' /proc/meminfo) RAM:"
log "  herdr slice: High=${HERDR_HIGH}G Max=${HERDR_MAX}G Swap=${HERDR_SWAP}G"
log "  user slice : Max=${USER_MAX}G Swap=${USER_SWAP}G"

USER_SLICE="user-${uid}.slice"
# systemd derives this slice from the herdr-session@ TEMPLATE name (deploy/60-session-boot.sh
# installs herdr-session@.service with no Slice= of its own), escaping '-' to '\x2d'. It has
# no unit file anywhere, so this drop-in is the only place its limits are ever declared.
HERDR_SLICE='app-herdr\x2dsession.slice'
CG_USER="/sys/fs/cgroup/user.slice/${USER_SLICE}"
CG_HERDR="${CG_USER}/user@${uid}.service/app.slice/${HERDR_SLICE}"

# ---- refuse to set a cap below what is already in use -----------------------------------
# Lowering memory.max under memory.current does not throttle — it invokes the cgroup OOM
# killer on the spot. Every re-run of this script would then cull a session.
# $1 = cgroup dir, $2 = cap in GiB, $3 = which file (memory.current|memory.swap.current)
cap_is_safe() {
  local dir="$1" gib="$2" file="$3" cur
  [ -d "$dir" ] || return 0                      # slice not running — nothing to kill
  cur="$(cat "$dir/$file" 2>/dev/null)" || return 0
  case "$cur" in ''|*[!0-9]*) return 0 ;; esac
  [ "$cur" -lt $(( gib * 1073741824 )) ]
}

# ---- 1) outer backstop: everything this user runs ---------------------------------------
log "writing /etc/systemd/system/${USER_SLICE}.d/50-memory-caps.conf"
install -d -m 0755 "/etc/systemd/system/${USER_SLICE}.d"
cat > "/etc/systemd/system/${USER_SLICE}.d/50-memory-caps.conf" <<CONF
# Managed by deploy/96-memory-caps.sh — regenerated on every run, do not hand-edit.
#
# Outer backstop. The inner herdr cap only covers herdr sessions; Claude started directly in
# a VS Code terminal lands in a login session-N.scope instead. ${USER_SLICE} is the common
# parent of user@${uid}.service AND every session-*.scope, so it is the only single place
# that covers both.
#
# NO MemoryHigh on purpose: MemoryHigh throttles rather than kills, and on an interactive
# slice every process stalls in reclaim together — it reads as the whole desktop hanging.
# The graduated warning layer lives on the inner herdr slice instead.
#
# Which process dies is not left to chance: Claude Code sets oom_score_adj=200 on itself
# while the VS Code server sits at 0, so the cgroup OOM killer strongly prefers a claude
# process. In the 2026-08-03 global OOM nothing but claude was touched.

[Slice]
MemoryAccounting=yes
MemoryMax=${USER_MAX}G
MemorySwapMax=${USER_SWAP}G
CONF

# ---- 2) inner cap: herdr sessions --------------------------------------------------------
DROPIN_DIR="$HOME_DIR/.config/systemd/user/${HERDR_SLICE}.d"
log "writing ${DROPIN_DIR}/50-memory-caps.conf"
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0755 "$DROPIN_DIR"
cat > "$DROPIN_DIR/50-memory-caps.conf" <<CONF
# Managed by deploy/96-memory-caps.sh — regenerated on every run, do not hand-edit.
#
# Bound the AGGREGATE of all herdr sessions. Applied to the PARENT slice rather than to
# herdr-session@.service because per-session caps do not sum, and several sessions run at
# once. systemd creates this slice implicitly from the template name, so it has no unit
# file — this drop-in is the only declaration of its limits.
#
# MemorySwapMax is the load-bearing one: memory.max bounds anon+file only, and the kernel
# relieves that pressure by paging anon out to swap — the resource that actually ran out.

[Slice]
MemoryAccounting=yes
MemoryHigh=${HERDR_HIGH}G
MemoryMax=${HERDR_MAX}G
MemorySwapMax=${HERDR_SWAP}G
CONF
chown "$DEV_USER:$DEV_USER" "$DROPIN_DIR/50-memory-caps.conf"

# ---- 3) apply live ----------------------------------------------------------------------
# daemon-reload alone is NOT enough: it updates systemd's view but never pushes cgroup
# properties onto an ALREADY-RUNNING slice, so the kernel files keep reading "max" until the
# next boot. set-property is what actually writes them. --runtime keeps the live copy in
# /run; the drop-ins above are what persist across a reboot.
systemctl daemon-reload
runuser -u "$DEV_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
  systemctl --user daemon-reload >/dev/null 2>&1 || :

if cap_is_safe "$CG_USER" "$USER_MAX" memory.current \
&& cap_is_safe "$CG_USER" "$USER_SWAP" memory.swap.current; then
  systemctl set-property --runtime "$USER_SLICE" \
    "MemoryMax=${USER_MAX}G" "MemorySwapMax=${USER_SWAP}G"
  ok "$USER_SLICE capped live: Max=${USER_MAX}G Swap=${USER_SWAP}G"
else
  warn "$USER_SLICE is ALREADY above the cap — not applying live (would OOM-kill immediately)."
  warn "  in use: $(awk '{printf "%.2f GiB", $1/1073741824}' "$CG_USER/memory.current" 2>/dev/null)" \
       "swap $(awk '{printf "%.2f GiB", $1/1073741824}' "$CG_USER/memory.swap.current" 2>/dev/null)"
  warn "  shed load, then re-run this script — or reboot, where the drop-in applies cleanly."
fi

if [ -d "$CG_HERDR" ]; then
  if cap_is_safe "$CG_HERDR" "$HERDR_MAX" memory.current \
  && cap_is_safe "$CG_HERDR" "$HERDR_SWAP" memory.swap.current; then
    runuser -u "$DEV_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
      systemctl --user set-property --runtime "$HERDR_SLICE" \
        "MemoryHigh=${HERDR_HIGH}G" "MemoryMax=${HERDR_MAX}G" "MemorySwapMax=${HERDR_SWAP}G"
    ok "$HERDR_SLICE capped live: High=${HERDR_HIGH}G Max=${HERDR_MAX}G Swap=${HERDR_SWAP}G"
  else
    warn "$HERDR_SLICE is ALREADY above the cap — not applying live. Shed load and re-run."
  fi
else
  log "$HERDR_SLICE not running — drop-in written, applies when a herdr session starts."
fi

# ---- 4) report what the KERNEL thinks, not what systemd was told -------------------------
# systemctl show would happily echo back values that never reached the kernel; only these
# files enforce anything.
log "effective cgroup limits:"
for pair in "$CG_USER|$USER_SLICE" "$CG_HERDR|$HERDR_SLICE"; do
  d="${pair%%|*}"; n="${pair##*|}"
  [ -d "$d" ] || { log "  $n: (not running)"; continue; }
  printf '       %s: max=%s swap.max=%s high=%s\n' "$n" \
    "$(cat "$d/memory.max" 2>/dev/null)" \
    "$(cat "$d/memory.swap.max" 2>/dev/null)" \
    "$(cat "$d/memory.high" 2>/dev/null)" >&2
done

ok "memory caps armed. A runaway now dies inside its own slice instead of taking the box down."
log "watch for hits:  cat $CG_HERDR/memory.events   # high/max counters, 0 means never tripped"
log "note: oom_kill there is CUMULATIVE and never resets — a stale 1 is not a new kill."
