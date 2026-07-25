#!/usr/bin/env bash
# Optional — pre-create the persistent sessions on every boot, so attaching always
# succeeds even immediately after a reboot:
#   claude-session.service  the 'claude' tmux session (`tmux attach -t claude`)
#   herdr-session.service   the headless herdr server  (`herdr` / `mux herdr`)
# The herdr unit is installed only if herdr is present; it is what makes herdr's
# saved session shape (workspaces/tabs/panes/cwd/layout) come back after a reboot
# without you attaching first.
#
# Connectivity (tailscaled + sshd) already starts on boot on its own; this only
# adds guaranteed-present *sessions*. It deliberately does NOT run `claude`
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

# --- herdr: the headless server, only if herdr is installed -------------------
# `herdr server` is the daemon that OWNS the pane PTYs — your shells and agents
# are its children, which is why they outlive the terminal you started them from.
# It also restores the saved session shape (~/.config/herdr/session.json) on
# start, so at boot the panes are rebuilt and running before anyone attaches.
# NOTE it runs in the FOREGROUND and never returns, so unlike the tmux unit above
# this is Type=simple, NOT oneshot — a oneshot ExecStart that never exits leaves
# the unit stuck in "activating (start)" until the start timeout fires, even
# though the server itself is up and working.
HERDR_BIN="/home/$DEV_USER/.local/bin/herdr"
if [ -x "$HERDR_BIN" ]; then
  echo ">> install user unit herdr-session.service"
  cat > "$UNIT_DIR/herdr-session.service" <<'UNIT'
[Unit]
Description=Persistent herdr server (remote-vs-code)
After=default.target

[Service]
Type=simple
# Absolute path — a non-interactive sh has no reason to have ~/.local/bin on PATH.
ExecStart=%h/.local/bin/herdr server
# A `herdr server stop` (or `mux`-driven shutdown) is a clean exit, so on-failure
# won't fight you; a crash does get picked back up.
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  chown "$DEV_USER:$DEV_USER" "$UNIT_DIR/herdr-session.service"

  # NAMED sessions (the per-workspace ones deploy/65-auto-attach.sh creates) live on
  # their own sockets under ~/.config/herdr/sessions/<name>/ and are NOT covered by the
  # unit above, which owns 'default' only. Without this they exist only on demand: the
  # first VS Code terminal for a workspace creates one, and a reboot loses it. This
  # TEMPLATE makes any of them a boot service:
  #     systemctl --user enable herdr-session@myproject.service
  # Enable (no --now) is the right verb when the session is already running on demand:
  # starting it would collide on the socket, whereas enable just takes effect next boot.
  echo ">> install user unit template herdr-session@.service"
  cat > "$UNIT_DIR/herdr-session@.service" <<'UNIT'
[Unit]
Description=Persistent herdr server for session '%i' (remote-vs-code)
After=default.target

[Service]
Type=simple
# Foreground, like the default-session unit — see the note there on why not oneshot.
# herdr session names are limited to letters, numbers, '.', '_' and '-', all of which
# are safe unescaped in a systemd instance name, so %i needs no unescaping.
ExecStart=%h/.local/bin/herdr --session %i server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  chown "$DEV_USER:$DEV_USER" "$UNIT_DIR/herdr-session@.service"
else
  echo ">> herdr not installed at $HERDR_BIN — skipping herdr-session units"
fi

# Linger lets the user manager (and thus these units) run with no active login.
loginctl enable-linger "$DEV_USER"

echo ">> enable + start"
sudo -u "$DEV_USER" env $RUN systemctl --user daemon-reload
sudo -u "$DEV_USER" env $RUN systemctl --user enable --now claude-session.service
sudo -u "$DEV_USER" env $RUN systemctl --user --no-pager status claude-session.service | head -n 6 || true
if [ -x "$HERDR_BIN" ]; then
  sudo -u "$DEV_USER" env $RUN systemctl --user enable --now herdr-session.service
  sudo -u "$DEV_USER" env $RUN systemctl --user --no-pager status herdr-session.service | head -n 6 || true

  # Enable the template for every named session that already exists, so the set of
  # persistent sessions matches the set you actually use. `enable` only (no --now):
  # these are typically already running on demand and would collide on their socket.
  named="$(sudo -u "$DEV_USER" env $RUN "$HERDR_BIN" session list 2>/dev/null \
            | awk 'NR>1 && $1!="default" && $1!="" {print $1}')"
  for s in $named; do
    sudo -u "$DEV_USER" env $RUN systemctl --user enable "herdr-session@${s}.service" >/dev/null 2>&1 \
      && echo ">> enabled herdr-session@${s}.service (takes effect next boot)" \
      || echo "!! could not enable herdr-session@${s}.service" >&2
  done
  [ -z "$named" ] && echo ">> no named herdr sessions yet — enable later with: systemctl --user enable herdr-session@<name>.service"
fi

echo
echo "Done. After every boot, 'tmux attach -t claude' will work."
[ -x "$HERDR_BIN" ] && echo "             and 'herdr' will attach an already-running server."
echo "Disable later with: systemctl --user disable --now claude-session.service"
[ -x "$HERDR_BIN" ] && echo "                    systemctl --user disable --now herdr-session.service"
