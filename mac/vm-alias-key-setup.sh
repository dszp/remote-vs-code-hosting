#!/usr/bin/env bash
# Create a dedicated SSH key for a SILENT VS Code Remote-SSH host ('__VM_SSH_ALIAS__') that does
# NOT go through the 1Password SSH agent — so VS Code reconnects after the laptop resumes
# with NO TouchID prompt. Your interactive `ssh __VM_NAME__` keeps prompting via 1Password.
# Run ON YOUR MAC.
#
#   ./mac/vm-alias-key-setup.sh
# Override defaults via env: OP_ACCOUNT, OP_VAULT, SSH_HOST, VM_ALIAS_HOST, KEY_PATH,
#   DEV_USER, WORKSPACE, BACKUP_TO_OP=0 (skip the 1Password backup).
#
# Why a separate key (not the 1Password agent): the 1Password agent re-locks on sleep and
# re-prompts on the next connection. VS Code Remote-SSH reconnects constantly, so that's a
# TouchID prompt every resume. A key whose passphrase lives in the macOS login keychain
# (auto-unlocked at login) authenticates silently. Trade-off: anyone with your UNLOCKED
# Mac can `ssh __VM_SSH_ALIAS__` with no challenge — that is the explicit goal here. The key is still
# encrypted at rest and, optionally, mirrored into 1Password as a record.
set -euo pipefail

OP_ACCOUNT="${OP_ACCOUNT:-__OP_ACCOUNT__}"
OP_VAULT="${OP_VAULT:-__OP_VAULT__}"
SSH_HOST="${SSH_HOST:-__VM_NAME__}"          # existing Host used to install the pubkey on the VM
VM_ALIAS_HOST="${VM_ALIAS_HOST:-__VM_SSH_ALIAS__}"   # the new silent Host alias to create
KEY_PATH="${KEY_PATH:-$HOME/.ssh/__VM_SSH_ALIAS___ed25519}"
DEV_USER="${DEV_USER:-__DEV_USER__}"             # login user on the VM
WORKSPACE="${WORKSPACE:-/home/$DEV_USER/workspace}"
BACKUP_TO_OP="${BACKUP_TO_OP:-1}"

OP="$(command -v op || echo /opt/homebrew/bin/op)"

[ -e "$KEY_PATH" ] && { echo "!! $KEY_PATH already exists — aborting (remove it or set KEY_PATH)"; exit 1; }

echo ">> generating $KEY_PATH (ed25519, random passphrase kept only in this shell)"
PASS="$(openssl rand -base64 24)"
ssh-keygen -t ed25519 -f "$KEY_PATH" -N "$PASS" -C "$VM_ALIAS_HOST-vscode-no-touchid" -q
echo "   $(ssh-keygen -lf "$KEY_PATH.pub")"

if [ "$BACKUP_TO_OP" = "1" ] && [ -x "$OP" ]; then
  echo ">> backing up the key into 1Password ($OP_VAULT vault)"
  "$OP" item create --account "$OP_ACCOUNT" --vault "$OP_VAULT" --category "Secure Note" \
    --title "$VM_ALIAS_HOST SSH key (VS Code Remote-SSH)" \
    "passphrase[password]=$PASS" \
    "public key[text]=$(cat "$KEY_PATH.pub")" \
    "description[text]=Dedicated keychain-backed key for the '$VM_ALIAS_HOST' SSH host (silent VS Code Remote-SSH). Bypasses the 1Password agent by design (IdentityAgent none). Passphrase is also in the macOS login keychain." \
    "private key[file]=$KEY_PATH" >/dev/null && echo "   saved." || echo "   (1Password backup failed; passphrase is still in the keychain after the next step)"
else
  echo ">> skipping 1Password backup (BACKUP_TO_OP=$BACKUP_TO_OP, op present: $([ -x "$OP" ] && echo yes || echo no))"
fi

echo ">> storing the passphrase in the macOS login keychain"
SHIM="$(mktemp)"; printf '#!/bin/bash\nprintf "%%s" "$VM_ALIAS_PASS"\n' > "$SHIM"; chmod 700 "$SHIM"
VM_ALIAS_PASS="$PASS" SSH_ASKPASS="$SHIM" SSH_ASKPASS_REQUIRE=force ssh-add --apple-use-keychain "$KEY_PATH"
rm -f "$SHIM"

echo ">> installing the public key on the VM (via existing Host '$SSH_HOST'; one TouchID)"
ssh-copy-id -i "$KEY_PATH.pub" "$SSH_HOST"

# Derive the VM's real HostName from the existing Host so we don't hardcode an IP.
VM_HOSTNAME="$(ssh -G "$SSH_HOST" 2>/dev/null | awk '/^hostname /{print $2; exit}')"
[ -n "$VM_HOSTNAME" ] || VM_HOSTNAME="__SAME_AS_${SSH_HOST}__"

cat <<EOF

>> ADD this block to ~/.ssh/config, ABOVE your 'Host *' block (ssh_config is first-match,
   and 'IdentityAgent none' must win over any agent set under 'Host *'):

  Host $VM_ALIAS_HOST
    HostName $VM_HOSTNAME
    User $DEV_USER
    IdentityAgent none
    IdentityFile $KEY_PATH
    IdentitiesOnly yes
    UseKeychain yes

   Then: ssh $VM_ALIAS_HOST   (expect a SILENT connect, even right after a resume)
   In VS Code: Remote-SSH -> '$VM_ALIAS_HOST'; open $WORKSPACE/<project>.
EOF
