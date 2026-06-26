#!/usr/bin/env bash
# Phase 6 (optional) — code-server browser IDE, reachable in any browser.
# RUN ON: the VM. Native laptop VS Code stays primary; this is the browser path.
#   CODE_SERVER_PASSWORD="$(op read --account __OP_ACCOUNT__ 'op://__OP_VAULT__/__CODE_SERVER_PW_ITEM__/password')" \
#       ./deploy/run-remote.sh __VM_NAME__ deploy/50-code-server.sh DEV_USER=__DEV_USER__
#
# Model: code-server binds to loopback with password auth; expose it on its own
# hostname via Cloudflare Tunnel + Access (deploy/55-cloudflared-http.sh). The
# Tailscale-serve path is optional, gated behind EXPOSE_TAILSCALE=1.
set -euo pipefail

DEV_USER="${DEV_USER:-__DEV_USER__}"
CODE_SERVER_PORT="${CODE_SERVER_PORT:-8080}"
CODE_SERVER_PASSWORD="${CODE_SERVER_PASSWORD:?export CODE_SERVER_PASSWORD via op — adds a layer on top of Cloudflare Access}"

echo ">> install code-server"
command -v code-server >/dev/null 2>&1 || curl -fsSL https://code-server.dev/install.sh | sh

echo ">> write config (loopback bind, password auth) for $DEV_USER"
# Done as root (this script's context) so it works regardless of prior ownership,
# then chowned back to the dev user — code-server runs as $DEV_USER and must own
# ~/.config (and ~/.local) to write its config/data/extensions.
CFG_DIR="/home/$DEV_USER/.config/code-server"
mkdir -p "$CFG_DIR"
cat > "$CFG_DIR/config.yaml" <<CFG
bind-addr: 127.0.0.1:${CODE_SERVER_PORT}
auth: password
password: ${CODE_SERVER_PASSWORD}
cert: false
CFG
chmod 600 "$CFG_DIR/config.yaml"
chown -R "$DEV_USER:$DEV_USER" "/home/$DEV_USER/.config" "/home/$DEV_USER/.local" 2>/dev/null || true

echo ">> enable code-server as a per-user service (survives logout via linger)"
systemctl enable --now "code-server@${DEV_USER}"

# Optional: publish over Tailscale HTTPS (off by default; we expose via Cloudflare
# Tunnel + Access instead — see 55-cloudflared-http.sh). Enable with EXPOSE_TAILSCALE=1.
if [ "${EXPOSE_TAILSCALE:-0}" = "1" ]; then
  echo ">> publish over Tailscale (HTTPS on the tailnet)"
  tailscale serve --bg --https=443 "http://127.0.0.1:${CODE_SERVER_PORT}" || \
    echo "   tailscale serve failed (enable MagicDNS + HTTPS certs in the tailnet admin console)"
fi

cat <<EOF

code-server is installed and listening on 127.0.0.1:${CODE_SERVER_PORT} (loopback only).
Expose it to the browser via Cloudflare Tunnel + Access:
  ./deploy/run-remote.sh __VM_NAME__ deploy/55-cloudflared-http.sh CF_HTTP_HOSTNAME=<host> CODE_SERVER_PORT=${CODE_SERVER_PORT}
Its integrated terminal can 'tmux attach -t claude' — same session as the laptop.
EOF
