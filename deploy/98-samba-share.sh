#!/usr/bin/env bash
# SMB file sharing to the Mac over Tailscale ONLY, so Finder / Word / Excel / Preview open
# files on the VM in place (no download step). Chosen over SSHFS: macFUSE needs a kext
# (Reduced Security boot on Apple Silicon) and Office's save-by-rename is fragile over FUSE.
#
# What it sets up:
#   [share]      ~/share, always on, read-write. The default drop folder for generated docs.
#   smbshare     /usr/local/bin helper: publish/unpublish any folder you OWN (e.g.
#                ~/workspace or one project) as an extra share, no sudo, via Samba usershares:
#                  smbshare on ~/workspace/NetSapiens [name]   smbshare off NetSapiens
#                  smbshare list
#
# Lockdown (SMB can't do SSH-key auth, so the gates are network + protocol + password):
#   - An nftables table (inet rvc_smb) drops tcp/445 on every interface but lo + tailscale0,
#     so the Proxmox LAN never reaches smbd. It is loaded by smb.service's own ExecStartPre,
#     so smbd cannot start without it. Samba's `hosts allow` = tailnet ranges backs it up.
#     Samba can't bind tailscale0 itself: it drops non-broadcast (point-to-point) interfaces,
#     by name AND by address ("not adding non-broadcast interface tailscale0").
#     Tighten further with a tailnet ACL that lets only the Mac reach this host on tcp:445.
#   - SMB3 minimum, encryption + signing required, no guest, no NetBIOS, no printers.
#   - Every share is valid-users = $DEV_USER; usershares are owner-only, max 20.
#   - SELinux stays enforcing: samba_enable_home_dirs lets smbd read under /home instead of
#     relabeling repo folders samba_share_t.
#
# The SMB password is SEPARATE from the login password and is set by hand, once, on the VM:
#   sudo smbpasswd -a __DEV_USER__        (store it in 1Password + the Mac Keychain)
#
# Mac side, once:
#   defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
#   ./mac/smb-mount-setup.sh   (LaunchAgent keeps smb://__DEV_USER__@<vm-tailscale-ip>/share mounted)
#   Finder's Cmd-K hangs on "Connecting..." here (its NetAuthSysAgent waits on sharingd for
#   an Apple ID), so the Mac mounts through that LaunchAgent instead; see its header.
#
# RUN ON: the VM (needs root).
#   ./deploy/run-remote.sh __VM_NAME__ deploy/98-samba-share.sh DEV_USER=__DEV_USER__
# Idempotent: rewrites smb.conf and the helper each run; existing usershares survive.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="/home/$DEV_USER"
SHARE_DIR="$HOME_DIR/share"
USERSHARE_DIR=/var/lib/samba/usershares
USERSHARE_GROUP=usershares

[ "$(id -u)" -eq 0 ] || die "run as root (run-remote.sh sudo's for you)"
id "$DEV_USER" >/dev/null 2>&1 || die "no such user: $DEV_USER"

log "installing samba"
dnf -y -q install samba samba-common-tools

install -d -o "$DEV_USER" -g "$DEV_USER" -m 0700 "$SHARE_DIR"

# Usershare store: sticky, group-writable by members only.
groupadd -f "$USERSHARE_GROUP"
install -d -o root -g "$USERSHARE_GROUP" -m 1770 "$USERSHARE_DIR"
usermod -aG "$USERSHARE_GROUP" "$DEV_USER"

log "writing /etc/samba/smb.conf"
[ -f /etc/samba/smb.conf.rvc-orig ] || cp -a /etc/samba/smb.conf /etc/samba/smb.conf.rvc-orig
cat > /etc/samba/smb.conf <<EOF
# Managed by remote-vs-code deploy/98-samba-share.sh. Edits are overwritten on re-run.
[global]
  workgroup = WORKGROUP
  server role = standalone server
  security = user
  map to guest = never
  restrict anonymous = 2

  hosts allow = 127.0.0.1 ::1 100.64.0.0/10 fd7a:115c:a1e0::/48
  hosts deny = ALL
  smb ports = 445
  disable netbios = yes

  server min protocol = SMB3
  server smb encrypt = required
  server signing = mandatory

  load printers = no
  printing = bsd
  printcap name = /dev/null
  disable spoolss = yes

  # Finder/Office friendliness: Mac metadata in xattrs, Mac-illegal chars mapped.
  vfs objects = catia fruit streams_xattr
  fruit:metadata = stream
  fruit:model = MacSamba
  fruit:posix_rename = yes
  fruit:zero_file_id = yes
  fruit:wipe_intentionally_left_blank_rfork = yes
  fruit:delete_empty_adfiles = yes

  usershare path = $USERSHARE_DIR
  usershare max shares = 20
  usershare owner only = yes
  usershare allow guests = no

[share]
  path = $SHARE_DIR
  valid users = $DEV_USER
  read only = no
  create mask = 0644
  directory mask = 0755
EOF
testparm -s >/dev/null 2>&1 || { testparm -s; die "smb.conf failed testparm"; }

log "SELinux: allowing smbd under /home"
setsebool -P samba_enable_home_dirs on
restorecon -R "$SHARE_DIR" "$USERSHARE_DIR"

log "nftables: tcp/445 from lo + tailscale0 only"
cat > /etc/samba/tailscale-only.nft <<'EOF'
# Loaded by smb.service ExecStartPre (deploy/98-samba-share.sh). Re-loadable: the first two
# lines make the delete idempotent.
table inet rvc_smb
delete table inet rvc_smb
table inet rvc_smb {
  chain input {
    type filter hook input priority -10; policy accept;
    tcp dport { 139, 445 } iifname != { "lo", "tailscale0" } drop
  }
}
EOF
install -d /etc/systemd/system/smb.service.d
rm -f /etc/systemd/system/smb.service.d/10-tailscale.conf
cat > /etc/systemd/system/smb.service.d/10-tailscale-only.conf <<'EOF'
[Service]
ExecStartPre=/usr/sbin/nft -f /etc/samba/tailscale-only.nft
EOF

log "installing /usr/local/bin/smbshare"
cat > /usr/local/bin/smbshare <<'SMBSHARE'
#!/usr/bin/env bash
# smbshare — publish a folder you own as an SMB share (Tailscale-only Samba on this VM).
#   smbshare on <dir> [name]   share <dir> read-write as <name> (default: folder name)
#   smbshare off <name|dir>    stop sharing it
#   smbshare list              what's shared (the fixed 'share' = ~/share is always on)
# Mac: Cmd-K > smb://<this-vm-tailscale-ip>/<name>
set -euo pipefail
GROUP=usershares
die() { echo "smbshare: $*" >&2; exit 1; }

# The group may have been granted after this login; run net through sg until re-login.
net_us() {
  if id -nG | tr ' ' '\n' | grep -qx "$GROUP"; then net usershare "$@"
  else sg "$GROUP" -c "$(printf '%q ' net usershare "$@")"; fi
}
share_name() { basename "$1" | tr -c 'A-Za-z0-9_.\n-' '-'; }

case "${1:-list}" in
  on)
    [ -n "${2:-}" ] || die "usage: smbshare on <dir> [name]"
    dir=$(realpath -e -- "$2") || die "no such folder: $2"
    [ -d "$dir" ] || die "not a folder: $dir"
    [ "$(stat -c %U "$dir")" = "$USER" ] || die "you don't own $dir (usershares are owner-only)"
    name=${3:-$(share_name "$dir")}
    [ "$name" != share ] || die "'share' is reserved for ~/share"
    # Raw Unix-user SID: a non-root `net` can't resolve names to SIDs (Access Denied).
    net_us add "$name" "$dir" "smbshare" "S-1-22-1-$(id -u):F" guest_ok=n
    echo "on: $name -> $dir" ;;
  off)
    [ -n "${2:-}" ] || die "usage: smbshare off <name|dir>"
    name=$2; [ -d "$2" ] && name=$(share_name "$(realpath -- "$2")")
    net_us delete "$name"
    echo "off: $name" ;;
  list|ls)
    echo "share -> $HOME/share (always on)"
    net_us info 2>/dev/null | awk -F= '/^\[/{n=substr($0,2,length($0)-2)} /^path=/{print n" -> "$2}' ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
SMBSHARE
chmod 0755 /usr/local/bin/smbshare

systemctl daemon-reload
systemctl enable --now smb
systemctl restart smb
systemctl disable --now nmb 2>/dev/null || true

log "listening sockets for smbd:"
ss -tlnpH | grep -w smbd >&2 || warn "smbd is not listening yet"
nft_ok=$(nft list chain inet rvc_smb input 2>/dev/null | grep -c 'dport { 139, 445 }' || true)
[ "$nft_ok" -ge 1 ] || die "nftables guard table inet rvc_smb is not loaded"

pdbedit -L 2>/dev/null | grep -q "^$DEV_USER:" \
  || warn "no SMB password yet: run 'sudo smbpasswd -a $DEV_USER' on the VM"
TS_IP4=$(ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
ok "samba up: smb://${TS_IP4:-<tailscale-ip>}/share  (+ smbshare on <dir>)"
