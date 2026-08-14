#!/usr/bin/env bash
# Phase 1 — base setup + persistence + SSH hardening.
# RUN ON: the VM (as root, or via run-remote.sh which sudo's).
#   ./deploy/run-remote.sh __DEV_USER__@<vm> deploy/10-base.sh DEV_USER=__DEV_USER__
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEV_USER="${DEV_USER:-__DEV_USER__}"

echo ">> packages (EPEL for mosh; tmux/git/curl/tar)"
dnf install -y epel-release
dnf install -y tmux git curl tar mosh

echo ">> swap: ensure swap MEETS POLICY (memory safety net, sized to RAM by default)"
# The VM ships with no swap, so a memory spike (e.g. several concurrent Claude Code sessions)
# has no cushion: the kernel OOM-killer culls processes — including the user systemd + tmux
# server — and every session dies (this happened 2026-07-12). A swapfile lets the box page
# and slow down instead of killing. Size = $SWAP_GB GiB; default "auto" = round(RAM) up to a
# whole GiB. SWAP_GB=0 skips. xfs rejects a fallocate'd swapfile ("swapfile has holes" —
# unwritten extents), so files are written with dd. Paired with deploy/95-swap-monitor.sh,
# which alerts before swap fills.
#
# This step used to stop at "swap exists", which meant a RAM increase silently left swap
# UNDER policy with nothing to say so — 16 GiB against a 24 GiB rule after the 2026-08-11
# bump. It now TOPS UP with an additional file sized to the shortfall. Existing swap is
# still never touched: swapoff pages everything back into RAM, the exact opposite of what a
# box under pressure needs, so a top-up file is the safe way to grow.
SWAP_GB="${SWAP_GB:-auto}"
if [ "$SWAP_GB" = "0" ]; then
  echo "   SWAP_GB=0 — skipping swap provisioning"
else
  if [ "$SWAP_GB" = "auto" ]; then
    # rvc_swap_policy_gib (lib.sh) is the single definition of this rule; the swap
    # monitor (deploy/95) embeds the same function so the two cannot drift.
    SWAP_GB="$(rvc_swap_policy_gib)"
  fi
  have_gb="$(rvc_swap_total_gib)"
  if ! [ "${SWAP_GB:-0}" -gt 0 ] 2>/dev/null; then
    echo "!! cannot read MemTotal — skipping swap" >&2
  elif [ "${have_gb:-0}" -ge "$SWAP_GB" ] 2>/dev/null; then
    echo "   swap meets policy (${have_gb}G >= ${SWAP_GB}G): $(swapon --show --noheadings | tr '\n' ' ')"
  else
    add_gb=$(( SWAP_GB - have_gb ))
    # Never fill / to provision swap: a full root breaks far more than short swap does.
    # Keep 5 GiB clear after the write.
    avail_gb="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"
    if [ "${avail_gb:-0}" -lt $(( add_gb + 5 )) ] 2>/dev/null; then
      echo "!! want ${add_gb}G more swap but only ${avail_gb:-?}G free on / — skipping (free space, or set SWAP_GB)" >&2
    else
      # First file is /swapfile; top-ups take the next free /swapfileN so the existing one
      # is never rewritten. Once a top-up is active, have_gb >= policy and this is a no-op.
      if [ "${have_gb:-0}" -eq 0 ]; then
        f=/swapfile
      else
        n=2; while [ -e "/swapfile$n" ]; do n=$(( n + 1 )); done; f="/swapfile$n"
      fi
      echo "   creating $f (${add_gb} GiB, dd for xfs-safety) to reach the ${SWAP_GB}G policy"
      dd if=/dev/zero of="$f" bs=1M count="$(( add_gb * 1024 ))" status=none
      chmod 600 "$f"
      restorecon "$f" 2>/dev/null || true          # SELinux label (no-op if not enforcing)
      mkswap "$f" >/dev/null
      swapon "$f"
      grep -q "^$f " /etc/fstab || echo "$f none swap sw 0 0" >> /etc/fstab
      echo "   swap on: $(swapon --show --noheadings | tr '\n' ' ')"
    fi
  fi
fi

echo ">> inotify: raise the file-watcher limits (VS Code Remote-SSH ENOSPC)"
# Sibling of the swapfile above: another kernel resource whose distro default is too small
# for this box's actual workload. The default 8192 watches is exhausted by a workspace with
# node_modules/.git plus a few reconnecting Remote-SSH windows, and the editor then stops
# watching files with "ENOSPC: System limit for number of file watchers reached".
# rvc_ensure_inotify_limits (deploy/lib.sh) never lowers a limit and never overwrites an
# existing drop-in. Paired with files.watcherExclude in deploy/67-vscode-terminal-settings.sh,
# which caps what VS Code asks to watch in the first place.
rvc_ensure_inotify_limits

echo ">> ensure dev user $DEV_USER exists with sudo"
if ! id "$DEV_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$DEV_USER"
fi
usermod -aG wheel "$DEV_USER"   # wheel = sudo on RHEL-family

echo ">> enable lingering for $DEV_USER (the load-bearing persistence bit)"
# Without this, logind can reap the tmux server when the last session ends.
loginctl enable-linger "$DEV_USER"

echo ">> tmux: drop a sane default config if none present"
sudo -u "$DEV_USER" bash -c '
  cfg="$HOME/.tmux.conf"
  if [ ! -f "$cfg" ]; then
    cat > "$cfg" <<TMUX
set -g history-limit 100000
set -g mouse on
set -g status-interval 5
setw -g aggressive-resize on
TMUX
  fi
'

echo ">> SSH hardening (key-only auth)"
install -m 0644 /dev/stdin /etc/ssh/sshd_config.d/10-rvc-hardening.conf <<'SSHD'
# Managed by remote-vs-code. Defense in depth even behind Tailscale / CF Access.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
SSHD
sshd -t && systemctl reload sshd
echo "   (left a working key-based session? good. test a NEW ssh session before closing this one.)"

echo ">> firewall: keep inbound closed except what we actually use"
if systemctl is-active --quiet firewalld; then
  # SSH stays reachable on the LAN for first-boot; tighten later if you want SSH
  # to be Tailscale-only. mosh UDP range allowed for the tailscale path.
  firewall-cmd --permanent --add-service=ssh || true
  firewall-cmd --permanent --add-port=60000-61000/udp || true
  firewall-cmd --reload || true
fi

echo ">> done. workspace dir:"
sudo -u "$DEV_USER" mkdir -p "/home/$DEV_USER/workspace"
echo "   /home/$DEV_USER/workspace"
