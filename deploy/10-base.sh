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

echo ">> swap: ensure a swapfile exists (memory safety net, sized to RAM by default)"
# The VM ships with no swap, so a memory spike (e.g. several concurrent Claude Code sessions)
# has no cushion: the kernel OOM-killer culls processes — including the user systemd + tmux
# server — and every session dies (this happened 2026-07-12). A swapfile lets the box page
# and slow down instead of killing. Size = $SWAP_GB GiB; default "auto" = round(RAM) up to a
# whole GiB. SWAP_GB=0 skips. Idempotent: leaves any existing swap untouched. xfs rejects a
# fallocate'd swapfile ("swapfile has holes" — unwritten extents), so the file is written with
# dd. Paired with deploy/95-swap-monitor.sh, which alerts before swap fills.
SWAP_GB="${SWAP_GB:-auto}"
if [ "$(swapon --show=NAME --noheadings 2>/dev/null | wc -l)" -gt 0 ]; then
  echo "   swap already active — leaving it as-is: $(swapon --show --noheadings | tr '\n' ' ')"
elif [ "$SWAP_GB" = "0" ]; then
  echo "   SWAP_GB=0 — skipping swap provisioning"
else
  if [ "$SWAP_GB" = "auto" ]; then
    # rvc_swap_policy_gib (lib.sh) is the single definition of this rule; the swap
    # monitor (deploy/95) embeds the same function so the two cannot drift.
    SWAP_GB="$(rvc_swap_policy_gib)"
    [ "$SWAP_GB" -gt 0 ] 2>/dev/null || { echo "!! cannot read MemTotal — skipping swap" >&2; SWAP_GB=0; }
  fi
  echo "   creating /swapfile (${SWAP_GB} GiB, dd for xfs-safety)"
  dd if=/dev/zero of=/swapfile bs=1M count="$(( SWAP_GB * 1024 ))" status=none
  chmod 600 /swapfile
  restorecon /swapfile 2>/dev/null || true          # SELinux label (no-op if not enforcing)
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "   swap on: $(swapon --show --noheadings | tr '\n' ' ')"
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
