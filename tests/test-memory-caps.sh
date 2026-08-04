#!/usr/bin/env bash
# rvc_mem_cap_gib — the memory-cap policy (deploy/lib.sh), turned into cgroup v2 limits by
# deploy/96-memory-caps.sh after two runaway claude.exe processes OOM-killed the box on
# 2026-08-03. These caps sit between "never fires" and "kills real work every day", so the
# arithmetic and the layering invariants are worth pinning down.
set -uo pipefail
cd "$(dirname "$0")"

# deploy/lib.sh FIRST: it sets -e and defines its own ok()/die(); tests/lib.sh goes
# after so the assertions win the name clash.
. ../deploy/lib.sh
set +e
. ./lib.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# $1 = MemTotal kB
meminfo() {
  printf 'MemTotal:       %s kB\nMemFree:  1 kB\nSwapTotal:      0 kB\n' "$1" > "$TMP/meminfo"
  printf '%s' "$TMP/meminfo"
}

# __VM_NAME__ as measured on 2026-08-03: 16639116 kB == 15.868 GiB. These five numbers were
# chosen against real behaviour on that box, so if the percentages ever drift, this is the
# case that catches it.
DEV=$(meminfo 16639116)
is "15.87 GiB box: herdr High = 9G"  "$(MEMINFO=$DEV rvc_mem_cap_gib herdr-high)" "9"
is "15.87 GiB box: herdr Max  = 12G" "$(MEMINFO=$DEV rvc_mem_cap_gib herdr-max)"  "12"
is "15.87 GiB box: herdr Swap = 4G"  "$(MEMINFO=$DEV rvc_mem_cap_gib herdr-swap)" "4"
is "15.87 GiB box: user Max   = 13G" "$(MEMINFO=$DEV rvc_mem_cap_gib user-max)"   "13"
is "15.87 GiB box: user Swap  = 6G"  "$(MEMINFO=$DEV rvc_mem_cap_gib user-swap)"  "6"

# Rounding to NEAREST, not truncation. 25% of 15.868 is 3.967: truncating yields 3 and caps
# swap a full GiB under intent. This is the assertion that fails if someone "simplifies" the
# + 524288 away.
is "herdr-swap rounds 3.97 up to 4" "$(MEMINFO=$DEV rvc_mem_cap_gib herdr-swap)" "4"

# ---- layering invariants ------------------------------------------------------------
# The two slices are nested: the herdr cap must bite BEFORE the outer user backstop, and the
# soft throttle must bite before the hard kill. If these ever invert, the inner cap is dead
# weight and the box loses its graduated response.
for kb in 2097152 4194304 8388608 16639116 33554432 67108864; do
  g="$(MEMINFO=$(meminfo $kb) rvc_mem_cap_gib herdr-high)"
  m="$(MEMINFO=$(meminfo $kb) rvc_mem_cap_gib herdr-max)"
  um="$(MEMINFO=$(meminfo $kb) rvc_mem_cap_gib user-max)"
  hs="$(MEMINFO=$(meminfo $kb) rvc_mem_cap_gib herdr-swap)"
  us="$(MEMINFO=$(meminfo $kb) rvc_mem_cap_gib user-swap)"
  gib=$(( kb / 1048576 ))
  if [ "$g" -le "$m" ]; then ok "${gib}G box: herdr High <= Max"
  else fail "${gib}G box: herdr High <= Max" "high=$g max=$m"; fi
  if [ "$m" -le "$um" ]; then ok "${gib}G box: herdr Max <= user Max"
  else fail "${gib}G box: herdr Max <= user Max" "herdr=$m user=$um"; fi
  if [ "$hs" -le "$us" ]; then ok "${gib}G box: herdr Swap <= user Swap"
  else fail "${gib}G box: herdr Swap <= user Swap" "herdr=$hs user=$us"; fi
  # The outer cap must leave the kernel, system.slice and page cache something to live in.
  # A cap at or above MemTotal can never fire before the global OOM killer does, which is
  # the exact failure this whole script exists to prevent.
  if [ "$um" -lt "$gib" ] || [ "$gib" -eq 0 ]; then ok "${gib}G box: user Max leaves headroom"
  else fail "${gib}G box: user Max leaves headroom" "user-max=$um total=$gib"; fi
done

# ---- scaling sanity ------------------------------------------------------------------
is "64 GiB box: user Max  = 52G"  "$(MEMINFO=$(meminfo 67108864) rvc_mem_cap_gib user-max)"   "52"
is "64 GiB box: herdr Max = 49G"  "$(MEMINFO=$(meminfo 67108864) rvc_mem_cap_gib herdr-max)"  "49"
is "4 GiB box:  user Max  = 3G"   "$(MEMINFO=$(meminfo 4194304)  rvc_mem_cap_gib user-max)"   "3"

# A box small enough that 25% rounds to nothing must still get a real limit, not 0 —
# memory.swap.max=0 would disable swap for the slice entirely, which is a very different
# (and much worse) policy than "cap it low".
is "tiny box floors at 1G, never 0" "$(MEMINFO=$(meminfo 1) rvc_mem_cap_gib herdr-swap)" "1"

# ---- refuse to guess ------------------------------------------------------------------
# A wrong number caps the box below its working set (killing real work daily) or so high it
# never fires. Both are worse than failing loudly.
printf 'Garbage: nope\n' > "$TMP/bad"
out="$(MEMINFO=$TMP/bad rvc_mem_cap_gib user-max)"; rc=$?
is "unreadable MemTotal reports 0" "$out" "0"
if [ "$rc" -ne 0 ]; then ok "unreadable MemTotal is a non-zero exit"
else fail "unreadable MemTotal is a non-zero exit" "rc=$rc"; fi

out="$(MEMINFO=$TMP/does-not-exist rvc_mem_cap_gib user-max)"; rc=$?
is "missing meminfo reports 0" "$out" "0"
if [ "$rc" -ne 0 ]; then ok "missing meminfo is a non-zero exit"
else fail "missing meminfo is a non-zero exit" "rc=$rc"; fi

# An unknown key must not silently return a plausible-looking number — deploy/96 would then
# write a cap nobody chose.
out="$(MEMINFO=$DEV rvc_mem_cap_gib not-a-real-cap)"; rc=$?
is "unknown cap name reports 0" "$out" "0"
if [ "$rc" -ne 0 ]; then ok "unknown cap name is a non-zero exit"
else fail "unknown cap name is a non-zero exit" "rc=$rc"; fi

out="$(MEMINFO=$DEV rvc_mem_cap_gib)"; rc=$?
is "missing cap name reports 0" "$out" "0"
if [ "$rc" -ne 0 ]; then ok "missing cap name is a non-zero exit"
else fail "missing cap name is a non-zero exit" "rc=$rc"; fi

# ---- deploy/96 must ask for caps the policy actually defines --------------------------
# A typo'd key returns 0 and a non-zero exit, which the script turns into a die() — but only
# if the names match. Pin them together so renaming one side breaks here, not in production.
SCRIPT=../deploy/96-memory-caps.sh
for k in herdr-high herdr-max herdr-swap user-max user-swap; do
  if grep -qF "rvc_mem_cap_gib $k" "$SCRIPT"; then ok "deploy/96 uses cap '$k'"
  else fail "deploy/96 uses cap '$k'" "not found in $SCRIPT"; fi
done

# The outer slice must NOT get a MemoryHigh: throttling an interactive slice stalls every
# process in it at once. This is a deliberate asymmetry, easy to "fix" by mistake.
#
# Compare DIRECTIVE lines only. The user-slice heredoc explains in prose why MemoryHigh is
# omitted, so a naive grep over the whole block matches the comment and asserts nothing.
# $1 = which heredoc (1 = outer user slice, 2 = inner herdr slice)
conf_directives() {
  awk -v want="$1" '/<<CONF$/{n++; next} n==want && /^CONF$/{exit} n==want' "$SCRIPT" \
    | grep '^Memory'
}
user_directives="$(conf_directives 1)"
herdr_directives="$(conf_directives 2)"

# Guard the extraction itself: if the heredocs are ever reordered or renamed, these must fail
# loudly rather than silently matching nothing (an empty string satisfies every `unlike`).
if [ -n "$user_directives" ];  then ok "extracted outer user-slice directives"
else fail "extracted outer user-slice directives" "got nothing from $SCRIPT"; fi
if [ -n "$herdr_directives" ]; then ok "extracted inner herdr-slice directives"
else fail "extracted inner herdr-slice directives" "got nothing from $SCRIPT"; fi

unlike "outer user slice sets no MemoryHigh"  "$user_directives"  "MemoryHigh"
like   "outer user slice sets MemorySwapMax"  "$user_directives"  "MemorySwapMax"
like   "outer user slice sets MemoryMax"      "$user_directives"  "MemoryMax"
# The inner slice is where the graduated throttle belongs.
like   "inner herdr slice sets MemoryHigh"    "$herdr_directives" "MemoryHigh"
like   "inner herdr slice sets MemorySwapMax" "$herdr_directives" "MemorySwapMax"

finish
