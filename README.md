# remote-vs-code

An always-on AlmaLinux 10 dev VM you reach with **native VS Code Remote-SSH**, where
**Claude Code keeps running even when the laptop is closed**.

> **This is a sanitized template.** Environment-specific values are written as
> `__PLACEHOLDER__` tokens (domain, hostnames, Proxmox host, dev user, Mac user,
> 1Password account/vault, etc.). Fill them in — see `env.example` for the full list —
> before running anything. No secrets are stored here; all are resolved from 1Password
> (`op`) at run time. See **Placeholders** at the bottom.

Native feel and persistence are *separate problems*, solved in separate layers:

| Layer | What | Why it's load-bearing |
|---|---|---|
| **Persistence** | `tmux` + `loginctl enable-linger` | Owns Claude Code's lifetime independent of any client. This is what makes "shut the laptop, keep running" true. |
| **Native editor** | VS Code Remote-SSH | Real desktop VS Code, full MS marketplace, extensions run remotely. |
| **Transport** | Tailscale (primary, carries UDP → `mosh`) + Cloudflare Tunnel/Access (secondary, no public port) | How the laptop reaches the host. |

Host: dedicated AlmaLinux **10** VM on **__PVE_HOST__** (CPU type `host`). Cloudflare **__CF_ACCOUNT__**
zone — SSH at `__SSH_HOSTNAME__`, browser code-server at `__CODE_HOSTNAME__`.

> Keep environment-specific details in a local, gitignored file (e.g. `PLAN.local.md`) — never in tracked files.

## Secrets: how this repo stays clean

All credentials are resolved on the **laptop** via the 1Password CLI (`op`, TouchID) and
pushed to the VM over SSH. Nothing secret is committed (`.gitignore` enforces it). The VM
holds almost no standing secrets:

- **Runtime secret retrieval on the VM** (rare) → a scoped **1Password Service Account** token, not biometric.
- **SSH keys on the VM** (git push, hops) → **forward the 1Password SSH agent** (key stays TouchID-gated on the laptop; see `config/ssh-config.snippet`).
- **Claude Code auth** → one-time `claude` OAuth login, persisted in `~/.claude`.

## How the scripts run

Host-setup scripts (`deploy/10`–`70`) are idempotent and run **on the VM**.
`deploy/run-remote.sh` ships a script over SSH via stdin and runs it with `sudo` — secrets
passed this way never touch the remote disk or `ps`. Resolve secrets locally first
(`op read`/`op run`), then call `run-remote.sh`.

```bash
# generic form
./deploy/run-remote.sh <ssh-target> deploy/NN-script.sh VAR=VAL ...
```

## Order of operations

Some steps are inherently interactive (browser/console) and can't be fully automated —
they're marked **[manual]**.

1. **Proxmox VM** — run against `root@__PVE_HOST__`:
   ```bash
   # 1Password-managed key? ssh-add reads $SSH_AUTH_SOCK, not ssh_config's IdentityAgent:
   PUBKEY="$(SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ssh-add -L | head -1)"
   ./deploy/run-remote.sh root@__PVE_HOST__ deploy/00-proxmox-vm.sh PUBKEY="$PUBKEY"
   ```
   Confirm `PVE_STORAGE`/`BRIDGE`/`VMID` for your __PVE_HOST__ first (see `env.example`). Verify the
   AlmaLinux 10 image URL in `00-proxmox-vm.sh` is current. Then find the VM IP
   (`qm guest cmd <VMID> network-get-interfaces`).

2. **Base + persistence + SSH hardening** — on the VM:
   ```bash
   ./deploy/run-remote.sh __DEV_USER__@<vm-ip> deploy/10-base.sh DEV_USER=__DEV_USER__
   ```
   ⚠ It sets key-only SSH auth — keep this session open and verify a **new** SSH session works before closing it.

3. **Tailscale (primary transport)** — on the VM. **[manual]** browser auth unless you pass `TS_AUTHKEY`:
   ```bash
   ./deploy/run-remote.sh __DEV_USER__@<vm-ip> deploy/20-tailscale.sh
   ```
   Note the MagicDNS name it prints → put it in `~/.ssh/config` `Host __VM_NAME__` (`config/ssh-config.snippet`).

4. **Cloudflare Tunnel (secondary transport)** — on the VM. First run prints the **[manual]** `cloudflared tunnel login` step; do it, then re-run:
   ```bash
   ./deploy/run-remote.sh __DEV_USER__@<vm-ip> deploy/30-cloudflared.sh \
       CF_TUNNEL_NAME=__VM_NAME__ CF_HOSTNAME=__SSH_HOSTNAME__
   ```
   **[manual, dashboard]** Create a self-hosted **Access** application for `__SSH_HOSTNAME__`
   (GitHub IdP + an Allow policy for your email). Then add the laptop `__VM_NAME__-cf` entry from
   `config/ssh-config.snippet`. (A headless **service token** is deferred — see "Deferred" below.)

5. **Claude Code** — on the VM:
   ```bash
   ./deploy/run-remote.sh __DEV_USER__@<vm-ip> deploy/40-claude-code.sh DEV_USER=__DEV_USER__
   ```
   Then **[manual]** in the persistent session: `tmux new -A -s claude` → `claude` (log in once).

6. **Laptop SSH config** — add the entries from `config/ssh-config.snippet` to `~/.ssh/config`
   (fill in the MagicDNS name). Install the VS Code **Remote - SSH** extension, connect to
   `__VM_NAME__`, open `~/workspace`. Set a terminal profile that runs `tmux new -A -s claude`.

7. **(Optional) code-server in the browser** — on the VM, then expose via Cloudflare:
   ```bash
   # install code-server (loopback :8080, password from 1Password)
   CODE_SERVER_PASSWORD="$(op read --account __OP_ACCOUNT__ 'op://__OP_VAULT__/__CODE_SERVER_PW_ITEM__/password')" \
       ./deploy/run-remote.sh __VM_NAME__ deploy/50-code-server.sh DEV_USER=__DEV_USER__
   # add it to the tunnel as its own hostname
   ./deploy/run-remote.sh __VM_NAME__ deploy/55-cloudflared-http.sh \
       CF_HTTP_HOSTNAME=__CODE_HOSTNAME__ CODE_SERVER_PORT=8080
   ```
   Then create a self-hosted **Access** app for `__CODE_HOSTNAME__` (GitHub IdP + the reusable
   policy) in the dashboard, and browse `https://__CODE_HOSTNAME__` from any device (incl. iPad).
   Its terminal can `tmux attach -t claude`. (Tailscale-serve is an alternative: `EXPOSE_TAILSCALE=1`.)

8. **Persistence niceties + shortcut** — on the VM:
   ```bash
   ./deploy/run-remote.sh __VM_NAME__ deploy/60-session-boot.sh DEV_USER=__DEV_USER__  # recreate 'claude' session on boot
   ./deploy/run-remote.sh __VM_NAME__ deploy/65-auto-attach.sh  DEV_USER=__DEV_USER__  # interactive shells auto-enter a folder-named session
   ./deploy/run-remote.sh __VM_NAME__ deploy/70-cs-shortcut.sh                   # install the `cs` helper on PATH
   ```

## Post-deploy enhancements (optional)

Quality-of-life layers added after the core is working. Each is independent.

**A. Silent VS Code host (`autodev`) — no TouchID on resume.** The 1Password SSH agent
re-locks on sleep, so VS Code Remote-SSH re-prompts for TouchID on every reconnect. A
dedicated key whose passphrase lives in the macOS login keychain connects silently, while
`ssh __VM_NAME__` keeps prompting as before.
```bash
./mac/autodev-key-setup.sh          # gen key, keychain, 1Password backup, install pubkey
```
Then add the printed `Host autodev` block to `~/.ssh/config` **above `Host *`** (first-match;
`IdentityAgent none` must win). Connect VS Code to `autodev`. Trade-off: anyone with your
*unlocked* Mac can `ssh autodev` with no challenge — that is the point. Keep the internet-facing
`__VM_NAME__-cf` on the 1Password agent (TouchID) instead.

**B. Remote attention notifications.** Make Claude on the VM raise a macOS notification on the
laptop, falling back to a phone push when the laptop is offline (the socket only exists while
connected, so a failed desktop delivery *is* "offline").
```bash
./mac/notify-bridge-setup.sh                                   # laptop: socat listener + LaunchAgent
./deploy/run-remote.sh __VM_NAME__ deploy/85-notify-hook.sh DEV_USER=__DEV_USER__   # VM: hook + push template
```
Add the `RemoteForward` for `~/.notify/mac.sock` to each VM host (see `config/ssh-config.snippet`).
Push is dormant until you fill `~/.notify/push.env` on the VM (Pushover or ntfy) and register a
device; `NOTIFY_PUSH_MODE` = `off|always|fallback`.

**C. Laptop helpers.** `config/shell-helpers.sh` (append to `~/.zshrc`) adds `rcode [folder]`
(open a VM workspace folder in a new Remote-SSH window) and `rpaste` (upload the clipboard image
to the VM and copy back a path Claude can read — pasting a screenshot into a remote terminal only
sends a local Mac path). For a screenshot hotkey, bind `mac/rpaste-upload.sh` in your launcher
(e.g. BetterTouchTool). **[manual]** A Finder **Quick Action** (Automator → "Quick Action" receiving
folders → Run Shell Script) makes a right-click "Open in VS Code Remote":
```zsh
host="autodev"   # or __VM_NAME__-cf for the Cloudflare fallback
cli="/usr/local/bin/code"; [ -x "$cli" ] || cli="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
for f in "$@"; do "$cli" --new-window --folder-uri "vscode-remote://ssh-remote+$host/home/__DEV_USER__/workspace/${f:t}"; done
```

**D. Extensions & per-folder settings over Remote-SSH.** UI-affecting extensions (e.g. Peacock
window colors) must be installed **in the remote** (Extensions view → "Install in SSH: …") to act
on the remote workspace's `.vscode/settings.json`. A gitignored `.vscode/settings.json` won't ride
along with `git clone`, so set such settings in the remote window directly.

## Cheatsheet

Day-to-day commands (also in [`CHEAT.md`](CHEAT.md)).

**Connect**
- `ssh __VM_NAME__` — main persistent session (auto-attaches; folder→session name, home→`claude`). A 2nd plain `ssh` re-attaches the same one.
- `mosh __VM_NAME__` then `cs` — resilient over roaming/flaky links.
- VS Code: Remote-SSH → `__VM_NAME__` (or `__VM_NAME__-cf` off-tailnet) → open `~/workspace/<project>`.
- Any browser (incl. iPad): `https://__CODE_HOSTNAME__`.

**Sessions (`cs` on the VM)**
- `cs` folder session · `cs <name>` named · `cs -n [base]` new independent (`folder-2`, …) · `cs ls` list
- reattach: `cs <name>` (VM) / `devx <name>` (Mac) · kill: `tmux kill-session -t <name>`

**From the Mac (helpers in `~/.zshrc`)**
- `devx` new independent session · `devx <name>` reattach/create named · `devsh` non-tmux scratch shell · `ssh __VM_NAME__ cs ls` list

**Multiple terminals**
- more shells, one tab: tmux windows — `Ctrl-b c` new · `Ctrl-b n`/`p` or `0-9` switch · `Ctrl-b w` list
- independent tab/session: `devx` (Mac) or `cs -n` (VM) — won't mirror
- non-tmux scratch: VS Code "+" → "shell (no tmux)" · Mac `devsh` · inline `NO_AUTO_TMUX=1 bash`
- ⚠ two clients on the *same* session mirror window-switching (tmux by design) — use separate sessions

**tmux basics** — detach `Ctrl-b d` · panes `Ctrl-b %` / `Ctrl-b "`, move `Ctrl-b <arrow>`, zoom `Ctrl-b z` · scroll `Ctrl-b [`

**Claude Code** — run `claude` *inside tmux* so it survives the laptop offline; reattach via VS Code terminal / `ssh` / `mosh` then `cs`.

**Secrets (`op` proxy)** — `op-mode status`; mac mode resolves `op read`/`op run --env-file` with TouchID on the Mac; `op-mode token` for headless. See `~/OP-SECRETS.md`.

**After reboot** — `ssh __VM_NAME__` works on its own; the `claude` session is re-created empty (re-run `claude`). tmux+linger survive disconnect/logout, not reboot.

## Windows client (basic access)

The VM is unchanged — Windows is a *client-only* concern, and only basic access is
supported (native VS Code + SSH). The Mac-only conveniences (the `op` TouchID
reverse-resolver in `mac/`, the `devx`/`devsh`/`rcode` shell helpers, `mosh`) are **not**
ported; use the browser code-server path or plain SSH instead.

What you need on Windows:

- **VS Code Remote-SSH**, **Tailscale**, and (for the secondary path) **cloudflared** all
  have native Windows builds — install and sign in the same as on the Mac.
- **SSH config** lives at `%USERPROFILE%\.ssh\config`. Use the same `Host __VM_NAME__` /
  `__VM_NAME__-cf` entries from `config/ssh-config.snippet`, but **delete the
  `IdentityAgent ...` line** — it's a macOS socket path. Keep `ForwardAgent yes`.
- **1Password SSH agent**: in 1Password → Settings → Developer, enable **Use the SSH
  agent** and the Windows app integration. Windows OpenSSH then talks to the agent over
  `\\.\pipe\openssh-ssh-agent` automatically (no `IdentityAgent` needed), and your key
  stays Windows-Hello-gated on the laptop — same trust model as TouchID on the Mac.
- **Getting your public key** (the step-1 `PUBKEY` one-liner is macOS-specific): with the
  1Password agent enabled, just run `ssh-add -L` in PowerShell and take the matching line.
- **Secrets**: there's no biometric `op` resolver on Windows. For the rare on-VM secret,
  use the scoped 1Password **service-account token** path (`op-mode token`) instead.
- **`mosh`** has no maintained native Windows client — rely on plain SSH/Tailscale, or the
  zero-install browser IDE at `https://__CODE_HOSTNAME__` for roaming/flaky links.

## If an `op`-gated step times out

You're probably away from the console (1Password locked). The script stops and reports where
it halted. Re-run the same command when you're back to TouchID-unlock — the scripts are
idempotent, so retries are safe.

## Verification

See the "Verification" section of `PLAN.local.md`. The core check: start a marker in
`tmux new -A -s claude`, fully disconnect, close the laptop, wait, reconnect and
`tmux attach -t claude` — the process is still running. That proves linger + tmux.

## Deferred: Cloudflare service token (headless CF access)

**Not built** — intentionally. The Cloudflare paths currently require an **interactive browser
GitHub login** to mint the Access token (~once per 24h per device; cloudflared caches it in
between). A **service token** would add *non-interactive* auth (client-id/secret headers) for:

- headless automation that connects **via Cloudflare** (cron, CI, scripts), or
- a phone/app SSH client that can't do the browser flow.

Why skipped: **Tailscale is the primary path and needs no interactive auth** — laptop and iPad
are already on the tailnet, and automation can use Tailscale too. A service token only earns its
keep if you need unattended access **specifically over Cloudflare**. Add it later in ~2 minutes:
Zero Trust → Access → **Service Auth** → create a token (store id/secret in 1Password) → add a
**Service Auth** policy to the app → set `TUNNEL_SERVICE_TOKEN_ID`/`TUNNEL_SERVICE_TOKEN_SECRET`
on the caller (`config/ssh-config.snippet` documents this).

## Not included (deliberately)

- **VS Code Remote Tunnels / `code tunnel`** browser access — relays through Microsoft infra tied to a GitHub/MS account; against the trust model. code-server is the browser path instead.
- **WARP** — Tailscale already carries UDP, so `mosh` works without it.
- A browser-WebIDE-in-containers approach (OpenVSCode + rootless Podman + a self-hosted LLM) — a different (multi-tenant, untrusted-agent) problem; mined for hardening ideas only.

## Secrets / op proxy (optional)

`deploy/80-op-proxy.sh` (VM) + `mac/op-resolver-setup.sh` (Mac) install an `op` wrapper that
resolves secrets two ways: **`mac` mode** routes `op read` / `op run --env-file` back to your
Mac via a `RemoteForward`'d socket so they resolve with **TouchID** (no inbound to the Mac,
nothing stored on the VM); **`token` mode** uses a local 1Password **service account**. Toggle
with `op-mode`. See the scripts' headers and `~/OP-SECRETS.md` (created on the VM).

## Placeholders

Fill these in (all live in `env.example`; some also appear in `config/ssh-config.snippet`):

| Token | Meaning | Example |
|---|---|---|
| `__BASE_DOMAIN__` | Your domain (Cloudflare zone) | `example.com` |
| `__SSH_HOSTNAME__` | Public hostname for SSH-over-Access | `dev.example.com` |
| `__CODE_HOSTNAME__` | Public hostname for browser code-server | `code.example.com` |
| `__CF_ACCOUNT__` | Cloudflare account name | `Personal` |
| `__VM_NAME__` | VM name / Tailscale node / SSH host alias / tunnel name | `dev` |
| `__DEV_USER__` | Login user on the VM | `dev` |
| `__MAC_USER__` | Your macOS username (op resolver paths/label) | `alex` |
| `__PVE_HOST__` | Proxmox host (SSH target for VM creation) | `pve` |
| `__PVE_TS_IP__` | Proxmox host's Tailscale IP (for `SSH_JUMP`) | `100.x.y.z` |
| `__VM_LAN_IP__` | VM's LAN IP (pre-Tailscale, for `SSH_JUMP`) | `192.168.1.50` |
| `__VMID__` | Proxmox VM ID | `200` |
| `__PVE_STORAGE__` / `__BRIDGE__` | Proxmox storage / network bridge | `local-lvm` / `vmbr0` |
| `__OP_ACCOUNT__` | 1Password account | `my.1password.com` |
| `__OP_VAULT__` | 1Password vault | `Private` |
| `__CODE_SERVER_PW_ITEM__` | 1Password item holding the code-server password | `code-server` |
| `__TAILSCALE_FQDN__` / `__TAILSCALE_IP__` / `__TAILSCALE_NAME__` | VM's MagicDNS name / Tailscale IP | — |
| `__TUNNEL_UUID__` | cloudflared tunnel UUID (generated) | — |
| `__CF_HOSTNAME__` / `__CODE_SERVER_PORT__` / `__CODE_SERVER_PASSWORD__` | filled by scripts/env at run time | — |
