# remote-vs-code

An always-on AlmaLinux 10 dev VM you reach with **native VS Code Remote-SSH**, where
**Claude Code keeps running even when the laptop is closed**.

> **This is a sanitized template.** Environment-specific values are written as
> `__PLACEHOLDER__` tokens (domain, hostnames, Proxmox host, dev user, 1Password
> account/vault, etc.). Fill them in — see `env.example` for the full list — before
> running anything. No secrets are stored here; all are resolved from 1Password (`op`)
> at run time. See **Placeholders** at the bottom.

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

## Daily use

- **Laptop, native:** VS Code Remote-SSH → `__VM_NAME__` (Tailscale) or `__VM_NAME__-cf` (Cloudflare, off-tailnet).
- **Any browser:** `https://__CODE_HOSTNAME__` (Access → code-server password).
- **Terminal:** `ssh __VM_NAME__` lands in tmux automatically; then `cs` (folder session), `cs <name>`, `cs ls`.
- **Resilient terminal:** `mosh __VM_NAME__` then `cs`.
- Run `claude` inside the tmux session for runs that survive the laptop going offline.

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
