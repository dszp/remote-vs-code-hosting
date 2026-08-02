#!/usr/bin/env bash
# rvc_swap_policy_gib — the swap sizing rule (deploy/lib.sh), used by deploy/10-base.sh to
# PROVISION swap and embedded into deploy/95's swap-check.sh to NOTICE when the running
# box has drifted below it (e.g. RAM was upgraded; 10-base leaves existing swap alone).
set -uo pipefail
cd "$(dirname "$0")"

# deploy/lib.sh FIRST: it sets -e and defines its own ok()/die(); tests/lib.sh goes
# after so the assertions win the name clash.
. ../deploy/lib.sh
set +e
. ./lib.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# $1 = MemTotal kB, $2 = SwapTotal kB (default 0)
meminfo() {
  printf 'MemTotal:       %s kB\nMemFree:  1 kB\nSwapTotal:      %s kB\n' "$1" "${2:-0}" > "$TMP/meminfo"
  printf '%s' "$TMP/meminfo"
}

is "15 GiB box wants 16G"        "$(MEMINFO=$(meminfo 16269832) rvc_swap_policy_gib)" "16"
is "exactly 8 GiB wants 8G"      "$(MEMINFO=$(meminfo 8388608)  rvc_swap_policy_gib)" "8"
is "one KiB over 8 GiB wants 9G" "$(MEMINFO=$(meminfo 8388609)  rvc_swap_policy_gib)" "9"
is "a tiny box still wants 1G"   "$(MEMINFO=$(meminfo 1)        rvc_swap_policy_gib)" "1"
is "32 GiB box wants 32G"        "$(MEMINFO=$(meminfo 33554432) rvc_swap_policy_gib)" "32"

# Refuse to guess when MemTotal is unreadable — a wrong number here would either
# provision an absurd swapfile or nag forever about a phantom shortfall.
printf 'Garbage: nope\n' > "$TMP/bad"
out="$(MEMINFO=$TMP/bad rvc_swap_policy_gib)"; rc=$?
is "unreadable MemTotal reports 0" "$out" "0"
if [ "$rc" -ne 0 ]; then ok "unreadable MemTotal is a non-zero exit"
else fail "unreadable MemTotal is a non-zero exit" "rc=$rc"; fi

out="$(MEMINFO=$TMP/does-not-exist rvc_swap_policy_gib)"; rc=$?
is "missing meminfo reports 0" "$out" "0"
if [ "$rc" -ne 0 ]; then ok "missing meminfo is a non-zero exit"
else fail "missing meminfo is a non-zero exit" "rc=$rc"; fi

# --- what the box ACTUALLY has, for comparison against the policy -------------------
# Rounded UP, deliberately: every swap area spends a few KiB on its header, so two 8 GiB
# files total 16777208 kB, not 16777216. Truncating that reads as 15G and would report a
# correctly-sized box as short by 1 GiB forever.
is "two 8G swapfiles read as 16G, not 15G" \
   "$(MEMINFO=$(meminfo 16269832 16777208) rvc_swap_total_gib)" "16"
is "a single 8G swapfile reads as 8G" \
   "$(MEMINFO=$(meminfo 16269832 8388604)  rvc_swap_total_gib)" "8"
is "no swap at all reads as 0" \
   "$(MEMINFO=$(meminfo 16269832 0)        rvc_swap_total_gib)" "0"

# The whole point: this box's real numbers must NOT look like a shortfall.
want="$(MEMINFO=$(meminfo 16269832 16777208) rvc_swap_policy_gib)"
have="$(MEMINFO=$(meminfo 16269832 16777208) rvc_swap_total_gib)"
if [ "$have" -ge "$want" ]; then ok "16 GiB RAM + two 8 GiB swapfiles is not flagged short"
else fail "16 GiB RAM + two 8 GiB swapfiles is not flagged short" "want=$want have=$have"; fi

# And a genuine shortfall still is: 15 GiB RAM with the original single 8 GiB file.
want2="$(MEMINFO=$(meminfo 16269832 8388604) rvc_swap_policy_gib)"
have2="$(MEMINFO=$(meminfo 16269832 8388604) rvc_swap_total_gib)"
if [ "$have2" -lt "$want2" ]; then ok "15 GiB RAM with one 8 GiB swapfile IS flagged short"
else fail "15 GiB RAM with one 8 GiB swapfile IS flagged short" "want=$want2 have=$have2"; fi

# --- the drift guard: deploy/95 must ship the SAME function, not a copy of the rule ----
SWAP_CHECK="../deploy/build/swap-check.sh"
if [ -r "$SWAP_CHECK" ]; then
  like "swap-check.sh embeds the policy function" "$(cat "$SWAP_CHECK")" "rvc_swap_policy_gib"
  like "swap-check.sh embeds the total function"  "$(cat "$SWAP_CHECK")" "rvc_swap_total_gib"
  # Byte-identical body, so the two can never disagree about what the policy is.
  fn_lib="$(declare -f rvc_swap_policy_gib | tail -n +2)"
  fn_chk="$(sed -n '/^rvc_swap_policy_gib ()/,/^}/p' "$SWAP_CHECK" | tail -n +2)"
  is "the embedded function is byte-identical to lib.sh's" "$fn_chk" "$fn_lib"
  # And 10-base must not carry its own copy of the arithmetic.
  unlike "10-base.sh no longer hard-codes the rounding" \
         "$(cat ../deploy/10-base.sh)" "1048575"
else
  printf '  skip  swap-check.sh drift guard (build ../deploy/build/swap-check.sh first)\n'
fi

printf '\n%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
