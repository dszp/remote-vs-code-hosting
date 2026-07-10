# Laptop shell helpers for the dev VM. Append to ~/.zshrc (zsh shown; tweak for bash).
# Pairs with the '__VM_SSH_ALIAS__' silent SSH host (mac/vm-alias-key-setup.sh).

# Open a VM workspace folder in a NEW VS Code window via Remote-SSH (silent '__VM_SSH_ALIAS__').
#   rcode | rcode .  -> /home/__DEV_USER__/workspace/<current local folder name>
#   rcode myproj     -> /home/__DEV_USER__/workspace/myproj
# Calls VS Code's real CLI directly so it can force a new window and a remote folder-uri.
# Override the host with RCODE_HOST=__VM_NAME__-cf (Cloudflare path).
rcode() {
  local host="${RCODE_HOST:-__VM_SSH_ALIAS__}" arg="${1:-}" folder
  if [[ -z "$arg" || "$arg" == "." ]]; then folder="${PWD:t}"; else folder="$arg"; fi
  local cli="/usr/local/bin/code"
  [[ -x "$cli" ]] || cli="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  "$cli" --new-window --folder-uri "vscode-remote://ssh-remote+${host}/home/__DEV_USER__/workspace/${folder}"
}

# Upload the clipboard image to the VM and copy back a remote path Claude can read
# (pasting a screenshot into a remote terminal only sends a local Mac path the VM can't
# open). Needs: brew install pngpaste. For a hotkey, see mac/rpaste-upload.sh.
#   screenshot -> rpaste -> ⌘V into Claude on the VM.
rpaste() {
  local host="${RCODE_HOST:-__VM_SSH_ALIAS__}" dir="${RPASTE_DIR:-/home/__DEV_USER__/.cache/pastes}"
  local name="paste-$(date +%Y%m%d-%H%M%S).png" tmp
  tmp="$(mktemp)" || return 1
  if ! pngpaste "$tmp" 2>/dev/null; then rm -f "$tmp"; print -u2 "rpaste: no image on the clipboard"; return 1; fi
  ssh "$host" "mkdir -p $dir && cat > '$dir/$name'" < "$tmp" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  printf '%s/%s' "$dir" "$name" | pbcopy
  print "rpaste: uploaded → $dir/$name  (remote path on clipboard — ⌘V into Claude on the VM)"
}
