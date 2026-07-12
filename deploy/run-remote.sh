#!/usr/bin/env bash
# Ship a host-setup script to a remote host and run it there over SSH.
#
#   ./deploy/run-remote.sh <ssh-target> <deploy/NN-script.sh> [VAR=VAL ...]
#
# The script content is piped to the remote `sudo bash -s` over stdin (the encrypted
# SSH channel), so it never lands on the remote disk and never appears in `ps`.
# Any VAR=VAL pairs (and an allow-listed set of already-exported vars) are exported
# inside the remote shell BEFORE the script body — this is how laptop-resolved
# secrets (from `op`) reach the host script without being committed or logged.
#
# Examples:
#   ./deploy/run-remote.sh __DEV_USER__@dev deploy/10-base.sh DEV_USER=__DEV_USER__
#   TS_AUTHKEY="$(op read 'op://__OP_VAULT__/Tailscale/authkey')" \
#       ./deploy/run-remote.sh __DEV_USER__@dev deploy/20-tailscale.sh
#
# SSH_JUMP=<jump-target> routes through a bastion (e.g. reach a VM on __PVE_HOST__'s LAN
# before Tailscale is on it):
#   SSH_JUMP=root@__PVE_TS_IP__ \
#       ./deploy/run-remote.sh __DEV_USER__@__VM_LAN_IP__ deploy/10-base.sh DEV_USER=__DEV_USER__
set -euo pipefail
cd "$(dirname "$0")/.."
source deploy/lib.sh

[ "$#" -ge 2 ] || die "usage: run-remote.sh <ssh-target> <deploy/NN-script.sh> [VAR=VAL ...]"
TARGET="$1"; SCRIPT="$2"; shift 2
[ -f "$SCRIPT" ] || die "no such script: $SCRIPT"

# Vars we forward automatically if present in the environment (extend as needed).
FORWARD_VARS=(DEV_USER TS_AUTHKEY CF_TUNNEL_NAME CF_HOSTNAME CF_SSH_HOSTNAME CF_HTTP_HOSTNAME \
              OP_SERVICE_ACCOUNT_TOKEN CODE_SERVER_PORT CODE_SERVER_PASSWORD EXPOSE_TAILSCALE NODE_VERSION)

# Build the preamble of `export VAR=...` lines.
preamble=""
for kv in "$@"; do
  case "$kv" in *=*) preamble+="export ${kv%%=*}=$(printf '%q' "${kv#*=}")"$'\n' ;;
    *) die "extra args must be VAR=VAL, got: $kv" ;; esac
done
for v in "${FORWARD_VARS[@]}"; do
  if [ -n "${!v:-}" ]; then preamble+="export ${v}=$(printf '%q' "${!v}")"$'\n'; fi
done

log "running $SCRIPT on $TARGET"
# Root targets (e.g. root@__PVE_HOST__) don't need sudo and Proxmox may not ship it.
# The exported vars live in the piped preamble (executed by the remote bash itself),
# so they reach the script regardless of sudo's env handling — no --preserve-env needed.
case "$TARGET" in
  root@*) runner='bash -s' ;;
  *)      runner='sudo bash -s' ;;
esac
# -t gives the remote a tty for any sudo password prompt.
ssh_opts=(-t -o StrictHostKeyChecking=accept-new)
[ -n "${SSH_JUMP:-}" ] && { ssh_opts+=(-J "$SSH_JUMP"); log "via jump $SSH_JUMP"; }
# A script that does `source "$(dirname "$0")/lib.sh"` can't find lib.sh over stdin — piped
# to `bash -s`, $0 is "bash", so it looks for ./lib.sh on the remote and dies. Inline lib.sh
# ahead of the body and turn the source line into a no-op. lib.sh is generic helpers with NO
# secrets, so streaming it keeps the "nothing on the remote disk / process list" guarantee.
emit_body() {
  if grep -qE '^[[:space:]]*(source|\.)[[:space:]].*lib\.sh' "$SCRIPT"; then
    cat deploy/lib.sh
    sed -E 's@^[[:space:]]*(source|\.)[[:space:]].*lib\.sh.*@: # lib.sh inlined by run-remote.sh@' "$SCRIPT"
  else
    cat "$SCRIPT"
  fi
}
{ printf '%s' "$preamble"; emit_body; } | ssh "${ssh_opts[@]}" "$TARGET" "$runner"
ok "finished $SCRIPT on $TARGET"
