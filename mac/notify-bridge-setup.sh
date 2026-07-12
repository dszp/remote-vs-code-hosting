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
# %n = the host alias as typed on the command line (expanded by ssh) -> each alias binds its
# OWN socket on the VM, and the VM hook tries every mac-*.sock, so one dead connection can't
# kill the bridge. Use %n, NOT %C: %C hashes the resolved HostName+port+user, so aliases that
# share a HostName (__VM_SSH_ALIAS__ and __VM_NAME__ both point at the same IP) would collide on one socket.
VM_SOCK="/home/$DEV_USER/.notify/mac-%n.sock"

command -v terminal-notifier >/dev/null || brew install terminal-notifier
command -v socat >/dev/null || brew install socat
NOTIFIER="$(command -v terminal-notifier)"
SOCAT="$(command -v socat)"

echo ">> writing the listener in $NOTIFY_DIR"
mkdir -p "$NOTIFY_DIR"
cat > "$NOTIFY_DIR/show.sh" <<SHOW
#!/bin/bash
# Per-connection: read ONE line of space-separated base64 fields and pop a notification.
#   title subtitle message url [tmux-session]     (older senders omit the 5th field)
read -r b_title b_sub b_msg b_url b_sess
dec() { [ -n "\$1" ] && printf '%s' "\$1" | base64 -D 2>/dev/null || true; }
title="\$(dec "\$b_title")"; sub="\$(dec "\$b_sub")"; msg="\$(dec "\$b_msg")"; url="\$(dec "\$b_url")"; sess="\$(dec "\$b_sess")"
[ -z "\$title" ] && title="Claude Code"; [ -z "\$msg" ] && msg="needs your attention"
args=(-title "\$title" -message "\$msg" -sound Glass -group claude-remote)
[ -n "\$sub" ] && args+=(-subtitle "\$sub")
# Click action: with a tmux session name, click.sh focuses a matching Ghostty tab and
# only falls back to the url (native VS Code); without one, open the url as before.
if [ -n "\$sess" ]; then
  args+=(-execute "$NOTIFY_DIR/click.sh '\$b_url' '\$b_sess'")
elif [ -n "\$url" ]; then
  args+=(-open "\$url")
fi
"$NOTIFIER" "\${args[@]}" >/dev/null 2>&1 || true
SHOW
chmod 700 "$NOTIFY_DIR/show.sh"

echo ">> writing the click handler $NOTIFY_DIR/click.sh"
cat > "$NOTIFY_DIR/click.sh" <<'CLICK'
#!/bin/bash
# Notification click action: focus the Ghostty tab attached to the notifying tmux
# session, else open the url (native VS Code). args: <b64 url> <b64 session>.
# The VM's tmux titles every client "<session> · <host>" (set-titles, config/tmux.conf),
# so a prefix match on "<session> · " finds the right tab — and misses entirely when the
# session only lives in a VS Code terminal, which is exactly the fallback case. Needs
# Ghostty >= 1.3.1 for the AppleScript dictionary (a 1.3 preview API — revisit on 1.4).
dec() { [ -n "$1" ] && printf '%s' "$1" | base64 -D 2>/dev/null || true; }
url="$(dec "$1")"; sess="$(dec "$2")"
if [ -n "$sess" ] && pgrep -xiq ghostty; then
  # pgrep guard: `tell application "Ghostty"` would LAUNCH Ghostty if it weren't running.
  # If several tabs show the session (stale title after a detach), first match wins.
  if /usr/bin/osascript - "$sess" >/dev/null 2>&1 <<'OSA'
on run argv
	set sessPrefix to (item 1 of argv) & " · "
	tell application "Ghostty"
		set matches to every terminal whose name starts with sessPrefix
		if (count of matches) is 0 then error "no tab attached to that session"
		focus item 1 of matches
		activate
	end tell
end run
OSA
  then exit 0; fi
fi
[ -n "$url" ] && open "$url"
exit 0
CLICK
chmod 700 "$NOTIFY_DIR/click.sh"

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

>> ADD this line under EVERY 'Host' you reach the VM with (__VM_NAME__, __VM_SSH_ALIAS__,
   __VM_NAME__-cf — see config/ssh-config.snippet), alongside the op-resolver forward,
   then reconnect:

      RemoteForward $VM_SOCK $MAC_SOCK
      StreamLocalBindUnlink yes

   Then run deploy/85-notify-hook.sh on the VM to install the Claude hook + push config.
   Test (from a Mac-originated VM session):
      printf '%s' '{"message":"bridge test"}' | ~/.claude/notify-remote.sh

   Clicking a notification focuses the Ghostty tab attached to Claude's tmux session
   (Ghostty >= 1.3.1), falling back to native VS Code (vscode://) when no tab matches.
   The FIRST such click prompts once for Automation permission — approve
   terminal-notifier -> Ghostty in System Settings > Privacy & Security > Automation.
EOF
