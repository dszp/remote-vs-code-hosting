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
# reconnecting Remote-SSH windows + extensions (n8n-as-code, Pylance).
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
