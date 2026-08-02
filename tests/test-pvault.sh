#!/usr/bin/env bash
# pvault — config parsing, fstab reconciliation, add/rm guards (deploy/72).
#
# Runs the exact installed tool (deploy/build/pvault, dropped via PVAULT_BIN —
# see tests/README.md) against a throwaway workspace, a fake fstab, and stub
# mount/umount/findmnt on PATH, so nothing here touches real mounts.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

PV="../deploy/build/pvault"
[ -x "$PV" ] || { printf 'missing %s — build the artifacts first (tests/README.md)\n' "$PV" >&2; exit 1; }
PVABS="$(cd "$(dirname "$PV")" && pwd)/$(basename "$PV")"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP"/{ws/A/docs,ws/B,bin,vault}
echo x > "$TMP/ws/B/f.md"

# Stubs: findmnt reports nothing mounted; mount/umount just record the call.
cat > "$TMP/bin/findmnt" <<'S'
#!/usr/bin/env bash
# $MOUNTED (newline-separated) lets a test say what is already mounted.
if [[ "$*" == *"-o TARGET"* ]]; then printf '%s' "${MOUNTED:-}"; exit 0; fi
for m in ${MOUNTED_LIST:-}; do :; done
exit 1                                    # --mountpoint probe: not a mountpoint
S
cat > "$TMP/bin/mount"  <<'S'
#!/usr/bin/env bash
printf 'MOUNT %s\n' "$*" >> "$CALLS"
S
cat > "$TMP/bin/umount" <<'S'
#!/usr/bin/env bash
printf 'UMOUNT %s\n' "$*" >> "$CALLS"
S
chmod +x "$TMP"/bin/*
export PATH="$TMP/bin:$PATH" CALLS="$TMP/calls"
export PVAULT_CONF="$TMP/conf" VAULT_ROOT="$TMP/vault" WORKSPACE_DIR="$TMP/ws" \
       PVAULT_FSTAB="$TMP/fstab" PVAULT_SUDO=""
: > "$TMP/fstab"
pv() { timeout 20 bash "$PVABS" "$@" 2>&1; }   # timeout: an unbounded walk-up loop is a real past bug

printf '# comment\nA/docs   A\nB/f.md\n' > "$TMP/conf"

# --- entry resolution -------------------------------------------------------
is "mountpoints: vault-path override applied" "$(pv mountpoints | head -1)" "$TMP/vault/A"
is "mountpoints: default is the source path"  "$(pv mountpoints | tail -1)" "$TMP/vault/B/f.md"
is "comments and blanks ignored"              "$(pv mountpoints | wc -l)"   "2"

# --- apply ------------------------------------------------------------------
pv apply >/dev/null
is "fstab: one entry per config line" "$(grep -c 'none bind' "$TMP/fstab")" "2"
like "fstab: bind option"             "$(grep 'vault/A ' "$TMP/fstab")"    "none bind,nofail 0 0"
like "mount called for the directory" "$(cat "$TMP/calls")"                "--bind $TMP/ws/A/docs $TMP/vault/A"
ok_file=$([ -f "$TMP/vault/B/f.md" ] && echo file || echo other)
is "a FILE source gets a file mountpoint"      "$ok_file" "file"
ok_dir=$([ -d "$TMP/vault/A" ] && echo dir || echo other)
is "a DIRECTORY source gets a dir mountpoint"  "$ok_dir"  "dir"

# Re-running must not duplicate the managed block — it is rewritten by marker.
pv apply >/dev/null; pv apply >/dev/null
is "apply is idempotent: one block"   "$(grep -c 'plans-vault >>>' "$TMP/fstab")" "1"
is "apply is idempotent: two entries" "$(grep -c 'none bind' "$TMP/fstab")"       "2"

# --- add / rm ---------------------------------------------------------------
mkdir -p "$TMP/ws/C/docs"
like "add reports the entry"    "$(pv add C/docs)"        "added C/docs"
is   "add appends to config"    "$(grep -c '^C/docs' "$TMP/conf")" "1"
is   "add mounts it too"        "$(pv mountpoints | wc -l)"        "3"
like "add refuses duplicates"   "$(pv add C/docs)"        "already configured"
like "add refuses missing path" "$(pv add nope/x)"        "no such path"
like "rm reports removal"       "$(pv rm C/docs)"         "removed C/docs"
is   "rm drops it from config"  "$(grep -c '^C/docs' "$TMP/conf")" "0"
like "rm refuses unknown entry" "$(pv rm C/docs)"         "not configured"

# A vault-path override must not stop `rm` matching on the SOURCE field.
like "rm matches source, not vault-path" "$(pv rm A/docs)" "removed A/docs"
is   "config down to one entry"          "$(pv mountpoints | wc -l)" "1"

# --- link / where: the repo <-> vault mapping -------------------------------
# The mapping is NOT mechanical (a vault-path override collapses levels), which is
# the whole reason these verbs exist. `where` needs no rtmd, so it is testable here.
printf 'A/docs   A\nB/f.md\n' > "$TMP/conf"
is "where: dir mount root -> source"  "$(pv where A)"          "$TMP/ws/A/docs"
is "where: file inside a mount"       "$(pv where A/x/y.md)"   "$TMP/ws/A/docs/x/y.md"
is "where: a file entry"              "$(pv where B/f.md)"     "$TMP/ws/B/f.md"
like "where: refuses an unpublished path" "$(pv where Nope/z.md)" "not a published vault path"
# link resolves the mapping BEFORE it needs rtmd, so the refusal is testable too.
like "link: refuses an unpublished path"  "$(pv link "$TMP/ws/elsewhere.md")" "not published"

# --- vault paths with spaces ------------------------------------------------
# Split on the FIRST whitespace run only. Obsidian folder names routinely contain
# spaces; this silently truncated to "REPORTS/Monthly" before the fix.
printf 'A/docs   REPORTS/Monthly Invoice Review\n' > "$TMP/conf"
is "vault-path may contain spaces" "$(pv mountpoints)" "$TMP/vault/REPORTS/Monthly Invoice Review"
is "where: round-trips a spaced path" "$(pv where 'REPORTS/Monthly Invoice Review/x.md')" \
   "$TMP/ws/A/docs/x.md"

# REGRESSION: parsing the space correctly is not enough — the fstab WRITER has to
# escape it too. Unescaped, the field splits and every entry under the folder
# writes the same truncated target with fstype "Invoice", so they collapse onto
# one duplicate mount unit and the next boot lands in emergency mode. Assert on
# the line that reaches fstab, not just on what mountpoints parses back.
pv apply >/dev/null
spaced="$(grep REPORTS "$TMP/fstab")"
like   "fstab: target spaces are escaped"   "$spaced" 'REPORTS/Monthly\040Invoice\040Review'
unlike "fstab: no raw space in the target"  "$spaced" 'Monthly Invoice'

# --- check: attachments, and the policy that decides their fate --------------
# Pre-0.1.0 every attachment uploaded and one rejected extension failed the WHOLE
# push. 0.1.0 added a per-folder filter in .rtmd, so `check` has to report the LIVE
# policy — it is state outside this config, and the two can disagree.
printf 'A/docs   A\n' > "$TMP/conf"
: > "$TMP/ws/A/docs/note.md"
like "check: clean when all notes" "$(pv check)" "clean"
: > "$TMP/ws/A/docs/report.html"
like "check: flags the attachment"  "$(pv check)" "1 attachment(s)"
: > "$TMP/ws/A/docs/x.canvas"; : > "$TMP/ws/A/docs/y.base"
like "check: canvas/base count as notes" "$(pv check)" "1 attachment(s)"

rtmd_policy() { printf '{"version":1,"baseUrl":"u","vaultId":"v"%s}\n' "$1" > "$TMP/vault/.rtmd"; }
like "check: no .rtmd reads as unknown"  "$(pv check)" "policy: unknown"
rtmd_policy ''
like "check: absent key is the old all"  "$(pv check)" "policy: all"
like "check: ...and warns it can break"  "$(pv check)" "ENTIRE push fails"
rtmd_policy ',"attachmentSync":{"enabled":false,"includeGlobs":[]}'
like "check: disabled reads as off"      "$(pv check)" "policy: off"
like "check: ...and says ignored"        "$(pv check)" "IGNORED"
rtmd_policy ',"attachmentSync":{"enabled":true,"includeGlobs":["**/*.html","assets/**"]}'
like "check: globs are reported"         "$(pv check)" '**/*.html, assets/**'
like "check: ...and says silently"       "$(pv check)" "ignored silently"
rtmd_policy ',"attachmentSync":{"enabled":true,"includeGlobs":[]}'
like "check: enabled with no globs = all" "$(pv check)" "policy: all"

rm -f "$TMP/ws/A/docs/report.html"
like "check: clean again once removed" "$(pv check)" "clean"

# --- retiring a FILE entry must unlink its mountpoint ------------------------
# REGRESSION: cleanup used rmdir, which ALWAYS fails on a file, so a retired
# single-file entry left behind the 0-byte stub that `: > "$dst"` created. rtmd
# walks the vault tree rather than this config, so that stub read as "the note was
# emptied" and the post-apply push TRUNCATED it server-side — the note stayed
# visible in Obsidian, blank, which looks like a successful sync.
mkdir -p "$TMP/ws/E"; echo real > "$TMP/ws/E/one.md"
printf 'E/one.md   V/one.md\n' > "$TMP/conf"
pv apply >/dev/null
is "file mountpoint was created" "$([ -f "$TMP/vault/V/one.md" ] && echo yes)" "yes"
printf '# nothing\n' > "$TMP/conf"
MOUNTED="$TMP/vault/V/one.md" pv apply >/dev/null
is "retired file stub is unlinked"     "$([ -e "$TMP/vault/V/one.md" ] && echo left)" ""
is "...and its empty parent goes too"  "$([ -e "$TMP/vault/V" ] && echo left)"       ""

# A stub that somehow holds content predates the mount and is NOT ours to delete.
printf 'E/one.md   V/one.md\n' > "$TMP/conf"; pv apply >/dev/null
echo "pre-existing" > "$TMP/vault/V/one.md"
printf '# nothing\n' > "$TMP/conf"
out="$(MOUNTED="$TMP/vault/V/one.md" pv apply)"
like "non-empty stale mountpoint is refused" "$out" "NOT removing"
is   "...and left on disk"  "$(cat "$TMP/vault/V/one.md")" "pre-existing"
rm -rf "$TMP/vault/V"

# --- collapsing file entries into one folder entry ---------------------------
# REGRESSION: mount points were created in the fstab loop, which runs BEFORE the
# stale-cleanup loop. Replacing per-file entries with one folder entry made the
# folder first, then cleanup rmdir'd it the moment its last retired child left it
# empty, and the mount died with "mount point does not exist".
mkdir -p "$TMP/ws/F"; echo a > "$TMP/ws/F/a.md"; echo b > "$TMP/ws/F/b.md"
printf 'F/a.md   V/a.md\nF/b.md   V/b.md\n' > "$TMP/conf"
pv apply >/dev/null
printf 'F   V\n' > "$TMP/conf"
: > "$TMP/calls"
MOUNTED="$(printf '%s\n%s' "$TMP/vault/V/a.md" "$TMP/vault/V/b.md")" pv apply >/dev/null
is   "collapsed: folder mountpoint survives cleanup" "$([ -d "$TMP/vault/V" ] && echo dir)" "dir"
like "collapsed: the folder is mounted"              "$(cat "$TMP/calls")" "MOUNT --bind $TMP/ws/F $TMP/vault/V"

# --- a mounted spaced path must not be seen as stale -------------------------
# REGRESSION: `findmnt -r` escapes spaces as \x20, so a mount whose vault-path had a
# space never matched the wanted list, was declared stale, and got unmounted then
# remounted on EVERY apply. Between the two the vault file is an empty stub, and a
# push landing in that window truncates it server-side. -l does not escape.
printf 'A/docs   REPORTS/Monthly Invoice Review\n' > "$TMP/conf"
: > "$TMP/calls"
MOUNTED="$TMP/vault/REPORTS/Monthly Invoice Review" pv apply >/dev/null
unlike "spaced mount is not unmounted as stale" "$(cat "$TMP/calls")" "UMOUNT"

# --- guards are advisory, not fatal -----------------------------------------
# A third-party origin should WARN but still add: the call is the user's.
mkdir -p "$TMP/ws/D/docs"; git -C "$TMP/ws/D" init -q
git -C "$TMP/ws/D" remote add origin https://github.com/open-gsd/gsd-core
out="$(pv add D/docs)"
like "third-party origin warns"      "$out" "third-party origin"
like "...but the entry is still added" "$out" "added D/docs"

finish
