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
# CHANGING WHERE AN ENTRY PUBLISHES retires its old vault path. The server still
# holds notes there, and pvault-sync pulls before it pushes — so the pull would
# recreate those orphans through the NEW bind mount, i.e. inside the repo, and the
# push would send them back up, minting new guids each cycle and invalidating every
# permalink in the frontmatter. `apply` therefore pushes immediately after any mount
# change, before a pull can run. Symptom if this regresses: stray empty directories
# appearing in a repo (docs/plans, docs/specs) and permalinks that keep going stale.
#
# ATTACHMENTS ARE FILTERED IN THE CLI, as of @realtime-md/cli 0.1.0 (2026-08-02).
# rtmd classifies anything that is not .md / .canvas / .base as an ATTACHMENT
# (kinds.ts), and the server rejects any whose extension is outside its
# `attachment_allowed_extensions` config — a rejection that fails the WHOLE push,
# not just that file. Before 0.1.0 the CLI had no ignore mechanism, so one stray
# .xlsx stopped every plan from syncing and the only symptom was a non-zero exit
# in the journal. The mount list was the only available filter.
#
# 0.1.0 added a per-folder policy, stored as `attachmentSync` in .rtmd:
#     rtmd config attachments off
#     rtmd config attachments on --include "**/*.html,assets/**"
#     rtmd config attachments on --all
#     rtmd config attachments              # show the current policy
# Non-matching attachments are ignored in BOTH directions — never uploaded,
# downloaded, or deleted — so a blocked extension can no longer break the push.
# THIS HOST publishes `**/*.html` and ignores everything else, which is what lets
# whole repo folders be bound instead of markdown files one at a time.
#
# Two traps that remain:
#   - Ignored is SILENT. A .pdf in a bound folder simply never appears in the
#     vault; nothing warns you. `pvault check` reports the live policy and what
#     it excludes, which is the only place that discrepancy surfaces.
#   - `rtmd ls` still LISTS ignored files with their classified kind, because it
#     merges the local scan into the listing. They are not on the server — check
#     with `rtmd attach ls`, which lists only what is actually stored.
# The policy is CLI-side and unrelated to the vault's own "Sync attachments" /
# "Attachment exclusions" settings in Obsidian, which are plugin-side.
#
# SYNC IS POLLED, not live: rtmd has no daemon/watch mode (status/pull/push only,
# a three-way diff against the .rtmd snapshot). So pull runs on a timer, and push
# is driven by inotify on the vault root. Both go through one flock so they can
# never interleave and corrupt the snapshot.
#
# PREREQUISITE — `rtmd`, the Realtime CLI, on PATH, and ~/vaults/plans already
# bound to a vault (`rtmd clone --cursor-token … <vaultId> ~/vaults/plans`; the
# cursor secret is vault-scoped and audited, unlike a personal session token).
# Published to npm on 2026-08-02, so it is no longer built from source:
#     npm i -g @realtime-md/cli
#     rtmd config attachments on --include "**/*.html"   # see the note above
# It is still wrapped as ~/.local/bin/rtmd, because BOTH the `rtmd` symlink npm
# creates and the `#!/usr/bin/env node` shebang inside it are tied to one nvm
# node version that a systemd user unit's PATH cannot see — the sync timer would
# fail with "node: not found", and an `nvm install` would strand the package on
# the old version. The wrapper resolves the newest node that actually HAS it.
# `rtmd whoami` prints the bound vault id (0.1.0); before that it took a devtools
# console in Obsidian to find one.
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
#            a deep path — `my-project/docs/superpowers  my-project` publishes
#            as plans/my-project/{plans,specs} rather than four levels of nesting.
#
# Blank lines and #-comments ignored. Split on the FIRST whitespace run, so a
# vault-path MAY contain spaces ("REPORTS/Monthly Invoice Review"); a source may not.
# Apply changes with `pvault apply` (or `pvault add <src> [dest]`, which does both).
#
# DELIBERATELY EXCLUDED, and why:
#   - git worktrees (their .git is a FILE, not a directory). The same tracked
#     files on another branch would land as a second, drifting copy — and the
#     mount goes stale the moment `git worktree remove` runs.
#   - third-party checkouts (e.g. SKILLS-EXTERNAL/gsd-core, origin open-gsd/*).
#     Their design docs are upstream's, not yours.
# `pvault add` warns about both rather than refusing — override if you mean it.

# Nothing is published until you add something. Examples — uncomment and edit,
# or just run `pvault add <src> [dest]`, which appends here and mounts it.
#
# my-project/docs/superpowers            my-project
# group/other-project/docs/superpowers   group/other-project
# notes/reports                          REPORTS
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
#   pvault link <path>      clickable Obsidian permalink for a repo OR vault path
#   pvault where <vpath>    the real file on disk behind a vault path
#   pvault check            attachment policy + published files it filters out
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
LIB_SYNC="${PVAULT_SYNC:-/usr/local/lib/remote-vs-code/pvault-sync.sh}"

die() { printf 'pvault: %s\n' "$*" >&2; exit 1; }

# Emit "src<TAB>dst" for each entry, both absolute. Relative sources resolve
# against ~/workspace; a missing vault-path defaults to the source path.
entries() {
  [ -r "$CONF" ] || die "no config at $CONF"
  while read -r line; do
    line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    # Split on the FIRST whitespace run only, so a vault path may contain spaces
    # ("REPORTS/Monthly Invoice Review"). Obsidian folder names routinely do.
    # The SOURCE may not — it is always a repo path, and none have spaces.
    local src="${line%%[[:space:]]*}" dst="${line#"${line%%[[:space:]]*}"}"
    dst="${dst#"${dst%%[![:space:]]*}"}"      # ltrim
    dst="${dst%"${dst##*[![:space:]]}"}"      # rtrim
    case "$src" in /*) ;; *) src="$WS/$src" ;; esac
    [ -n "$dst" ] || dst="${src#"$WS"/}"
    printf '%s\t%s\n' "$src" "$VAULT_ROOT/$dst"
  done < "$CONF"
}

cmd_mountpoints() { entries | cut -f2; }

# Map a path to its place in the vault. Accepts a REPO path (absolute or relative
# to ~/workspace) or an already-vault-relative path. Prints the vault-relative
# form, or nothing if the path is not published.
#
# This has to exist because the mapping is NOT mechanical: a config vault-path
# override collapses levels ("Remote-VS-Code/remote-vs-code/docs/superpowers" ->
# "Remote-VS-Code"), so nothing can derive the vault path from a repo path
# without reading the config. Anything wanting a permalink needs this first.
vault_path_of() { # $1 = path
  local p="$1" abs src dst
  case "$p" in /*) abs="$p" ;; *) abs="$WS/$p" ;; esac
  while IFS=$'\t' read -r src dst; do
    case "$abs" in
      "$src") printf '%s' "${dst#"$VAULT_ROOT"/}"; return 0 ;;
      "$src"/*) printf '%s/%s' "${dst#"$VAULT_ROOT"/}" "${abs#"$src"/}"; return 0 ;;
    esac
  done < <(entries)
  # Already vault-relative? Accept it if it actually exists in the vault.
  [ -e "$VAULT_ROOT/$p" ] && { printf '%s' "$p"; return 0; }
  return 1
}

cmd_where() {   # vault-relative -> the real file on disk (what the phone can't see)
  local p="${1:?usage: pvault where <vault-path>}" src dst
  while IFS=$'\t' read -r src dst; do
    local rel="${dst#"$VAULT_ROOT"/}"
    case "$p" in
      "$rel") printf '%s\n' "$src"; return 0 ;;
      "$rel"/*) printf '%s/%s\n' "$src" "${p#"$rel"/}"; return 0 ;;
    esac
  done < <(entries)
  die "not a published vault path: $p"
}

cmd_link() {
  local p="${1:?usage: pvault link <repo-path|vault-path>}" vp
  vp="$(vault_path_of "$p")" || die "not published (and not in the vault): $p"
  [ -e "$VAULT_ROOT/$vp" ] || die "published, but no such file in the vault: $vp"
  command -v rtmd >/dev/null || die "rtmd is not installed"
  # rtmd resolves paths against the bound folder, so run from the vault root.
  (cd "$VAULT_ROOT" && rtmd permalink "$vp")
}

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

# fstab fields are whitespace-delimited, so a space in a vault path has to be
# written as an octal escape. Unescaped, the field splits: every entry under
# "REPORTS/Monthly Invoice Review" writes target ".../REPORTS/Monthly" with
# fstype "Invoice", so they all collapse to one duplicate mount unit and the
# boot drops to emergency mode. Backslash is substituted first or it would
# re-escape the sequences the later rules emit.
fstab_esc() { # $1 = path -> escaped for use as an fstab field
  local s="$1"
  s="${s//\\/\\134}"
  s="${s// /\\040}"
  s="${s//$'\t'/\\011}"
  s="${s//$'\n'/\\012}"
  printf '%s' "$s"
}

# Rewrite the managed fstab block, then mount anything not yet mounted. Entries
# removed from the config are unmounted. Idempotent: safe to re-run any time.
cmd_apply() {
  local tmp; tmp="$(mktemp)"
  {
    printf '%s\n' "$BEGIN"
    while IFS=$'\t' read -r src dst; do
      [ -e "$src" ] || { printf 'pvault: skipping missing source %s\n' "$src" >&2; continue; }
      # Mount points are created in the MOUNT loop below, not here. Creating them
      # this early put them in reach of the stale-cleanup loop that runs in between:
      # collapsing per-file entries into one folder entry made the folder first, then
      # cleanup rmdir'd it as soon as the last retired child left it empty, and the
      # mount failed with "mount point does not exist".
      # nofail: a bind whose target went missing must not strand the whole boot
      # in emergency mode. pvault-sync already refuses to push when a configured
      # mount is inactive, so an unmounted entry still surfaces loudly.
      printf '%s %s none bind,nofail 0 0\n' "$(fstab_esc "$src")" "$(fstab_esc "$dst")"
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
    if ! grep -qxF "$m" <<<"$want"; then
      printf 'unmounting stale %s\n' "$m"
      changed=1
      $SUDO umount "$m" || true
      # Drop the now-empty mountpoint and any parents it left behind, or moving an
      # entry to a new vault-path strands the old tree as empty folders. Bounded to
      # the vault root, and rmdir refuses anything non-empty, so this can't eat data.
      #
      # A FILE mountpoint has to be unlinked explicitly: `rmdir` on a file always
      # fails, so retiring a single-file entry used to leave the 0-byte stub that
      # `: > "$dst"` created. rtmd walks the vault tree, not this config, so the
      # stub read as "this note was emptied" and the post-apply push TRUNCATED the
      # note server-side — it stayed visible in Obsidian, blank. That looks like a
      # successful sync, which is what made it dangerous.
      if [ -f "$m" ] && ! findmnt -ln --mountpoint "$m" >/dev/null 2>&1; then
        if [ -s "$m" ]; then
          # Content here did not come from the bind (a bind never writes through to
          # the mountpoint's own inode), so it predates the mount. Not ours to delete.
          printf 'pvault: NOT removing %s — stale mountpoint is non-empty\n' "${m#"$VAULT_ROOT"/}" >&2
        else
          rm -f "$m"
        fi
      fi
      local d="$m"; [ -d "$d" ] || d="$(dirname "$d")"
      while [ "$d" != "$VAULT_ROOT" ] && [ "${d#"$VAULT_ROOT"/}" != "$d" ]; do
        rmdir "$d" 2>/dev/null || break
        d="$(dirname "$d")"
      done
    fi
    # -l (list), NOT -r (raw): raw mode escapes spaces as \x20, so every mount whose
    # vault-path contains a space failed the comparison below, was declared stale, and
    # was unmounted and immediately remounted on every apply. Harmless-looking churn,
    # but between the two the vault file is an empty stub — and a push landing in that
    # window would truncate it server-side.
  done < <(findmnt -ln -o TARGET | grep "^$VAULT_ROOT/" || true)

  while IFS=$'\t' read -r src dst; do
    [ -e "$src" ] || continue
    # Presence is not enough: changing an entry's SOURCE while its vault-path stays
    # the same (widening `X/docs/superpowers  V` to `X/docs  V`) leaves the old mount
    # in place, and "already mounted" would silently skip it — the config says one
    # thing and the vault shows another. findmnt reports a bind mount's origin as
    # DEV[/sub/path]; compare that, and remount when it disagrees.
    if findmnt -ln --mountpoint "$dst" >/dev/null 2>&1; then
      local cur; cur="$(findmnt -ln -o SOURCE --mountpoint "$dst" 2>/dev/null | head -1)"
      cur="${cur#*[}"; cur="${cur%]}"
      [ "$cur" = "$src" ] && continue
      printf 'remounting %s (was %s)\n' "${dst#"$VAULT_ROOT"/}" "${cur#"$WS"/}"
      $SUDO umount "$dst" || true
    else
      printf 'mounting %s\n' "${dst#"$VAULT_ROOT"/}"
    fi
    changed=1
    # Create the mount point HERE, after the stale-cleanup loop has had its say —
    # see the note in the fstab loop above. A file source needs a file mount point;
    # a directory needs a directory.
    if [ -d "$src" ]; then mkdir -p "$dst"; else mkdir -p "$(dirname "$dst")"; [ -e "$dst" ] || : > "$dst"; fi
    $SUDO mount --bind "$src" "$dst" || printf 'pvault: FAILED to mount %s\n' "$dst" >&2
  done < <(entries)

  # PUSH FIRST when the mount layout changed, and do NOT let a pull run before it.
  # Re-pointing an entry leaves the server holding notes at the OLD vault paths.
  # pvault-sync's normal order is pull-then-push, so the pull would RESURRECT those
  # orphans — writing them back through the new bind mount into the repo itself
  # (a repo gained empty docs/plans/ and docs/specs/ trees this way), which then
  # push back up, and every cycle mints fresh guids that invalidate the permalinks
  # in the frontmatter. A push here sees the old paths as locally absent and deletes
  # them server-side, which is the correct reading: the config no longer publishes them.
  if [ -n "${changed:-}" ] && [ -x "$LIB_SYNC" ] && [ -f "$VAULT_ROOT/.rtmd" ]; then
    printf 'mounts changed — pushing to retire old vault paths before any pull\n'
    "$LIB_SYNC" push || printf 'pvault: post-apply push failed; run `pvault sync` once resolved\n' >&2
  fi
}

# Files that are NOT notes sync as attachments. rtmd's kinds.ts: .md=note,
# .canvas, .base — the rest are attachments, and whether they sync at all is the
# .rtmd `attachmentSync` policy's call (see the header).
nonnote_files() { # $1 = path to scan
  [ -e "$1" ] || return 0
  find "$1" -type f -not -path '*/.*' \
    ! -iname '*.md' ! -iname '*.canvas' ! -iname '*.base' 2>/dev/null
}

# The live attachment policy, read from .rtmd: "off", "all", or the include globs.
# Reported rather than assumed — it is per-folder CLI state that lives outside
# this config, so the two can disagree and only this surfaces it.
attach_policy() {
  local f="$VAULT_ROOT/.rtmd"
  [ -r "$f" ] || { echo "unknown"; return; }
  python3 - "$f" <<'PY' 2>/dev/null || echo "unknown"
import json, sys
a = (json.load(open(sys.argv[1])).get("attachmentSync") or {})
if not a: print("all")                       # absent = pre-0.1.0 default
elif not a.get("enabled"): print("off")
else:
    g = a.get("includeGlobs") or []
    print(", ".join(g) if g else "all")
PY
}

cmd_check() {
  local total=0 src dst policy; policy="$(attach_policy)"
  printf 'attachment policy: %s   (rtmd config attachments …)\n\n' "$policy"
  while IFS=$'\t' read -r src dst; do
    local n; n="$(nonnote_files "$src" | wc -l)"
    [ "$n" -eq 0 ] && continue
    total=$((total+n))
    printf '%-52s %s attachment(s)\n' "${src#"$WS"/}" "$n"
    nonnote_files "$src" | sed 's|.*\.||' | sort | uniq -c | sort -rn | sed 's/^/     /' | head -5
  done < <(entries)
  [ "$total" -eq 0 ] && { echo "clean — every published file is a note (.md/.canvas/.base)"; return; }
  echo
  case "$policy" in
    off)  echo "$total non-note file(s) above are IGNORED — never uploaded, and nothing"
          echo "warns when one is missing from the vault. Notes still sync normally." ;;
    all)  echo "$total non-note file(s) above ALL sync as attachments. If the server's"
          echo "allowlist rejects any extension the ENTIRE push fails and nothing syncs."
          echo "Narrow it: rtmd config attachments on --include '**/*.html'" ;;
    unknown)
          echo "$total non-note file(s) above. Could not read the policy from"
          echo "$VAULT_ROOT/.rtmd — check it with: rtmd config attachments" ;;
    *)    echo "$total non-note file(s) above; only those matching [$policy] sync."
          echo "The rest are ignored silently. A rejected extension inside the filter"
          echo "would still fail the whole push." ;;
  esac
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
    *__MAC_USER__*|*__GIT_ORG__*|'') ;;
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
  local nn; nn="$(nonnote_files "$abs" | wc -l)"
  if [ "$nn" -gt 0 ]; then
    local policy; policy="$(attach_policy)"
    printf 'pvault: NOTE %s contains %s non-note file(s) (%s);\n' \
      "$rel" "$nn" "$(nonnote_files "$abs" | sed 's|.*\.||' | sort -u | tr '\n' ',' | sed 's/,$//')" >&2
    case "$policy" in
      all) printf '        the attachment policy is "all", so every one of them uploads — and a\n        single rejected extension fails the ENTIRE push. Narrow it with\n        `rtmd config attachments on --include …`, or check: pvault check\n' >&2 ;;
      *)   printf '        the attachment policy is [%s], so the rest are ignored SILENTLY —\n        they will simply never appear in the vault. Check: pvault check\n' "$policy" >&2 ;;
    esac
  fi
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
  link)        shift; cmd_link "$@" ;;
  where)       shift; cmd_where "$@" ;;
  check)       cmd_check ;;
  sync)        /usr/local/lib/remote-vs-code/pvault-sync.sh both ;;
  status)      (cd "$VAULT_ROOT" && rtmd status) ;;
  -h|--help|help)
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//' ;;
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
