#!/usr/bin/env bash
# rvc_ensure_inotify_limits — the persistent inotify raise (deploy/lib.sh, called by
# deploy/10-base.sh). Sources the real function, never the real /etc or /sbin/sysctl.
set -uo pipefail
cd "$(dirname "$0")"

# deploy/lib.sh FIRST: it sets -e (a failing assertion must not abort the file) and
# defines its own ok()/die(), so tests/lib.sh is sourced AFTER to win the name clash.
. ../deploy/lib.sh
set +e
. ./lib.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A stub `sysctl` on PATH: reports whatever the case under test wants the kernel to be
# currently enforcing, and records every invocation so we can assert on --system.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/sysctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
if [ "${1:-}" = "-n" ]; then
  case "$2" in
    fs.inotify.max_user_watches)   printf '%s\n' "${STUB_WATCHES:-8192}" ;;
    fs.inotify.max_user_instances) printf '%s\n' "${STUB_INSTANCES:-128}" ;;
    *) exit 1 ;;
  esac
fi
STUB
chmod 0755 "$TMP/bin/sysctl"
export PATH="$TMP/bin:$PATH"

# Fresh state per case: empty drop-in dir, empty stub log.
reset() {
  rm -rf "$TMP/sysctl.d" "$TMP/stub.log"
  mkdir -p "$TMP/sysctl.d"
  : > "$TMP/stub.log"
  export SYSCTL_DIR="$TMP/sysctl.d"
  export STUB_LOG="$TMP/stub.log"
  export STUB_WATCHES=8192 STUB_INSTANCES=128
}
CONF() { printf '%s' "$TMP/sysctl.d/99-inotify.conf"; }

# --- writes when the drop-in is absent and the kernel is at the distro default ------
reset
rvc_ensure_inotify_limits >/dev/null 2>&1
if [ -f "$(CONF)" ]; then ok "absent + low: writes the drop-in"
else fail "absent + low: writes the drop-in" "no file at $(CONF)"; fi
like "absent + low: sets max_user_watches"   "$(cat "$(CONF)" 2>/dev/null)" "fs.inotify.max_user_watches=524288"
like "absent + low: sets max_user_instances" "$(cat "$(CONF)" 2>/dev/null)" "fs.inotify.max_user_instances=1024"
like "absent + low: applies with sysctl --system" "$(cat "$TMP/stub.log")" "--system"

# --- every emitted setting line is real sysctl syntax ------------------------------
bad="$(grep -vE '^[[:space:]]*(#|$)' "$(CONF)" 2>/dev/null | grep -vE '^[a-z][a-z0-9._]*=[0-9]+$')"
is "absent + low: only key=value setting lines" "$bad" ""

# --- an existing drop-in is somebody's deliberate choice ---------------------------
reset
printf '# hand tuned\nfs.inotify.max_user_watches=99\n' > "$(CONF)"
rvc_ensure_inotify_limits >/dev/null 2>&1
is   "existing drop-in: left byte-for-byte alone" \
     "$(cat "$(CONF)")" "$(printf '# hand tuned\nfs.inotify.max_user_watches=99\n')"
is   "existing drop-in: does not reload sysctl"   "$(cat "$TMP/stub.log")" ""

# --- never lower a limit something else already raised -----------------------------
reset
export STUB_WATCHES=524288 STUB_INSTANCES=1024
rvc_ensure_inotify_limits >/dev/null 2>&1
if [ -f "$(CONF)" ]; then fail "running values already at target: writes nothing" "wrote $(CONF)"
else ok "running values already at target: writes nothing"; fi

reset
export STUB_WATCHES=1048576 STUB_INSTANCES=2048
rvc_ensure_inotify_limits >/dev/null 2>&1
if [ -f "$(CONF)" ]; then fail "running values above target: writes nothing" "wrote $(CONF)"
else ok "running values above target: writes nothing"; fi

# --- both limits matter: one below target is enough to act -------------------------
reset
export STUB_WATCHES=524288 STUB_INSTANCES=128
rvc_ensure_inotify_limits >/dev/null 2>&1
if [ -f "$(CONF)" ]; then ok "only instances below target: still writes"
else fail "only instances below target: still writes" "no file at $(CONF)"; fi

reset
export STUB_WATCHES=8192 STUB_INSTANCES=1024
rvc_ensure_inotify_limits >/dev/null 2>&1
if [ -f "$(CONF)" ]; then ok "only watches below target: still writes"
else fail "only watches below target: still writes" "no file at $(CONF)"; fi

# --- re-running after its own write is a no-op (the drop-in guard covers it) --------
reset
rvc_ensure_inotify_limits >/dev/null 2>&1
before="$(cat "$(CONF)")"
: > "$TMP/stub.log"
rvc_ensure_inotify_limits >/dev/null 2>&1
is "second run: content unchanged"   "$(cat "$(CONF)")" "$before"
is "second run: does not reload sysctl" "$(cat "$TMP/stub.log")" ""

printf '\n%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
