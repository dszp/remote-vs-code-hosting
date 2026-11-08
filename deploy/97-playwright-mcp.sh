#!/usr/bin/env bash
# One shared Playwright MCP server for every Claude Code session on the box.
# RUN ON: the VM. run-remote sudo's; the units themselves are per-user (see below).
#   ./deploy/run-remote.sh __VM_NAME__ deploy/97-playwright-mcp.sh DEV_USER=__DEV_USER__
#
# WHY: Claude Code spawns every stdio MCP server at session start, so the playwright plugin
# put a safe-chain + node pair in EACH session — 19 of them on 2026-10-04, ~1.5 GB of RAM+swap,
# nearly all idle. A remote HTTP server is different: once Claude Code has cached its tool
# list it connects only when a session first calls a playwright tool. One idle server
# replaces N, and Chromium starts only when something actually drives a browser.
#
# UPDATES: Chromium ships inside each playwright-core release (no system Chrome here), so
# freezing the package freezes the browser and its security fixes. Every start runs
# `npm install @playwright/mcp@latest` through safe-chain, and a timer restarts the service
# nightly at 05:00 America/New_York. The install step is allowed to fail (offline boot) —
# the service then starts on the version already installed.
#
# USER units, not system ones: SELinux (enforcing) forbids a system service from executing
# user_home_t files, and both nvm's node and safe-chain live in $HOME. The first cut as a
# system unit died with 203/EXEC "Permission denied". DEV_USER has linger, so the user
# manager — and this service — still starts at boot without a login.
#
# --allowed-hosts: the DNS-rebinding guard checks the Host header and by default admits only
# "localhost:PORT"; Claude Code uses the literal 127.0.0.1 (no ::1 surprise), so admit exactly that.
#
# --isolated: in HTTP mode every client gets its own browser context, but a persistent
# profile can only be opened by one browser at a time, so concurrent sessions would fight
# over it. Isolated profiles live in memory: no cookies or logins survive a session.
#
# After this, disable the playwright plugin and point Claude Code at the URL (user scope):
#   playwright -> {"type":"http","url":"http://127.0.0.1:8931/mcp"}
# Tool names change from mcp__plugin_playwright_playwright__* to mcp__playwright__*.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="/home/$DEV_USER"
PORT="${PLAYWRIGHT_MCP_PORT:-8931}"
PREFIX="$HOME_DIR/.local/share/playwright-mcp"
SAFE_CHAIN="$HOME_DIR/.safe-chain/bin/safe-chain"

# nvm's node, resolved now from the user's login shell. A systemd unit gets no nvm, so the
# bin dir is baked into PATH — re-run this script after switching the default node.
NODE_BIN="$(runuser -u "$DEV_USER" -- bash -lc 'dirname "$(command -v node)"')"
[ -x "$NODE_BIN/node" ] || die "no node for $DEV_USER (nvm installed?)"
[ -x "$SAFE_CHAIN" ] || die "safe-chain missing at $SAFE_CHAIN — refusing to npm install unscanned"
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0755 "$PREFIX"

UNIT_DIR="$HOME_DIR/.config/systemd/user"
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0755 "$UNIT_DIR"
[ "$(loginctl show-user "$DEV_USER" -p Linger --value 2>/dev/null)" = yes ] \
  || { loginctl enable-linger "$DEV_USER"; log "enabled linger for $DEV_USER (user units start at boot)"; }

log "installing user unit playwright-mcp.service (127.0.0.1:$PORT, node from $NODE_BIN)"
cat > "$UNIT_DIR/playwright-mcp.service" <<UNIT
[Unit]
Description=Shared Playwright MCP server for Claude Code (127.0.0.1:$PORT)
After=network-online.target

[Service]
Environment=PATH=$NODE_BIN:/usr/local/bin:/usr/bin:/bin
# Pull the newest release (and with it the newest Chromium). "-": an offline start keeps
# the installed version rather than failing.
ExecStartPre=-$SAFE_CHAIN npm install --prefix $PREFIX --no-fund --no-audit --loglevel=error @playwright/mcp@latest
ExecStart=$NODE_BIN/node $PREFIX/node_modules/@playwright/mcp/cli.js --host 127.0.0.1 --port $PORT --allowed-hosts 127.0.0.1:$PORT --headless --isolated
TimeoutStartSec=300
Restart=on-failure
RestartSec=5
MemoryHigh=2G
MemoryMax=3G

[Install]
WantedBy=default.target
UNIT

cat > "$UNIT_DIR/playwright-mcp-restart.service" <<'UNIT'
[Unit]
Description=Restart the shared Playwright MCP server to pick up a new release

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl --user try-restart playwright-mcp.service
UNIT

cat > "$UNIT_DIR/playwright-mcp-restart.timer" <<'UNIT'
[Unit]
Description=Nightly 05:00 Eastern restart of the shared Playwright MCP server

[Timer]
OnCalendar=*-*-* 05:00:00 America/New_York

[Install]
WantedBy=timers.target
UNIT
chown "$DEV_USER:$DEV_USER" "$UNIT_DIR"/playwright-mcp*

uctl() { runuser -u "$DEV_USER" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$DEV_USER")" systemctl --user "$@"; }
uctl daemon-reload
uctl enable playwright-mcp.service
uctl enable --now playwright-mcp-restart.timer
uctl restart playwright-mcp.service
ok "playwright-mcp on http://127.0.0.1:$PORT/mcp; next restart: $(uctl show playwright-mcp-restart.timer -p NextElapseUSecRealtime --value)"
