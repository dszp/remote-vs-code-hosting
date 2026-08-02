#!/usr/bin/env bash
# Publish selected folders/files into a Realtime vault, two-way, so plans and docs
# Claude writes on the VM are readable AND editable from Obsidian on any device.
#
# WHY BIND MOUNTS, NOT SYMLINKS: the rtmd CLI walks the vault folder with
# `readdir(withFileTypes)` and does `if (entry.isSymbolicLink()) continue` —
# symlinked files AND directories are skipped outright, so a symlink farm syncs
# nothing (packages/cli/src/sync.ts). A bind mount presents a real dirent, so the
# scan sees it, and an edit made on the phone writes THROUGH to the repo's own
# file — no copy, no reconciler.
#
# WHAT IS PUBLISHED is declarative, in ~/.config/remote-vs-code/plans-vault.conf:
#   <source> [<vault-path>]
# `source` is absolute or relative to ~/workspace; `vault-path` is relative to the
# vault root and defaults to `source`. Directories and single FILES both work
# (mount --bind handles either). Add entries with `pvault add`, or edit the file.
#
# THE DELETION HAZARD this guards: rtmd computes a three-way diff, so a vault
# directory that is EMPTY because its bind mount is not active reads as "every
# file was deleted" and a push would delete them server-side. pvault-sync
# therefore refuses to push unless every configured mount is live. This is the
# single most important safety property here — do not weaken it.
#
# SYNC IS POLLED, not live: rtmd has no daemon/watch mode (status/pull/push only,
# a three-way diff against the .rtmd snapshot). So pull runs on a timer, and push
# is driven by inotify on the vault root. Both go through one flock so they can
# never interleave and corrupt the snapshot.
#
# PREREQUISITE — `rtmd`, the Realtime CLI, on PATH, and ~/vaults/plans already
# bound to a vault (`rtmd clone --cursor-token … <vaultId> ~/vaults/plans`; the
# cursor secret is vault-scoped and audited, unlike a personal session token).
# It is expected on npm shortly — install it that way once it is. Until then it
# builds from source, and the ONE thing worth writing down is the build ORDER,
# because the documented command alone fails with four "Could not resolve
# @realtime-md/sdk" errors:
#     git clone https://github.com/nealol/realtime ~/src/realtime
#     cd ~/src/realtime && bun install
#     bun run --filter @realtime-md/sdk build     # <- FIRST; not in their docs
#     bun run --filter @realtime-md/cli build
# The built CLI runs on plain node (bun is only the builder). Wrap it as
# ~/.local/bin/rtmd, and resolve node explicitly there — nvm's node is not on a
# systemd user unit's PATH, so the sync timer would fail with "node: not found".
#
# RUN ON: the VM.
#   ./deploy/run-remote.sh __VM_NAME__ deploy/72-plans-vault.sh DEV_USER=__DEV_USER__
# Set PVAULT_BIN=/path to also drop a copy of the tool for the test suite.
set -euo pipefail

# Same convention as the sibling scripts: taken from the ENVIRONMENT (run-remote.sh
# exports the VAR=VAL pairs). Do NOT derive from `id -un` — under sudo that is root,
# and everything would be installed into /root.
DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="${HOME_DIR:-/home/$DEV_USER}"
CONF_DIR="$HOME_DIR/.config/remote-vs-code"
CONF="$CONF_DIR/plans-vault.conf"
VAULT_ROOT="${VAULT_ROOT:-$HOME_DIR/vaults/plans}"
LIB_DIR="/usr/local/lib/remote-vs-code"
UNIT_DIR="$HOME_DIR/.config/systemd/user"

echo ">> [1/5] inotify-tools"
if ! command -v inotifywait >/dev/null; then
  dnf install -y inotify-tools
else
  echo "already installed"
fi

echo ">> [2/5] seed $CONF"
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0755 "$CONF_DIR"
if [ ! -f "$CONF" ]; then
  install -o "$DEV_USER" -g "$DEV_USER" -m 0644 /dev/stdin "$CONF" <<'CONF'
# What gets published into the Realtime "Plans" vault.
#
#   <source> [<vault-path>]
#
# source     absolute, or relative to ~/workspace. A directory OR a single file.
# vault-path relative to the vault root; defaults to <source>. Use it to flatten
#            a deep path — `ReconDash/docs/superpowers  ReconDash` publishes as
#            plans/ReconDash/{plans,specs} instead of four levels of nesting.
#
# Blank lines and #-comments ignored. Paths with spaces: quote the whole field.
# Apply changes with `pvault apply` (or `pvault add <src> [dest]`, which does both).
#
# DELIBERATELY EXCLUDED, and why:
#   - git worktrees (their .git is a FILE, not a directory). The same tracked
#     files on another branch would land as a second, drifting copy — and the
#     mount goes stale the moment `git worktree remove` runs.
#   - third-party checkouts (e.g. SKILLS-EXTERNAL/gsd-core, origin open-gsd/*).
#     Their design docs are upstream's, not yours.
# `pvault add` warns about both rather than refusing — override if you mean it.

ANSIBLE/ansible-podman-playbooks/docs/superpowers          ansible-podman-playbooks
Autotask-Validations/docs/superpowers                      Autotask-Validations
MCP-Autotask/STLUMC/docs/superpowers                       MCP-Autotask/STLUMC
MCP-Autotask/workflow-rules/docs/superpowers               MCP-Autotask/workflow-rules
n8n/n8n-as-code/docs/superpowers                           n8n-as-code
NetSapiens/NetSapiens-Onboarding-Backup/docs/superpowers   NetSapiens/Onboarding-Backup
NetSapiens/sv-portal-kit/docs/superpowers                  NetSapiens/sv-portal-kit
ReconDash/docs/superpowers                                 ReconDash
Remote-VS-Code/remote-vs-code/docs/superpowers             Remote-VS-Code
troubleshoot-linux/docs/superpowers                        troubleshoot-linux
CONF
  echo "created $CONF"
else
  echo "kept existing $CONF ($(grep -cvE '^\s*(#|$)' "$CONF") entries)"
fi

echo ">> [3/5] install $LIB_DIR/pvault-sync.sh"
install -d -m 0755 "$LIB_DIR"
install -m 0755 /dev/stdin "$LIB_DIR/pvault-sync.sh" <<'SYNC'
#!/usr/bin/env bash
# One serialized rtmd sync pass. Called by the timer, the inotify watcher, and
# `pvault sync`. Source of truth: deploy/72-plans-vault.sh — do not edit in place.
#
#   pvault-sync.sh pull   remote -> local only
#   pvault-sync.sh push   local -> remote only (mount-guarded)
#   pvault-sync.sh both   pull then push (the timer's job)
set -uo pipefail
VAULT_ROOT="${VAULT_ROOT:-$HOME/vaults/plans}"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/pvault-sync.lock"
mode="${1:-both}"

log() { printf '%s pvault-sync: %s\n' "$(date -Is)" "$*"; }

# THE GUARD. An inactive bind mount leaves an EMPTY directory, which rtmd's
# three-way diff reads as "these files were deleted" — a push would then delete
# them on the server, and the next pull would delete them from the repo. Refuse.
mounts_ok() {
  local missing=0 dest
  while read -r dest; do
    [ -n "$dest" ] || continue
    if ! findmnt -rn --mountpoint "$dest" >/dev/null 2>&1; then
      log "NOT MOUNTED: $dest"; missing=1
    fi
  done < <(pvault mountpoints 2>/dev/null)
  [ "$missing" -eq 0 ]
}

exec 9>"$LOCK" || { log "cannot open lock"; exit 1; }
flock -w 120 9 || { log "another sync holds the lock; skipping"; exit 0; }

cd "$VAULT_ROOT" 2>/dev/null || { log "vault root $VAULT_ROOT missing"; exit 1; }
[ -f .rtmd ] || { log "$VAULT_ROOT is not bound (no .rtmd) — run rtmd clone first"; exit 1; }

rc=0
case "$mode" in
  pull|both) rtmd pull || rc=$? ;;
esac
case "$mode" in
  push|both)
    if mounts_ok; then
      rtmd push || rc=$?
    else
      log "REFUSING TO PUSH: a configured mount is inactive — run 'pvault apply'"
      rc=1
    fi ;;
esac
exit "$rc"
SYNC
echo "installed $LIB_DIR/pvault-sync.sh"

echo ">> [4/5] install /usr/local/bin/pvault"
install -m 0755 /dev/stdin /usr/local/bin/pvault <<'PVAULT'
#!/usr/bin/env bash
# pvault — manage what is published into the Realtime vault.
# Source of truth: deploy/72-plans-vault.sh. Do not edit in place.
#
#   pvault list             configured entries + mount state
#   pvault apply            reconcile fstab + mounts to match the config
#   pvault add <src> [dst]  add an entry and apply
#   pvault rm  <src>        remove an entry, unmount, and apply
#   pvault sync             run one pull+push now
#   pvault status           rtmd status for the vault
#   pvault mountpoints      absolute mount destinations, one per line (internal)
set -uo pipefail

CONF="${PVAULT_CONF:-$HOME/.config/remote-vs-code/plans-vault.conf}"
VAULT_ROOT="${VAULT_ROOT:-$HOME/vaults/plans}"
WS="${WORKSPACE_DIR:-$HOME/workspace}"
FSTAB="${PVAULT_FSTAB:-/etc/fstab}"
BEGIN='# >>> remote-vs-code plans-vault >>>'
END='# <<< remote-vs-code plans-vault <<<'
SUDO="${PVAULT_SUDO-sudo}"

die() { printf 'pvault: %s\n' "$*" >&2; exit 1; }

# Emit "src<TAB>dst" for each entry, both absolute. Relative sources resolve
# against ~/workspace; a missing vault-path defaults to the source path.
entries() {
  [ -r "$CONF" ] || die "no config at $CONF"
  while read -r line; do
    line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    # shellcheck disable=SC2086
    set -- $line
    local src="$1" dst="${2:-}"
    case "$src" in /*) ;; *) src="$WS/$src" ;; esac
    [ -n "$dst" ] || dst="${src#"$WS"/}"
    printf '%s\t%s\n' "$src" "$VAULT_ROOT/$dst"
  done < "$CONF"
}

cmd_mountpoints() { entries | cut -f2; }

cmd_list() {
  printf '%-8s %-52s %s\n' STATE SOURCE 'VAULT PATH'
  while IFS=$'\t' read -r src dst; do
    local state
    if [ ! -e "$src" ]; then state=NOSRC
    elif findmnt -rn --mountpoint "$dst" >/dev/null 2>&1; then state=mounted
    else state=UNMOUNTED; fi
    printf '%-8s %-52s %s\n' "$state" "${src#"$WS"/}" "${dst#"$VAULT_ROOT"/}"
  done < <(entries)
}

# Rewrite the managed fstab block, then mount anything not yet mounted. Entries
# removed from the config are unmounted. Idempotent: safe to re-run any time.
cmd_apply() {
  local tmp; tmp="$(mktemp)"
  {
    printf '%s\n' "$BEGIN"
    while IFS=$'\t' read -r src dst; do
      [ -e "$src" ] || { printf 'pvault: skipping missing source %s\n' "$src" >&2; continue; }
      # A file source needs a file mount point; a directory needs a directory.
      if [ -d "$src" ]; then mkdir -p "$dst"; else mkdir -p "$(dirname "$dst")"; [ -e "$dst" ] || : > "$dst"; fi
      printf '%s %s none bind 0 0\n' "$src" "$dst"
    done < <(entries)
    printf '%s\n' "$END"
  } > "$tmp"

  $SUDO sed -i "\|^$BEGIN\$|,\|^$END\$|d" "$FSTAB"
  $SUDO tee -a "$FSTAB" < "$tmp" >/dev/null
  rm -f "$tmp"

  # Unmount anything under the vault root that the config no longer lists.
  local want; want="$(cmd_mountpoints)"
  while read -r m; do
    [ -n "$m" ] || continue
    grep -qxF "$m" <<<"$want" || { printf 'unmounting stale %s\n' "$m"; $SUDO umount "$m" || true; }
  done < <(findmnt -rn -o TARGET | grep "^$VAULT_ROOT/" || true)

  while IFS=$'\t' read -r src dst; do
    [ -e "$src" ] || continue
    findmnt -rn --mountpoint "$dst" >/dev/null 2>&1 && continue
    printf 'mounting %s\n' "${dst#"$VAULT_ROOT"/}"
    $SUDO mount --bind "$src" "$dst" || printf 'pvault: FAILED to mount %s\n' "$dst" >&2
  done < <(entries)
}

# Advisory checks only — `pvault add` warns and proceeds, it does not refuse.
warn_about() {
  local src="$1" root parent
  # Normalize first: `dirname` on a RELATIVE path bottoms out at ".", which is
  # its own parent — walking up from there spins forever.
  root="$(cd -- "$(dirname -- "$src")" 2>/dev/null && pwd)" || return 0
  while [ -n "$root" ] && [ "$root" != "/" ] && [ "$root" != "$WS" ] && [ ! -e "$root/.git" ]; do
    parent="$(dirname -- "$root")"
    [ "$parent" = "$root" ] && break   # fixed point — stop no matter what
    root="$parent"
  done
  [ -e "$root/.git" ] || return 0
  [ -f "$root/.git" ] && printf 'pvault: NOTE %s is a git WORKTREE — its files are another branch of the same repo, and the mount goes stale on `git worktree remove`.\n' "${root#"$WS"/}" >&2
  local origin; origin="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
  case "$origin" in
    *__MAC_USER__*|*servantvoice*|'') ;;
    *) printf 'pvault: NOTE %s has a third-party origin (%s) — its docs are upstream'"'"'s.\n' "${root#"$WS"/}" "$origin" >&2 ;;
  esac
}

# Match on the FIRST FIELD, not a regex built from a path — paths contain '/'
# and '.', and escaping them for ERE is how you get "stray \ before /".
conf_has() { # $1=rel $2=abs
  awk -v a="$1" -v b="$2" '{ t=$0; sub(/#.*/,"",t); n=split(t,f," ")
                             if (n && (f[1]==a || f[1]==b)) { found=1 } }
                           END { exit !found }' "$CONF"
}
conf_drop() { # $1=rel $2=abs — the config minus matching entries, on stdout
  awk -v a="$1" -v b="$2" '{ t=$0; sub(/#.*/,"",t); n=split(t,f," ")
                             if (n && (f[1]==a || f[1]==b)) next
                             print }' "$CONF"
}

cmd_add() {
  local src="${1:?usage: pvault add <source> [vault-path]}" dst="${2:-}"
  local abs="$src"; case "$abs" in /*) ;; *) abs="$WS/$abs" ;; esac
  [ -e "$abs" ] || die "no such path: $abs"
  local rel="${abs#"$WS"/}"
  conf_has "$rel" "$abs" && die "already configured: $rel"
  warn_about "$abs"
  printf '%s%s\n' "$rel" "${dst:+  $dst}" >> "$CONF"
  printf 'added %s%s\n' "$rel" "${dst:+ -> $dst}"
  cmd_apply
}

cmd_rm() {
  local src="${1:?usage: pvault rm <source>}"
  local abs="$src"; case "$abs" in /*) ;; *) abs="$WS/$abs" ;; esac
  local rel="${abs#"$WS"/}" tmp; tmp="$(mktemp)"
  conf_has "$rel" "$abs" || { rm -f "$tmp"; die "not configured: $rel"; }
  conf_drop "$rel" "$abs" > "$tmp"
  mv "$tmp" "$CONF"; printf 'removed %s\n' "$rel"
  cmd_apply
}

case "${1:-list}" in
  list)        cmd_list ;;
  apply)       cmd_apply ;;
  add)         shift; cmd_add "$@" ;;
  rm|remove)   shift; cmd_rm "$@" ;;
  mountpoints) cmd_mountpoints ;;
  sync)        /usr/local/lib/remote-vs-code/pvault-sync.sh both ;;
  status)      (cd "$VAULT_ROOT" && rtmd status) ;;
  -h|--help|help)
    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (try: pvault --help)" ;;
esac
PVAULT
echo "installed /usr/local/bin/pvault"
if [ -n "${PVAULT_BIN:-}" ]; then
  install -d -m 0755 "$(dirname "$PVAULT_BIN")"
  install -m 0755 /usr/local/bin/pvault "$PVAULT_BIN"
  echo "copied pvault to $PVAULT_BIN"
fi

echo ">> [5/5] systemd user units"
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0755 "$UNIT_DIR"

install -o "$DEV_USER" -g "$DEV_USER" -m 0644 /dev/stdin "$UNIT_DIR/pvault-pull.service" <<UNIT
[Unit]
Description=Realtime vault: pull remote changes, then push local ones
After=network-online.target

[Service]
Type=oneshot
# systemd user units do NOT inherit the login shell's PATH, and rtmd lives in
# ~/.local/bin — without this the timer fails with "rtmd: command not found".
Environment=PATH=$HOME_DIR/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin
Environment=VAULT_ROOT=$VAULT_ROOT
ExecStart=$LIB_DIR/pvault-sync.sh both
UNIT

install -o "$DEV_USER" -g "$DEV_USER" -m 0644 /dev/stdin "$UNIT_DIR/pvault-pull.timer" <<'UNIT'
[Unit]
Description=Realtime vault sync every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=60
AccuracySec=5s
Unit=pvault-pull.service

[Install]
WantedBy=timers.target
UNIT

# Push is event-driven so a plan Claude just wrote reaches the phone in seconds
# rather than waiting up to a minute. --exclude keeps rtmd's own snapshot writes
# (.rtmd) from retriggering the watcher into a loop; the flock in pvault-sync
# makes an overlap harmless anyway.
install -o "$DEV_USER" -g "$DEV_USER" -m 0644 /dev/stdin "$UNIT_DIR/pvault-push.service" <<UNIT
[Unit]
Description=Realtime vault: push on local change (inotify)
After=network-online.target

[Service]
Environment=PATH=$HOME_DIR/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin
Environment=VAULT_ROOT=$VAULT_ROOT
ExecStart=/bin/bash -c 'inotifywait -m -r -q --exclude "/\\\\.rtmd" \\
    -e close_write -e create -e delete -e moved_to -e moved_from \\
    --format %%w%%f "$VAULT_ROOT" | while read -r _; do \\
      sleep 2; \\
      while read -r -t 0.2 _; do :; done; \\
      $LIB_DIR/pvault-sync.sh push; \\
    done'
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
UNIT

chown -R "$DEV_USER:$DEV_USER" "$UNIT_DIR"
echo "installed pvault-pull.{service,timer} + pvault-push.service in $UNIT_DIR"
echo
echo "Next, as $DEV_USER:"
echo "  pvault apply                       # create the bind mounts"
echo "  systemctl --user daemon-reload"
echo "  systemctl --user enable --now pvault-pull.timer pvault-push.service"
