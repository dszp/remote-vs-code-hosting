# Laptop shell helpers for the dev VM. Append to ~/.zshrc (zsh shown; tweak for bash).
# Pairs with the '__VM_SSH_ALIAS__' silent SSH host (mac/vm-alias-key-setup.sh).

# Main interactive shell on the VM, over mosh (survives sleep, IP changes and a closed lid;
# the VM's ~/.bashrc auto-attaches the tmux session, so a dropped link loses nothing).
#   dv -> host '__VM_NAME__': keys via the 1Password SSH agent — a TouchID prompt per connect.
#   da -> host '__VM_SSH_ALIAS__':  dedicated passphrase-less key + IdentityAgent none — silent.
# Same VM, same tmux sessions; pick by whether you want the prompt. Under mosh that really is
# the only difference: mosh closes the ssh channel once mosh-server is up, so neither host's
# ForwardAgent nor its RemoteForward survives into the session. The always-on '__VM_NAME__-fwd'
# LaunchAgent (mac/forward-agent-setup.sh) is what keeps the op/notify sockets live — that is
# why mosh doesn't cost you TouchID secrets or notifications on the VM.
# Needs UDP 60000-61000 end to end: Tailscale carries it, the Cloudflare Access path does not
# (there, fall back to `ssh __VM_NAME__-cf`).
alias dv='mosh __VM_NAME__'
alias da='mosh __VM_SSH_ALIAS__'

# Extra INDEPENDENT tmux session on the VM — won't mirror your main one:
#   devx        new session ('folder-2', …)
#   devx work   reattach/create one named 'work'
# These use ssh (not mosh) because they run a one-shot command; set DEVX_HOST=__VM_SSH_ALIAS__ to use
# the silent key and skip the agent prompt, at the cost of agent forwarding on the VM.
devx() { ssh -t "${DEVX_HOST:-__VM_NAME__}" cs "${1:--n}"; }

# Quick NON-tmux scratch shell on the VM (nothing to detach from, nothing left running):
devsh() { ssh -t "${DEVX_HOST:-__VM_NAME__}" 'NO_AUTO_TMUX=1 bash -l'; }

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
