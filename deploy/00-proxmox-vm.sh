#!/usr/bin/env bash
# Phase 0 — create the AlmaLinux 10 dev VM on __PVE_HOST__.
# RUN ON: root@__PVE_HOST__
#   PUBKEY must be a real SSH public key. NOTE: `ssh-add` reads $SSH_AUTH_SOCK, NOT
#   ~/.ssh/config's IdentityAgent — so with a 1Password-managed key, point it at the
#   1Password agent socket explicitly:
#     PUBKEY="$(SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ssh-add -L | head -1)"
#   ./deploy/run-remote.sh root@__PVE_HOST__ deploy/00-proxmox-vm.sh PUBKEY="$PUBKEY"
#
# Idempotent: if $VMID already exists it stops and tells you (won't clobber).
# AlmaLinux 10 requires the x86-64-v3 baseline -> we set CPU type to `host`.
set -euo pipefail

# ---- tunables (override via env) -----------------------------------------
VMID="${VMID:-__VMID__}"
VM_NAME="${VM_NAME:-__VM_NAME__}"
VM_CORES="${VM_CORES:-4}"
VM_MEM_MB="${VM_MEM_MB:-8192}"
VM_DISK_GB="${VM_DISK_GB:-60}"
PVE_STORAGE="${PVE_STORAGE:-__PVE_STORAGE__}" # where the VM disk lives (confirmed on __PVE_HOST__: a storage pool with enough free space)
BRIDGE="${BRIDGE:-__BRIDGE__}"
CI_USER="${CI_USER:-__DEV_USER__}"
PUBKEY="${PUBKEY:?set PUBKEY to your SSH public key — see header for the 1Password ssh-add hint}"
# Fail fast on a bad key BEFORE any side effects (a non-key string like
# "The agent has no identities." otherwise half-builds the VM, then qm rejects it).
case "$PUBKEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@*\ *|sk-ecdsa-*\ *) : ;;
  *) echo "PUBKEY does not look like an SSH public key: '$(printf '%.40s' "$PUBKEY")...'" >&2
     echo "  (with a 1Password key: SSH_AUTH_SOCK=<1P agent.sock> ssh-add -L | head -1)" >&2
     exit 1 ;;
esac
# Verify this URL points at the current Alma 10 GenericCloud image before running.
IMG_URL="${IMG_URL:-https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2}"
IMG_PATH="/var/lib/vz/template/iso/$(basename "$IMG_URL")"

command -v qm >/dev/null || { echo "qm not found — run this on a Proxmox host (root@__PVE_HOST__)"; exit 1; }

if qm status "$VMID" >/dev/null 2>&1; then
  echo "VM $VMID already exists — nothing to do. (qm destroy $VMID to start over.)"
  exit 0
fi

echo ">> downloading AlmaLinux 10 cloud image (if missing)"
[ -f "$IMG_PATH" ] || curl -fL --retry 3 -o "$IMG_PATH" "$IMG_URL"

echo ">> creating VM $VMID ($VM_NAME)"
qm create "$VMID" \
  --name "$VM_NAME" \
  --cores "$VM_CORES" --memory "$VM_MEM_MB" \
  --cpu host \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-single \
  --ostype l26 \
  --agent enabled=1

echo ">> importing disk to $PVE_STORAGE"
qm importdisk "$VMID" "$IMG_PATH" "$PVE_STORAGE"
qm set "$VMID" --scsi0 "${PVE_STORAGE}:vm-${VMID}-disk-0"
qm set "$VMID" --boot order=scsi0
qm disk resize "$VMID" scsi0 "${VM_DISK_GB}G"

echo ">> attaching cloud-init"
qm set "$VMID" --ide2 "${PVE_STORAGE}:cloudinit"
qm set "$VMID" --ciuser "$CI_USER"
qm set "$VMID" --ipconfig0 "ip=dhcp"
# Install the laptop public key for the cloud-init user.
tmpkey="$(mktemp)"; printf '%s\n' "$PUBKEY" > "$tmpkey"
qm set "$VMID" --sshkeys "$tmpkey"; rm -f "$tmpkey"

echo ">> starting VM $VMID"
qm start "$VMID"

cat <<EOF

VM $VMID created and starting.
  - Find its IP from your DHCP/Proxmox (or the guest agent: qm guest cmd $VMID network-get-interfaces).
  - First login: ssh ${CI_USER}@<vm-ip>   (key-based; cloud-init disabled the password).
  - Next: install Tailscale (deploy/20-tailscale.sh) so you can stop depending on the LAN IP.
EOF
