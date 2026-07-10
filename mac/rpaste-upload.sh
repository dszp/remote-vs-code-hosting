#!/bin/bash
# On-demand: upload the current clipboard image to the dev VM and copy back a remote
# path that Claude (running ON the VM) can read. Pasting a screenshot into a remote
# terminal only sends a local Mac file path, which the VM can't open — this fixes that.
#
# Bind to a hotkey (e.g. BetterTouchTool -> "Execute Shell Script" -> this file's path).
# Runs with no terminal, so it reports via a macOS notification. Workflow:
#   screenshot -> press hotkey -> ⌘V into Claude on the VM.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
HOST="${RCODE_HOST:-__VM_SSH_ALIAS__}"
DIR="${RPASTE_DIR:-/home/__DEV_USER__/.cache/pastes}"
NAME="paste-$(date +%Y%m%d-%H%M%S).png"
NOTIFIER="/opt/homebrew/bin/terminal-notifier"
GROUP="rpaste"
# notify MSG [SOUND] [DISMISS]
# terminal-notifier 2.0.0 has no -timeout, so when macOS shows these as Alerts
# they stick until dismissed. DISMISS (seconds) schedules a detached -remove so
# the success toast self-clears; omit it to leave a notification sticky (errors).
notify() {
  [ -x "$NOTIFIER" ] || return 0
  "$NOTIFIER" -title "rpaste" -message "$1" -sound "${2:-Pop}" -group "$GROUP" >/dev/null 2>&1
  [ -n "$3" ] && ( sleep "$3"; "$NOTIFIER" -remove "$GROUP" >/dev/null 2>&1 ) &
  disown 2>/dev/null || true
}

TMP="$(mktemp -t rpaste).png"
if ! /opt/homebrew/bin/pngpaste "$TMP" 2>/dev/null; then
  rm -f "$TMP"; notify "No image on the clipboard" Basso; exit 1
fi
if ! /usr/bin/ssh "$HOST" "mkdir -p $DIR && cat > '$DIR/$NAME'" < "$TMP"; then
  rm -f "$TMP"; notify "Upload failed (is the VM reachable?)" Basso; exit 1
fi
rm -f "$TMP"
printf '%s/%s' "$DIR" "$NAME" | /usr/bin/pbcopy
notify "Uploaded → $NAME · path copied, ⌘V into Claude" Glass 5
