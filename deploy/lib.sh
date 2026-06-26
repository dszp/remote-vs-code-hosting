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

# Resolve a secret from 1Password on the laptop. Usage: val=$(op_read "op://Vault/Item/field")
op_read() {
  need op
  op read "$1" 2>/dev/null || die "op read failed for: $1  (is the 1Password app unlocked? TouchID may be required)"
}
