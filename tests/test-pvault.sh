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
[[ "$*" == *"-o TARGET"* ]] && exit 0    # enumerate: nothing mounted
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
like "fstab: bind option"             "$(grep 'vault/A ' "$TMP/fstab")"    "none bind 0 0"
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

# --- guards are advisory, not fatal -----------------------------------------
# A third-party origin should WARN but still add: the call is the user's.
mkdir -p "$TMP/ws/D/docs"; git -C "$TMP/ws/D" init -q
git -C "$TMP/ws/D" remote add origin https://github.com/open-gsd/gsd-core
out="$(pv add D/docs)"
like "third-party origin warns"      "$out" "third-party origin"
like "...but the entry is still added" "$out" "added D/docs"

finish
