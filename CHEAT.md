# Cheatsheet — remote dev VM (`__VM_NAME__`)

## Connect
- `ssh __VM_NAME__` — your **main** persistent session (auto-attaches; session is named after the
  folder you land in, home → `claude`). A 2nd plain `ssh __VM_NAME__` re-attaches the SAME session.
- `mosh __VM_NAME__` — resilient over roaming / flaky links, then `cs`.
- **VS Code:** Remote-SSH → `__VM_NAME__` (or `__VM_NAME__-cf` when off-tailnet) → open `~/workspace/<project>`.
- **Any browser (incl. iPad):** `https://__CODE_HOSTNAME__` (Access → code-server password).

## Sessions (`cs` on the VM)
- `cs` — attach/create the folder's session (home → `claude`)
- `cs <name>` — attach/create a **named** session
- `cs -n [base]` — a **new independent** session (`folder-2`, `folder-3`, …)
- `cs ls` — list sessions
- reattach later: `cs <name>` (on VM) · `devx <name>` (from the Mac)
- kill: `tmux kill-session -t <name>` (on VM) · `ssh __VM_NAME__ tmux kill-session -t <name>` (Mac)

## From the Mac (helpers in `~/.zshrc`)
- `devx` — **new** independent session (= `ssh -t __VM_NAME__ cs -n`)
- `devx <name>` — reattach/create a named session
- `devsh` — quick **non-tmux** scratch shell on the VM
- `ssh __VM_NAME__ cs ls` — list sessions without attaching

## Multiple terminals — which tool
- **More shells, one tab, same session:** tmux windows — `Ctrl-b c` new · `Ctrl-b n`/`p` or `Ctrl-b 0-9` switch · `Ctrl-b w` list · `Ctrl-b ,` rename
- **Independent tab/session:** `devx` (Mac) or `cs -n` (VM) — won't mirror
- **Non-tmux scratch:** VS Code "+" → **"shell (no tmux)"** · Mac `devsh` · inline `NO_AUTO_TMUX=1 bash`
- ⚠ Two clients on the **same** session mirror window-switching (tmux by design) — use separate sessions to avoid.

## tmux basics
- detach `Ctrl-b d` · reattach `cs <name>`
- windows: new `Ctrl-b c` · switch `Ctrl-b 0-9` / `n` / `p` · rename `Ctrl-b ,`
- panes: split `Ctrl-b %` (vertical) / `Ctrl-b "` (horizontal) · move `Ctrl-b <arrow>` · zoom `Ctrl-b z`
- scroll/copy mode: `Ctrl-b [` (then arrows/PgUp; `q` to exit)

## Claude Code
- Run `claude` **inside a tmux session** → it survives the laptop going offline.
- Reattach from anywhere: VS Code terminal · `ssh __VM_NAME__` · `mosh __VM_NAME__` then `cs`.
- The code-server **extension** panel is window-bound; the **tmux terminal** is the durable one.

## Secrets (`op` proxy)
- `op-mode status` — current mode + whether the Mac resolver socket is present
- **mac mode** (default): `op read 'op://…'` or `op run --env-file=.env -- wrangler deploy`
  → resolves on the Mac with **TouchID** (needs a Mac-originated session)
- **token mode** (headless): place a service-account token, `op-mode token`; revert with `op-mode mac`
- full notes: `~/OP-SECRETS.md` on the VM

## After a reboot
- `ssh __VM_NAME__` works on its own (tailscaled + sshd auto-start).
- The `claude` session is re-created empty by the boot service; anything that was *running* stopped — re-run `claude`.
- tmux + linger survive disconnect/logout, **not** reboot.
