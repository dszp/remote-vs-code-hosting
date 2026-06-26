#!/usr/bin/env bash
# Phase 5 — Node + Claude Code on the VM, run as the dev user.
# RUN ON: the VM.
#   ./deploy/run-remote.sh __DEV_USER__@<vm> deploy/40-claude-code.sh DEV_USER=__DEV_USER__
#
# Installs nvm + Node for the dev user (keeps Node out of system paths) and the
# Claude Code CLI. The one-time `claude` login is interactive (OAuth) — do it in
# the tmux session afterwards; creds persist in ~/.claude.
set -euo pipefail

DEV_USER="${DEV_USER:-__DEV_USER__}"
# 'lts/*' works for install, alias, AND use ('--lts' is rejected by `nvm alias`).
NODE_VERSION="${NODE_VERSION:-lts/*}"

sudo -u "$DEV_USER" -H bash -s <<EOF
set -euo pipefail
export NVM_DIR="\$HOME/.nvm"
if [ ! -s "\$NVM_DIR/nvm.sh" ]; then
  echo ">> installing nvm"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
. "\$NVM_DIR/nvm.sh"

echo ">> installing Node ($NODE_VERSION)"
nvm install $NODE_VERSION
nvm alias default $NODE_VERSION
nvm use default

echo ">> installing Claude Code"
npm install -g @anthropic-ai/claude-code
claude --version || true

# Lock down the creds dir ahead of first login.
mkdir -p "\$HOME/.claude" && chmod 700 "\$HOME/.claude"

# Convenience alias: always land in the persistent session.
grep -q 'alias claudetmux=' "\$HOME/.bashrc" 2>/dev/null || \
  echo "alias claudetmux='tmux new -A -s claude'" >> "\$HOME/.bashrc"
EOF

cat <<EOF

Claude Code installed for $DEV_USER. Next (interactive, in the persistent session):
  ssh __DEV_USER__@<vm>            # or VS Code Remote-SSH terminal
  tmux new -A -s claude
  claude                    # log in once (OAuth); ~/.claude persists
Closing the laptop now leaves this tmux session — and any running 'claude' — alive.
EOF
