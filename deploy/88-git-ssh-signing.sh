#!/usr/bin/env bash
# Git SSH signing on the VM with the key that stays in 1Password on the Mac. Idempotent.
#
# The Mac's always-on carrier (mac/forward-agent-setup.sh, `ssh -N __VM_NAME__-fwd`) forwards
# the Mac's signing filter (mac/1p-sign-filter-setup.sh — exposes only the signing key from
# the 1Password agent) to ~/.ssh/mac-1p-agent.sock. Git signs through it with
# `ssh-keygen -Y sign`, so each signature is a TouchID prompt on the Mac and the private key
# never leaves 1Password. With the Mac offline, signing fails with a clear message instead
# of falling back to anything else.
#
# Sets, in the dev user's GLOBAL git config: gpg.format=ssh, user.signingkey (the public
# key, inline), gpg.ssh.program (the wrapper below), gpg.ssh.allowedSignersFile (so
# `git tag -v` / `git log --show-signature` verify locally), and tag.gpgsign=true.
# commit.gpgsign is left alone: Claude commits often, and a TouchID per commit (or a
# failed commit whenever the Mac is asleep) isn't wanted by default — opt in per repo with
# `git config commit.gpgsign true`.
#
# RUN ON: the VM (as root via run-remote, or directly as the dev user).
#   ./deploy/run-remote.sh __VM_NAME__ deploy/88-git-ssh-signing.sh DEV_USER=__DEV_USER__ \
#       SIGNING_PUBKEY="ssh-ed25519 AAAA…"
# SIGNING_PUBKEY is the PUBLIC half of the 1Password signing key (not a secret).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="/home/$DEV_USER"
require_env SIGNING_PUBKEY
[[ "$SIGNING_PUBKEY" =~ ^(ssh-ed25519|ecdsa-sha2-nistp[0-9]+|ssh-rsa)\ [A-Za-z0-9+/=]+$ ]] \
  || die "SIGNING_PUBKEY must be '<type> <base64>' (no comment, no private key)"

as_user() { if [ "$(id -un)" = "$DEV_USER" ]; then "$@"; else sudo -u "$DEV_USER" -H "$@"; fi; }
need ssh-keygen; need git

SIGNER="$HOME_DIR/.local/bin/git-ssh-sign-1p"
log "writing $SIGNER"
as_user install -d -m 700 "$HOME_DIR/.local/bin" "$HOME_DIR/.config/git"
as_user tee "$SIGNER" >/dev/null <<'WRAP'
#!/usr/bin/env bash
# gpg.ssh.program for git: ssh-keygen against the 1Password agent forwarded from the Mac
# (deploy/88-git-ssh-signing.sh). Verification needs no agent; signing does.
sock="$HOME/.ssh/mac-1p-agent.sock"
case " $* " in
  *" -Y sign "*)
    SSH_AUTH_SOCK="$sock" timeout 5 ssh-add -l >/dev/null 2>&1
    if [ $? -ge 2 ]; then   # 0 = keys listed, 1 = agent up but empty; 2+ = no agent
      echo "git-ssh-sign-1p: no live 1Password agent at $sock." >&2
      echo "  Is the Mac online, with __VM_NAME__-fwd forwarding the agent? (mac/forward-agent-setup.sh)" >&2
      exit 1
    fi ;;
esac
export SSH_AUTH_SOCK="$sock"
exec ssh-keygen "$@"
WRAP
as_user chmod 755 "$SIGNER"

EMAIL="$(as_user git config --global user.email || true)"
[ -n "$EMAIL" ] || die "set the dev user's global git user.email first"
SIGNERS="$HOME_DIR/.config/git/allowed_signers"
log "writing $SIGNERS"
printf '%s %s\n' "$EMAIL" "$SIGNING_PUBKEY" | as_user tee "$SIGNERS" >/dev/null

log "configuring global git signing for $DEV_USER"
as_user git config --global gpg.format ssh
as_user git config --global user.signingkey "key::$SIGNING_PUBKEY"
as_user git config --global gpg.ssh.program "$SIGNER"
as_user git config --global gpg.ssh.allowedSignersFile "$SIGNERS"
as_user git config --global tag.gpgsign true

if [ -S "$HOME_DIR/.ssh/mac-1p-agent.sock" ]; then
  ok "agent socket present — test: echo test | ssh-keygen -Y sign -n file -f <(echo \"$SIGNING_PUBKEY\") (TouchID on the Mac)"
else
  warn "no ~/.ssh/mac-1p-agent.sock yet — add the agent RemoteForward from mac/forward-agent-setup.sh on the Mac"
fi
ok "git SSH signing configured (tags sign by default; commits opt-in per repo)"
