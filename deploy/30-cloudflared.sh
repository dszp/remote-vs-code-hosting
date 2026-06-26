#!/usr/bin/env bash
# Phase 3 (server side) — Cloudflare Tunnel for SSH (secondary transport).
# RUN ON: the VM.
#   ./deploy/run-remote.sh __DEV_USER__@<vm> deploy/30-cloudflared.sh CF_TUNNEL_NAME=__VM_NAME__ CF_HOSTNAME=__SSH_HOSTNAME__
#
# `cloudflared tunnel login` is interactive (browser, __CF_ACCOUNT__ CF account) and is
# left as a manual step the first time — see the prompt below. Everything else is
# scripted and idempotent. The Access application + service token are created in the
# Cloudflare dashboard (see README) — not here.
set -euo pipefail

CF_TUNNEL_NAME="${CF_TUNNEL_NAME:-__VM_NAME__}"
CF_HOSTNAME="${CF_HOSTNAME:-__SSH_HOSTNAME__}"

echo ">> install cloudflared"
if ! command -v cloudflared >/dev/null 2>&1; then
  curl -fsSL -o /tmp/cloudflared.rpm \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-x86_64.rpm
  dnf install -y /tmp/cloudflared.rpm
fi

# cert.pem is produced by `cloudflared tunnel login`; without it we cannot create tunnels.
if [ ! -f /root/.cloudflared/cert.pem ] && [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
  cat <<EOF

  INTERACTIVE STEP REQUIRED (run once, on the VM):
      sudo cloudflared tunnel login
  Pick the __CF_ACCOUNT__ account / __BASE_DOMAIN__ zone in the browser it opens, then re-run this script.
EOF
  exit 2
fi

mkdir -p /etc/cloudflared

echo ">> create tunnel '$CF_TUNNEL_NAME' (if absent)"
if ! cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -qx "$CF_TUNNEL_NAME"; then
  cloudflared tunnel create "$CF_TUNNEL_NAME"
fi
UUID="$(cloudflared tunnel list 2>/dev/null | awk -v n="$CF_TUNNEL_NAME" '$2==n{print $1}')"
[ -n "$UUID" ] || { echo "could not resolve tunnel UUID"; exit 1; }
echo "   tunnel UUID: $UUID"

# Move the per-tunnel credentials JSON into /etc/cloudflared for the system service.
for d in /root/.cloudflared "$HOME/.cloudflared"; do
  if [ -f "$d/$UUID.json" ]; then install -m 0600 "$d/$UUID.json" "/etc/cloudflared/$UUID.json"; fi
done

echo ">> write /etc/cloudflared/config.yml"
cat > /etc/cloudflared/config.yml <<EOF
tunnel: $UUID
credentials-file: /etc/cloudflared/$UUID.json
ingress:
  - hostname: $CF_HOSTNAME
    service: ssh://localhost:22
  - service: http_status:404
EOF

echo ">> route DNS $CF_HOSTNAME -> tunnel"
cloudflared tunnel route dns "$CF_TUNNEL_NAME" "$CF_HOSTNAME" || \
  echo "   (route may already exist — continuing)"

echo ">> install + start the cloudflared system service"
cloudflared --config /etc/cloudflared/config.yml service install || true
systemctl enable --now cloudflared
systemctl status --no-pager cloudflared | head -n 5 || true

cat <<EOF

Server side done. Remaining (dashboard, see README):
  1. Create a self-hosted Access application for $CF_HOSTNAME.
  2. Policy 1: allow your email (browser auth).  Policy 2: Service Auth -> a scoped service token.
Then on the laptop add the 'Host dev-cf' ~/.ssh/config entry (config/ssh-config.snippet).
EOF
