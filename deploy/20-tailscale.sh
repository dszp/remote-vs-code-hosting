#!/usr/bin/env bash
# Phase 2 — Tailscale (primary transport) + mosh path.
# RUN ON: the VM.
#   # interactive (browser auth):
#   ./deploy/run-remote.sh __DEV_USER__@<vm> deploy/20-tailscale.sh
#   # non-interactive (auth key from 1Password):
#   TS_AUTHKEY="$(op read 'op://__OP_VAULT__/Tailscale/authkey')" \
#       ./deploy/run-remote.sh __DEV_USER__@<vm> deploy/20-tailscale.sh
set -euo pipefail

echo ">> install tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled

echo ">> bring tailscale up"
if [ -n "${TS_AUTHKEY:-}" ]; then
  tailscale up --authkey "$TS_AUTHKEY" --ssh=false
else
  echo "   no TS_AUTHKEY set — starting interactive login."
  echo "   Open the URL it prints to authorize this node in your tailnet."
  tailscale up --ssh=false
fi

# mosh needs UDP 60000-61000; carried natively over the tailnet (10-base opened it in firewalld).
echo ">> tailscale status:"
tailscale status || true
echo ">> this node's tailnet addresses:"
tailscale ip -4 || true
echo
echo "Use the MagicDNS name (or the 100.x IP) as 'HostName' in the laptop ~/.ssh/config 'Host dev' entry."
