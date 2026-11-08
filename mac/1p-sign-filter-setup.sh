#!/usr/bin/env bash
# Build and run the 1Password signing filter as a LaunchAgent. Run ON YOUR MAC. Idempotent.
#
# 1p-sign-filter (mac/1p-sign-filter/) is a tiny SSH agent in front of the 1Password agent
# that exposes ONE key: List shows only it, signatures go through only for it, and every
# other agent operation is refused. The __VM_NAME__-fwd carrier (mac/forward-agent-setup.sh)
# forwards the filter's socket to the VM for git signing (deploy/88-git-ssh-signing.sh), so
# the VM never sees the other 1Password keys. It must run here, not on the VM: there,
# anything could bypass it by talking to the raw forwarded socket.
#
#   ./mac/1p-sign-filter-setup.sh
# Override via env: ALLOW_FP (SHA256:… of the key to expose), UPSTREAM, LISTEN, BIN.
# Needs Go (brew install go). Re-run after pulling changes to rebuild and restart.
set -euo pipefail

ALLOW_FP="${ALLOW_FP:-SHA256:__SIGNING_KEY_FINGERPRINT__}"   # the git signing key
UPSTREAM="${UPSTREAM:-$HOME/.1password/agent.sock}"
LISTEN="${LISTEN:-$HOME/.1password-filter/sign.sock}"
BIN="${BIN:-$HOME/.local/bin/1p-sign-filter}"
LABEL="com.__MAC_USER__.1p-sign-filter"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$LABEL.log"
SRC="$(cd "$(dirname "$0")/1p-sign-filter" && pwd)"

GO="$(command -v go || echo /opt/homebrew/bin/go)"
[ -x "$GO" ] || { echo "!! go not found — brew install go"; exit 1; }
[ -S "$UPSTREAM" ] || echo "!! $UPSTREAM not found — enable 1Password's SSH agent (Settings > Developer)"

echo ">> testing and building $BIN"
( cd "$SRC" && "$GO" vet ./... && "$GO" test -count=1 ./... && mkdir -p "$(dirname "$BIN")" && "$GO" build -trimpath -o "$BIN" . )

echo ">> LaunchAgent $LABEL"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$BIN</string>
    <string>-upstream</string><string>$UPSTREAM</string>
    <string>-listen</string><string>$LISTEN</string>
    <string>-allow</string><string>$ALLOW_FP</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>StandardOutPath</key><string>$LOG</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$LISTEN" ] && break; sleep 0.5; done
cat <<EOF

>> Verify (exactly one key, $ALLOW_FP):
     SSH_AUTH_SOCK=$LISTEN ssh-add -l
   Then point the carrier's signing forward at the filter (mac/forward-agent-setup.sh prints it):
     RemoteForward /home/__DEV_USER__/.ssh/mac-1p-agent.sock $LISTEN
   and restart it:  launchctl kickstart -k gui/\$(id -u)/com.__MAC_USER__.__VM_NAME__-forward
   Logs: $LOG     Tear down: launchctl bootout gui/\$(id -u)/$LABEL && rm $PLIST
EOF
