#!/usr/bin/env bash
# Add an HTTP service (e.g. code-server) to the existing cloudflared tunnel as its
# own hostname, to be gated by a Cloudflare Access app. Regenerates the tunnel's
# config.yml with both the SSH and the HTTP ingress (idempotent), routes DNS, and
# restarts cloudflared. The Access application itself is created in the dashboard.
#
# RUN ON: the VM.
#   ./deploy/run-remote.sh __VM_NAME__ deploy/55-cloudflared-http.sh \
#       CF_HTTP_HOSTNAME=__CODE_HOSTNAME__ CODE_SERVER_PORT=8080
set -euo pipefail

CFG=/etc/cloudflared/config.yml
CF_SSH_HOSTNAME="${CF_SSH_HOSTNAME:-__SSH_HOSTNAME__}"
CF_HTTP_HOSTNAME="${CF_HTTP_HOSTNAME:?set CF_HTTP_HOSTNAME, e.g. __CODE_HOSTNAME__}"
CODE_SERVER_PORT="${CODE_SERVER_PORT:-8080}"

[ -f "$CFG" ] || { echo "no $CFG — run 30-cloudflared.sh first"; exit 1; }
UUID="$(awk '/^tunnel:/{print $2}' "$CFG")"
CRED="$(awk '/^credentials-file:/{print $2}' "$CFG")"
[ -n "$UUID" ] && [ -n "$CRED" ] || { echo "could not parse tunnel/credentials from $CFG"; exit 1; }

echo ">> writing $CFG with SSH + HTTP ($CF_HTTP_HOSTNAME -> :$CODE_SERVER_PORT) ingress"
cat > "$CFG" <<EOF
tunnel: $UUID
credentials-file: $CRED
ingress:
  - hostname: $CF_SSH_HOSTNAME
    service: ssh://localhost:22
  - hostname: $CF_HTTP_HOSTNAME
    service: http://localhost:$CODE_SERVER_PORT
  - service: http_status:404
EOF

echo ">> route DNS for $CF_HTTP_HOSTNAME"
cloudflared tunnel route dns "$UUID" "$CF_HTTP_HOSTNAME" || echo "   (route may already exist — continuing)"

echo ">> restart cloudflared"
systemctl restart cloudflared
sleep 1
systemctl is-active cloudflared && echo "cloudflared active"

echo
echo "Ingress now:"; sed -n '/ingress:/,$p' "$CFG"
echo
echo "Next: create a self-hosted Access app in the dashboard for $CF_HTTP_HOSTNAME"
echo "(GitHub IdP + the 'GitHub Authentication Specific' policy), then browse https://$CF_HTTP_HOSTNAME"
