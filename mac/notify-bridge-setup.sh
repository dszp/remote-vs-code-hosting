#!/usr/bin/env bash
# Mac side of the remote notify bridge: lets Claude Code running ON THE VM raise a
# native macOS notification on this laptop (terminal-notifier), and — when the laptop
# is offline — fall back to a push service. Pairs with deploy/85-notify-hook.sh on the VM.
# Run ON YOUR MAC.
#
#   ./mac/notify-bridge-setup.sh
# Override defaults via env: SSH_HOST, DEV_USER, NOTIFY_DIR.
#
# How it works (same trust model as the op resolver): your Mac->VM SSH connection
# RemoteForwards the VM's ~/.notify/mac.sock back to a socket here, where a tiny socat
# LaunchAgent runs terminal-notifier. No inbound to the Mac; nothing stored on the VM.
# Because the forwarded socket only exists while you're connected, a VM-side delivery
# failure == "laptop offline" — which is exactly when the VM hook switches to push.
set -euo pipefail

SSH_HOST="${SSH_HOST:-__VM_NAME__}"        # the ~/.ssh/config Host(s) to RemoteForward from
DEV_USER="${DEV_USER:-__DEV_USER__}"           # login user on the VM (its socket path)
NOTIFY_DIR="${NOTIFY_DIR:-$HOME/.notify}"
MAC_SOCK="$NOTIFY_DIR/notify.sock"
VM_SOCK="/home/$DEV_USER/.notify/mac.sock"

command -v terminal-notifier >/dev/null || brew install terminal-notifier
command -v socat >/dev/null || brew install socat
NOTIFIER="$(command -v terminal-notifier)"
SOCAT="$(command -v socat)"

echo ">> writing the listener in $NOTIFY_DIR"
mkdir -p "$NOTIFY_DIR"
cat > "$NOTIFY_DIR/show.sh" <<SHOW
#!/bin/bash
# Per-connection: read ONE line of 4 space-separated base64 fields and pop a notification.
#   title subtitle message url
read -r b_title b_sub b_msg b_url
dec() { [ -n "\$1" ] && printf '%s' "\$1" | base64 -D 2>/dev/null || true; }
title="\$(dec "\$b_title")"; sub="\$(dec "\$b_sub")"; msg="\$(dec "\$b_msg")"; url="\$(dec "\$b_url")"
[ -z "\$title" ] && title="Claude Code"; [ -z "\$msg" ] && msg="needs your attention"
args=(-title "\$title" -message "\$msg" -sound Glass -group claude-remote)
[ -n "\$sub" ] && args+=(-subtitle "\$sub")
[ -n "\$url" ] && args+=(-open "\$url")
"$NOTIFIER" "\${args[@]}" >/dev/null 2>&1 || true
SHOW
chmod 700 "$NOTIFY_DIR/show.sh"

echo ">> LaunchAgent (socat listener on $MAC_SOCK)"
PLIST="$HOME/Library/LaunchAgents/com.__MAC_USER__.notify-bridge.plist"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.__MAC_USER__.notify-bridge</string>
  <key>ProgramArguments</key><array>
    <string>$SOCAT</string>
    <string>UNIX-LISTEN:$MAC_SOCK,fork,mode=0600,unlink-early</string>
    <string>EXEC:$NOTIFY_DIR/show.sh</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$NOTIFY_DIR/bridge.err.log</string>
  <key>StandardOutPath</key><string>$NOTIFY_DIR/bridge.out.log</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/com.__MAC_USER__.notify-bridge" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

cat <<EOF

>> ADD this line under EVERY 'Host' you reach the VM with (__VM_NAME__, autodev,
   __VM_NAME__-cf — see config/ssh-config.snippet), alongside the op-resolver forward,
   then reconnect:

      RemoteForward $VM_SOCK $MAC_SOCK
      StreamLocalBindUnlink yes

   Then run deploy/85-notify-hook.sh on the VM to install the Claude hook + push config.
   Test (from a Mac-originated VM session):
      printf '%s' '{"message":"bridge test"}' | ~/.claude/notify-remote.sh
EOF
