#!/usr/bin/env bash
# Phase 1 — base setup + persistence + SSH hardening.
# RUN ON: the VM (as root, or via run-remote.sh which sudo's).
#   ./deploy/run-remote.sh __DEV_USER__@<vm> deploy/10-base.sh DEV_USER=__DEV_USER__
set -euo pipefail

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
    ram_kib="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
    SWAP_GB=$(( (ram_kib + 1048575) / 1048576 ))   # KiB -> GiB, rounded up
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
