#!/usr/bin/env bash
# Mac side of the reverse op resolver. Run ON YOUR MAC. Pairs with deploy/80-op-proxy.sh
# on the VM: each Mac->VM SSH connection forwards its own VM socket ~/.op-proxy/mac-<hash>.sock
# (RemoteForward %C) back to a
# small `op read`-only resolver here, so the VM resolves secrets via TouchID with NO
# inbound to the Mac (works with shields-up + the sandboxed App Store Tailscale).
#
#   ./mac/op-resolver-setup.sh
# Override defaults via env: OP_ACCOUNT, SSH_HOST, VM_SOCK.
set -euo pipefail

OP_ACCOUNT="${OP_ACCOUNT:-__OP_ACCOUNT__}"   # which 1Password account (you have several)
SSH_HOST="${SSH_HOST:-__VM_NAME__}"                    # the ~/.ssh/config Host to add RemoteForward to
# %C = ssh's per-host connection hash: each host alias binds its OWN socket on the VM and
# the VM's op proxy tries every mac-*.sock, so one dead connection can't break resolution.
VM_SOCK="${VM_SOCK:-/home/__DEV_USER__/.op-proxy/mac-%C.sock}"   # socket path ON THE VM (matches DEV_USER there)
DIR="$HOME/.op-resolver"
MAC_SOCK="$DIR/resolver.sock"

OP="$(command -v op || echo /opt/homebrew/bin/op)"
command -v socat >/dev/null || brew install socat
SOCAT="$(command -v socat)"

echo ">> writing resolver scripts in $DIR"
mkdir -p "$DIR"
cat > "$DIR/resolve.sh" <<RESOLVE
#!/bin/bash
# Per-connection resolver. Wire protocol on stdin (the VM's op proxy speaks it):
#   1-line form (legacy): a bare op:// ref            -> resolved against the default account
#   2-line form:          <account>\n<op:// ref>      -> resolved against <account>
# The account hint lets items that live in a NON-default 1Password account resolve
# (the VM sends it from its own --account/OP_ACCOUNT). An empty or malformed hint falls
# back to the default below. op read only; every access is logged. TouchID still gates
# each read, so the hint only widens WHICH signed-in account is queried, not whether.
set -euo pipefail
OP="$OP"; OP_ACCOUNT_DEFAULT="$OP_ACCOUNT"; LOG="\$HOME/.op-resolver/access.log"
ts="\$(date '+%Y-%m-%d %H:%M:%S')"
IFS= read -r l1 || exit 0; l1="\${l1%\$'\r'}"
case "\$l1" in
  op://*) acct=""; ref="\$l1" ;;                              # legacy single-line form
  *)      acct="\$l1"; IFS= read -r ref || exit 0; ref="\${ref%\$'\r'}" ;;
esac
case "\$ref" in op://*) ;; *) printf 'ERR not-an-op-ref\n'; printf '%s DENY %s\n' "\$ts" "\$ref" >> "\$LOG"; exit 0 ;; esac
if [ "\${#ref}" -gt 512 ] || printf '%s' "\$ref" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  printf 'ERR bad-ref\n'; printf '%s DENY(bad) %s\n' "\$ts" "\$ref" >> "\$LOG"; exit 0; fi
# Constrain the account hint to a safe identifier (sign-in address / email / UUID / shorthand);
# on anything else, log and fall back to the default rather than pass it to op.
if [ -n "\$acct" ] && { [ "\${#acct}" -gt 128 ] || printf '%s' "\$acct" | LC_ALL=C grep -Eqv '^[A-Za-z0-9._@-]+\$'; }; then
  printf '%s WARN bad-account(%s) -> default\n' "\$ts" "\$acct" >> "\$LOG"; acct=""; fi
account="\${acct:-\$OP_ACCOUNT_DEFAULT}"
if val="\$("\$OP" read --account "\$account" -- "\$ref" 2>/dev/null)"; then
  printf '%s\n' "\$val"; printf '%s OK   [%s] %s\n' "\$ts" "\$account" "\$ref" >> "\$LOG"
else printf 'ERR op-read-failed\n'; printf '%s FAIL [%s] %s\n' "\$ts" "\$account" "\$ref" >> "\$LOG"; fi
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
