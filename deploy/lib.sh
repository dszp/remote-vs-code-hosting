#!/usr/bin/env bash
# Shared helpers for the remote-vs-code deploy scripts.
# Source this at the top of each script:  source "$(dirname "$0")/lib.sh"
#
# Design notes:
#  - Host-setup scripts (10..50) are written to run ON the target VM (idempotent).
#  - run-remote.sh ships a host-script over SSH and runs it via stdin (no secrets on
#    the remote command line / process list, nothing written to the repo).
#  - Secrets are resolved on the LAPTOP with `op` (TouchID) and exported into the
#    environment before invoking a script; run-remote.sh forwards selected vars.

set -euo pipefail

# ---- pretty logging -------------------------------------------------------
_c()  { printf '\033[%sm' "$1"; }
log()  { printf '%s[ rvc ]%s %s\n' "$(_c '1;36')" "$(_c 0)" "$*" >&2; }
ok()   { printf '%s[  ok ]%s %s\n' "$(_c '1;32')" "$(_c 0)" "$*" >&2; }
warn() { printf '%s[warn ]%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*" >&2; }
die()  { printf '%s[fail ]%s %s\n' "$(_c '1;31')" "$(_c 0)" "$*" >&2; exit 1; }

# ---- small guards ---------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# Require an env var to be set and non-empty (used by host scripts).
require_env() {
  local name="$1"
  [ -n "${!name:-}" ] || die "missing required env var: $name (export it, e.g. via 'op run')"
}

# Idempotent line-in-file: ensure $1 (exact line) exists in file $2.
ensure_line() {
  local line="$1" file="$2"
  grep -qxF -- "$line" "$file" 2>/dev/null || printf '%s\n' "$line" | sudo tee -a "$file" >/dev/null
}

# ---- swap sizing policy ---------------------------------------------------
# THE ONE definition of how much swap this box should have: RAM, rounded up to a whole
# GiB. deploy/10-base.sh uses it to PROVISION; deploy/95-swap-monitor.sh embeds these
# same functions (via `declare -f`, so they are the same bytes, not a copy) to NOTICE
# when the running box has fallen below it.
#
# WHY THE MONITOR NEEDS THIS: 10-base deliberately leaves existing swap alone
# ("swap already active — leaving it as-is"), which is right — it must never destroy a
# swapfile out from under a running system. But it means a RAM upgrade silently leaves
# swap undersized forever, with nothing to flag it. Observed on __VM_NAME__ 2026-07-30:
# 15 GiB RAM against an 8 GiB swapfile provisioned when the VM was smaller.
#
# MEMINFO is overridable so both are testable (tests/test-swap-policy.sh).

# Wanted swap, in whole GiB, from RAM.
rvc_swap_policy_gib() {
  local kib
  kib="$(awk '/^MemTotal:/{print $2}' "${MEMINFO:-/proc/meminfo}" 2>/dev/null)"
  # A wrong number here would provision an absurd swapfile or nag about a phantom
  # shortfall, so refuse to guess.
  case "$kib" in ''|*[!0-9]*) printf '0'; return 1 ;; esac
  printf '%s' $(( (kib + 1048575) / 1048576 ))
}

# Swap the box actually has, in whole GiB, rounded UP.
# Rounding up is load-bearing: every swap area spends a few KiB on its header, so two
# 8 GiB files report 16777208 kB rather than 16777216. Truncating that yields 15 and
# would report a correctly-sized box as 1 GiB short — forever.
rvc_swap_total_gib() {
  local kib
  kib="$(awk '/^SwapTotal:/{print $2}' "${MEMINFO:-/proc/meminfo}" 2>/dev/null)"
  case "$kib" in ''|*[!0-9]*) printf '0'; return 1 ;; esac
  printf '%s' $(( (kib + 1048575) / 1048576 ))
}

# ---- memory cap policy ----------------------------------------------------
# THE ONE definition of how much memory a runaway is allowed to take. deploy/96-memory-caps.sh
# turns these into cgroup v2 limits on two nested slices.
#
# WHY: swap alone only buys time. On 2026-08-03 two runaway `claude.exe` processes (the
# Bun-compiled binary shipped inside @anthropic-ai/claude-code) reached ~10.5 GiB of charged
# memory EACH, drove global swap to 0kB, and the kernel OOM-killer fired box-wide — exactly
# the failure deploy/10's swapfile and deploy/95's alert were meant to soften. Neither process
# held a large conversation (the biggest transcript on the box was 20 MB), so this is a leak
# that recurs, not a workload that can be tuned away. Bound it instead.
#
# SWAP IS THE LOAD-BEARING CAP. In cgroup v2 memory.max bounds anon+file only, and the kernel
# relieves that pressure by paging anon out to SWAP — the very resource that hit zero. Capping
# memory without also capping swap aims the leak straight at the failure mode. During the
# incident one process sat at 1.3 GiB resident with 9.1 GiB paged out; that dynamic was
# already visible before any cap existed.
#
# TWO LAYERS, because one slice cannot see everything:
#   herdr-*  app-herdr\x2dsession.slice — herdr sessions. Gets a graduated MemoryHigh so a
#            busy batch is throttled before anything dies.
#   user-*   user-<uid>.slice — the common parent of user@<uid>.service AND every login
#            session-N.scope, so it also covers Claude started in a plain VS Code terminal
#            (7 of 13 live sessions were outside the herdr slice when this was written).
#            Backstop only — NO MemoryHigh: throttling an interactive slice stalls every
#            process in it at once and reads as the whole desktop hanging.
#
# Percentages of RAM, not fixed GiB, so the same rule sizes a 4 GiB VM and a 64 GiB one.
# On the 15.87 GiB __VM_NAME__ these yield 9/12/4 and 13/6 GiB respectively — chosen against
# measured behaviour: one busy herdr session peaked at 6.31 GiB with no leak, so the caps
# must clear that, while the leak drove the herdr slice to 13.76 and the user slice to 15.16.
#
# MEMINFO is overridable so this is testable (tests/test-memory-caps.sh).
rvc_mem_cap_gib() {
  local which="${1:-}" kib total ceil hh hm hs um us
  kib="$(awk '/^MemTotal:/{print $2}' "${MEMINFO:-/proc/meminfo}" 2>/dev/null)"
  # A wrong number here would either cap a box below its normal working set — killing real
  # work every day — or set a limit so high it never fires. Refuse to guess.
  case "$kib" in ''|*[!0-9]*) printf '0'; return 1 ;; esac

  # Every value is rounded to NEAREST GiB, not truncated: at 15.87 GiB RAM, 25% truncates to
  # 3 and would cap swap a full GiB under the intended 4.
  #
  # Then CLAMPED, so the layering holds by construction instead of by luck. Percentages alone
  # break down on small boxes — on a 2 GiB VM, 82% rounds straight back to 2, a cap equal to
  # RAM that can never fire before the global OOM killer does, i.e. exactly the failure this
  # policy exists to prevent. The clamps are what make the rule safe at both ends:
  #   user-max  <= RAM - 1G   the kernel, system.slice and page cache must have somewhere
  #                           to live, or the cap is decoration.
  #   herdr-max <= user-max   the inner cap must bite FIRST, or it is dead weight.
  #   herdr-high<= herdr-max  the soft throttle must bite before the hard kill.
  #   herdr-swap<= user-swap  same nesting, for the resource that actually ran out.
  # Nothing ever floors below 1G: memory.swap.max=0 disables swap for the slice entirely,
  # which is a very different — and much worse — policy than "cap it low".
  total=$(( kib / 1048576 ))
  ceil=$(( total - 1 )); [ "$ceil" -lt 1 ] && ceil=1

  um=$(( (kib * 82 / 100 + 524288) / 1048576 ))   # outer backstop
  [ "$um" -gt "$ceil" ] && um=$ceil; [ "$um" -lt 1 ] && um=1
  hm=$(( (kib * 76 / 100 + 524288) / 1048576 ))   # cgroup OOM kill, contained to herdr
  [ "$hm" -gt "$um" ] && hm=$um;    [ "$hm" -lt 1 ] && hm=1
  hh=$(( (kib * 57 / 100 + 524288) / 1048576 ))   # throttle + reclaim, never kills
  [ "$hh" -gt "$hm" ] && hh=$hm;    [ "$hh" -lt 1 ] && hh=1
  us=$(( (kib * 38 / 100 + 524288) / 1048576 ))
  [ "$us" -lt 1 ] && us=1
  hs=$(( (kib * 25 / 100 + 524288) / 1048576 ))
  [ "$hs" -gt "$us" ] && hs=$us;    [ "$hs" -lt 1 ] && hs=1

  case "$which" in
    herdr-high) printf '%s' "$hh" ;;
    herdr-max)  printf '%s' "$hm" ;;
    herdr-swap) printf '%s' "$hs" ;;
    user-max)   printf '%s' "$um" ;;
    user-swap)  printf '%s' "$us" ;;
    *) printf '0'; return 1 ;;
  esac
}

# ---- kernel limits --------------------------------------------------------
# Raise the inotify watch limits persistently. Called by deploy/10-base.sh.
#
# WHY: AlmaLinux defaults fs.inotify.max_user_watches to 8192, which a workspace with
# node_modules/ and .git/ plus several reconnecting VS Code Remote-SSH windows and
# extensions blows through — the editor then pops "ENOSPC: System limit for number of
# file watchers reached" and file watching silently stops working. This is the kernel
# half of the fix; the other half caps what VS Code asks to watch at all
# (files.watcherExclude, deploy/67-vscode-terminal-settings.sh).
#
# NEVER LOWERS A LIMIT. A fixed value written unconditionally could undo a higher one
# set by another drop-in or a distro update, so the effective values (`sysctl -n`, i.e.
# what is actually in force — not any single file) are checked first. Both must already
# meet the target to skip; one below is enough to act.
#
# NON-DESTRUCTIVE: an existing 99-inotify.conf is somebody's deliberate choice and is
# left byte-for-byte alone, matching deploy/67 and 68. SYSCTL_DIR is overridable so the
# logic can be tested off to the side (tests/test-inotify-sysctl.sh).
rvc_ensure_inotify_limits() {
  local dir="${SYSCTL_DIR:-/etc/sysctl.d}"
  local conf="$dir/99-inotify.conf"
  local want_watches=524288 want_instances=1024
  local have_watches have_instances

  if [ -e "$conf" ]; then
    echo ">> $conf already exists — leaving it as-is"
    return 0
  fi

  have_watches="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null)"
  have_instances="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null)"
  # A missing or non-numeric reading means "unknown", which must not be mistaken for
  # "already high enough" — treat it as 0 so we write rather than skip.
  case "$have_watches"   in ''|*[!0-9]*) have_watches=0   ;; esac
  case "$have_instances" in ''|*[!0-9]*) have_instances=0 ;; esac

  if [ "$have_watches" -ge "$want_watches" ] && [ "$have_instances" -ge "$want_instances" ]; then
    echo ">> inotify limits already at or above target ($have_watches / $have_instances) — nothing to do"
    return 0
  fi

  install -d -m 0755 "$dir"
  cat > "$conf" <<EOF
# Raise inotify limits so VS Code Remote-SSH file watchers don't hit ENOSPC.
# 8192 default is too small for a workspace with node_modules/.git + multiple
# reconnecting Remote-SSH windows + extensions (Pylance and friends).
# Managed by remote-vs-code deploy/10-base.sh — it never overwrites this file.
fs.inotify.max_user_watches=$want_watches
fs.inotify.max_user_instances=$want_instances
EOF
  chmod 0644 "$conf"
  echo ">> wrote $conf (watches $have_watches -> $want_watches, instances $have_instances -> $want_instances)"
  sysctl --system >/dev/null 2>&1 || echo "!! sysctl --system failed; limits apply on next boot" >&2
}

# Resolve a secret from 1Password on the laptop. Usage: val=$(op_read "op://Vault/Item/field")
op_read() {
  need op
  op read "$1" 2>/dev/null || die "op read failed for: $1  (is the 1Password app unlocked? TouchID may be required)"
}
