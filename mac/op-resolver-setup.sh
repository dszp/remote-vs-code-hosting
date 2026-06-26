#!/usr/bin/env bash
# Mac side of the reverse op resolver. Run ON YOUR MAC. Pairs with deploy/80-op-proxy.sh
# on the VM: your Mac->VM SSH connection forwards the VM's ~/.op-proxy/mac.sock back to a
# small `op read`-only resolver here, so the VM resolves secrets via TouchID with NO
# inbound to the Mac (works with shields-up + the sandboxed App Store Tailscale).
#
#   ./mac/op-resolver-setup.sh
# Override defaults via env: OP_ACCOUNT, SSH_HOST, VM_SOCK.
set -euo pipefail

OP_ACCOUNT="${OP_ACCOUNT:-__OP_ACCOUNT__}"   # which 1Password account (you have several)
SSH_HOST="${SSH_HOST:-__VM_NAME__}"                    # the ~/.ssh/config Host to add RemoteForward to
VM_SOCK="${VM_SOCK:-/home/__DEV_USER__/.op-proxy/mac.sock}"   # socket path ON THE VM (matches DEV_USER there)
DIR="$HOME/.op-resolver"
MAC_SOCK="$DIR/resolver.sock"

OP="$(command -v op || echo /opt/homebrew/bin/op)"
command -v socat >/dev/null || brew install socat
SOCAT="$(command -v socat)"

echo ">> writing resolver scripts in $DIR"
mkdir -p "$DIR"
cat > "$DIR/resolve.sh" <<RESOLVE
#!/bin/bash
# Per-connection: read ONE op:// ref on stdin, return the secret. op read only; logged.
set -euo pipefail
OP="$OP"; OP_ACCOUNT="$OP_ACCOUNT"; LOG="\$HOME/.op-resolver/access.log"
IFS= read -r ref || exit 0; ref="\${ref%\$'\r'}"; ts="\$(date '+%Y-%m-%d %H:%M:%S')"
case "\$ref" in op://*) ;; *) printf 'ERR not-an-op-ref\n'; printf '%s DENY %s\n' "\$ts" "\$ref" >> "\$LOG"; exit 0 ;; esac
if [ "\${#ref}" -gt 512 ] || printf '%s' "\$ref" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  printf 'ERR bad-ref\n'; printf '%s DENY(bad) %s\n' "\$ts" "\$ref" >> "\$LOG"; exit 0; fi
if val="\$("\$OP" read --account "\$OP_ACCOUNT" -- "\$ref" 2>/dev/null)"; then
  printf '%s\n' "\$val"; printf '%s OK   %s\n' "\$ts" "\$ref" >> "\$LOG"
else printf 'ERR op-read-failed\n'; printf '%s FAIL %s\n' "\$ts" "\$ref" >> "\$LOG"; fi
RESOLVE
cat > "$DIR/listen.sh" <<LISTEN
#!/bin/bash
set -euo pipefail
SOCK="$MAC_SOCK"; rm -f "\$SOCK"
# -t120 so op has time to prompt TouchID before the half-close tears the conn down.
exec "$SOCAT" -t120 UNIX-LISTEN:"\$SOCK",fork,mode=0600 EXEC:"$DIR/resolve.sh"
LISTEN
chmod +x "$DIR/resolve.sh" "$DIR/listen.sh"

echo ">> LaunchAgent"
PLIST="$HOME/Library/LaunchAgents/com.__MAC_USER__.op-resolver.plist"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.__MAC_USER__.op-resolver</string>
  <key>ProgramArguments</key><array><string>$DIR/listen.sh</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$DIR/stderr.log</string>
  <key>StandardOutPath</key><string>$DIR/stdout.log</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/com.__MAC_USER__.op-resolver" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ">> ~/.ssh/config RemoteForward on Host $SSH_HOST"
if ! grep -q "$VM_SOCK" "$HOME/.ssh/config" 2>/dev/null; then
  cat <<EOF

  ADD these lines under 'Host $SSH_HOST' in ~/.ssh/config (and any other Host you
  connect to the VM with), then reconnect:

      RemoteForward $VM_SOCK $MAC_SOCK
      StreamLocalBindUnlink yes
EOF
else
  echo "   (RemoteForward already present)"
fi

echo
echo "Done. Test from the VM (Mac-originated session):  op read 'op://<vault>/<item>/<field>'"
echo "Note: the VM's sshd needs 'StreamLocalBindUnlink yes' (deploy/80-op-proxy.sh sets it)."
