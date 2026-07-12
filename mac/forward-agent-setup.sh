#!/usr/bin/env bash
# Always-on carrier for the op resolver + notify bridge. Run ON YOUR MAC.
#
# The op proxy (mac mode) and the notify bridge only work while a LIVE Mac->VM SSH
# connection is holding their RemoteForward'd sockets open. A VS Code Remote-SSH window
# does NOT count: reloading/reconnecting it reuses the multiplexed connection or reattaches
# to the running remote server WITHOUT re-binding a forward, so the sockets on the VM are
# orphaned files and `op read` fails with "no live resolver socket". Interactive terminals
# and mosh are just as unreliable (mosh can't forward unix sockets at all).
#
# This installs a dedicated LaunchAgent that holds `ssh -N __VM_NAME__-fwd` open, so op/notify
# have a live socket whenever the Mac is online — independent of VS Code, terminals, or mosh.
# launchd KeepAlive + ssh ServerAliveInterval mean it self-heals: a dropped link (sleep,
# network change, Tailscale blip) exits ssh and launchd relaunches it; on resume it rebinds.
# It rides Tailscale (like your other silent hosts); when Tailscale is fully down it simply
# falls back — op to `op-mode token`, notify to Pushover — and reconnects when Tailscale is back.
#
#   ./mac/forward-agent-setup.sh
# Override defaults via env: FWD_HOST, SSH_HOST, KEY_PATH, DEV_USER.
#
# Prereqs: mac/vm-alias-key-setup.sh (the silent key this reuses), mac/op-resolver-setup.sh,
# and mac/notify-bridge-setup.sh (the Mac-side sockets this forwards to).
set -euo pipefail

FWD_HOST="${FWD_HOST:-__VM_NAME__-fwd}"     # the new forward-only alias this agent connects as
SSH_HOST="${SSH_HOST:-__VM_NAME__}"         # existing Host used only to derive the VM's HostName
KEY_PATH="${KEY_PATH:-$HOME/.ssh/__VM_SSH_ALIAS___ed25519}"   # silent key from vm-alias-key-setup.sh
DEV_USER="${DEV_USER:-__DEV_USER__}"            # login user on the VM (its socket paths)
LABEL="com.__MAC_USER__.__VM_NAME__-forward"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$LABEL.log"

[ -f "$KEY_PATH" ] || { echo "!! $KEY_PATH missing — run mac/vm-alias-key-setup.sh first"; exit 1; }

# Derive the VM's real HostName from the existing Host so we don't hardcode an IP.
VM_HOSTNAME="$(ssh -G "$SSH_HOST" 2>/dev/null | awk '/^hostname /{print $2; exit}')"
[ -n "$VM_HOSTNAME" ] || { echo "!! couldn't derive HostName from Host '$SSH_HOST'"; exit 1; }

echo ">> LaunchAgent $LABEL (ssh -N $FWD_HOST)"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/ssh</string>
    <string>-N</string>
    <string>$FWD_HOST</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>StandardOutPath</key><string>$LOG</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

cat <<EOF

>> ADD this block to ~/.ssh/config, ABOVE your 'Host *' block (ssh_config is first-match,
   so 'IdentityAgent none' must win over any agent set under 'Host *'). %n expands to the
   alias '$FWD_HOST', so it binds its OWN mac-$FWD_HOST.sock on the VM — distinct from your
   interactive __VM_SSH_ALIAS__/__VM_NAME__ sockets, no collision:

  Host $FWD_HOST
    HostName $VM_HOSTNAME
    User $DEV_USER
    IdentityAgent none
    IdentityFile $KEY_PATH
    IdentitiesOnly yes
    UseKeychain yes
    ConnectTimeout 15
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
    RemoteForward /home/$DEV_USER/.op-proxy/mac-%n.sock $HOME/.op-resolver/resolver.sock
    RemoteForward /home/$DEV_USER/.notify/mac-%n.sock $HOME/.notify/notify.sock
    StreamLocalBindUnlink yes

   The agent is already running and retries every 30s (ThrottleInterval), so it connects
   as soon as the block is in place (KeepAlive rides out the gap). Verify:
      launchctl list | grep $LABEL          # column 1 = pid (running), column 2 = last exit
      op-mode status                          # on the VM: 'mac sockets' >= 1 with the Mac online
   Tear down:  launchctl bootout gui/\$(id -u)/$LABEL && rm $PLIST
EOF
