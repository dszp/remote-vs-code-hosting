#!/usr/bin/env bash
# Optional — pre-create the persistent 'claude' tmux session on every boot, so
# `tmux attach -t claude` always succeeds even immediately after a reboot.
#
# Connectivity (tailscaled + sshd) already starts on boot on its own; this only
# adds a guaranteed-present *session*. It deliberately does NOT run `claude`
# (interactive; auto-running an agent unattended is out of scope for this box).
#
# RUN ON: the VM. run-remote uses sudo; we drop to the dev user for the --user unit.
#   ./deploy/run-remote.sh __DEV_USER__@<vm> deploy/60-session-boot.sh DEV_USER=__DEV_USER__
set -euo pipefail

DEV_USER="${DEV_USER:-__DEV_USER__}"
UID_N="$(id -u "$DEV_USER")"
RUN="XDG_RUNTIME_DIR=/run/user/${UID_N}"
UNIT_DIR="/home/$DEV_USER/.config/systemd/user"

echo ">> install user unit claude-session.service"
install -d "$UNIT_DIR"
# Ensure the whole ~/.config tree is owned by the dev user (install -d does not
# reliably chown pre-existing parents, which can leave ~/.config root-owned and
# break other user-level tools like code-server).
chown -R "$DEV_USER:$DEV_USER" "/home/$DEV_USER/.config"
cat > "$UNIT_DIR/claude-session.service" <<'UNIT'
[Unit]
Description=Persistent tmux session 'claude' (remote-vs-code)
After=default.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Idempotent: create the session only if it isn't already there. Never kills it.
ExecStart=/bin/sh -lc 'tmux has-session -t claude 2>/dev/null || tmux new -d -s claude'

[Install]
WantedBy=default.target
UNIT
chown "$DEV_USER:$DEV_USER" "$UNIT_DIR/claude-session.service"

# Linger lets the user manager (and thus this unit) run with no active login.
loginctl enable-linger "$DEV_USER"

echo ">> enable + start it"
sudo -u "$DEV_USER" env $RUN systemctl --user daemon-reload
sudo -u "$DEV_USER" env $RUN systemctl --user enable --now claude-session.service
sudo -u "$DEV_USER" env $RUN systemctl --user --no-pager status claude-session.service | head -n 6 || true

echo
echo "Done. After every boot, 'tmux attach -t claude' will work."
echo "Disable later with: systemctl --user disable --now claude-session.service"
