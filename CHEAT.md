# Cheatsheet — remote dev VM (`__VM_NAME__`)

## Connect
- `ssh __VM_NAME__` — auto-attaches a persistent session named after the folder you land in
  (home → `claude`). A 2nd terminal opened while that session is being viewed gets `folder-2`
  (it won't hijack/mirror the one Claude's in); use `cs <folder>` to force the same one.
- `mosh __VM_NAME__` — resilient over roaming / flaky links, then `cs`.
- **VS Code:** Remote-SSH → `__VM_NAME__` (or `__VM_NAME__-cf` when off-tailnet) → open `~/workspace/<project>`.
- **Any browser (incl. iPad):** `https://__CODE_HOSTNAME__` (Access → code-server password).

## Sessions (`cs` on the VM)
- `cs` — attach/create the current folder's session (home → `claude`); `cs .` is the same
- `cs <dir>` — name a session after a folder **and** start it there; Tab-completes like `cd`
  (`cs Rem⇥` → `cs Remote-VS-Code`), so it works from `~/workspace` without `cd`-ing in first
- `cs <name>` — attach/create a plain **named** session
- `cs -n [base]` — a **new independent** session (`folder-2`, `folder-3`, …)
- `cs s` / `cs d` / `cs k` — **s**witch to / **d**etach all clients from / **k**ill a session;
  bare = **fzf picker** (the list shows each session's client count), or pass a name to act
  directly (`cs k Remote-VS-Code-2`). Aliases: `cs switch`/`detach`/`kill` · `cs ls` — just list
- `cs` attaches with `-D`: a reconnect detaches the stale client, so **no mirror/scroll-lock**
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
- ⚠ Two clients on the **same** session mirror window-switching (tmux by design) — use separate sessions, or `tmux detach-client -a` to drop every client **but yours** (never ends the session).

## tmux basics
- **prefix** = `Ctrl-b` — press & release it, *then* the key (so "`Ctrl-b d`" = prefix, then `d`)
- detach `Ctrl-b d` · reattach with `cs <name>` (or `tmux attach -t <name>`)
- windows (tabs): new `Ctrl-b c` · switch `Ctrl-b 0-9` / `n` / `p` · list `Ctrl-b w` · rename `Ctrl-b ,`
- panes (splits): `Ctrl-b %` vertical · `Ctrl-b "` horizontal · move `Ctrl-b <arrow>` · zoom `Ctrl-b z`
- scroll back: `Ctrl-b [` then arrows/PgUp (`q` to exit) — or just mouse-wheel / tap-drag (mouse is on)
- **the same by hand** (what `cs` wraps — useful when `cs` isn't on PATH):
  - `cs` / `cs <name>` → `tmux new -A -D -s <name>` — attach if it exists, else create (`-D` drops a stale client)
  - `cs ls` → `tmux ls` · `cs -n` → `tmux new -s <name>` (always a fresh session)
  - `cs s <name>` → `tmux switch-client -t <name>` (inside tmux) / `tmux attach -d -t <name>` (from outside)
  - `cs d <name>` → `tmux detach-client -s <name>` (boot all its clients) · `cs k <name>` → `tmux kill-session -t <name>`

## tmux advanced — the next useful bits
- **command prompt:** `Ctrl-b :` then a tmux command — everything below also has a `:command` form
- **sessions:** rename `Ctrl-b $` · visual switcher `Ctrl-b s` · next/prev `Ctrl-b )` / `(` · last-used `Ctrl-b L`
- **windows:** find by name `Ctrl-b f` · last-used `Ctrl-b l` · move to another index `Ctrl-b .` · kill `Ctrl-b &`
- **panes:** resize `Ctrl-b Ctrl-<arrow>` (keep Ctrl held; repeatable) or `:resize-pane -L/-R/-U/-D 5` · cycle layouts `Ctrl-b <space>` · swap `Ctrl-b {` / `}` · kill `Ctrl-b x`
- **pane ↔ window:** pop a pane out to its own window `Ctrl-b !` · pull a window in as a pane `:join-pane -s <window>`
- **copy / search scrollback:** in copy mode (`Ctrl-b [`) search `/` (down) or `?` (up), `n`/`N` to repeat; select `Space`, copy `Enter`, paste `Ctrl-b ]`. (Search keys are vi-style; enable with `:setw -g mode-keys vi`. With the mouse, just drag to select+copy.)
- **broadcast input:** `:setw synchronize-panes on` types into every pane at once (`off` to stop) — handy for the same command across hosts
- **reload / inspect:** `Ctrl-b :source-file ~/.tmux.conf` after editing the config · `Ctrl-b ?` lists every key binding (`q` exits) · toggle mouse `Ctrl-b m`

## tmux config — what we changed (`~/.tmux.conf`; repo copy `config/tmux.conf`)
- **mouse on** (`set -g mouse on`) — wheel / iPad tap-drag scrolls the scrollback; toggle with `Ctrl-b m` (status bar shows **MOUSE ON/OFF**). Wheel is tuned to **1 line per tick** (iPad tap-drag fired too many events and felt jumpy). **Why the toggle matters:** Claude Code now runs **fullscreen and grabs the mouse** too (so you can click its UI). tmux-mouse **and** Claude-mouse on at the same time = `aN;NaNM` click-drag garbage — only one layer should own the mouse. Working in Claude and want to click? `Ctrl-b m` hands the mouse to Claude; flip it back for wheel scrollback in shells.
- **mouse-state indicator** — the status bar (right side) shows `MOUSE ON` (green = tmux owns the mouse) or `MOUSE OFF` (red = handed to Claude / native selection), so you always know which layer has it.
- **clipboard bridge (OSC 52)** (`set-clipboard on` + `terminal-features ',*:clipboard'`) — copying in tmux (mouse drag-end **or** copy-mode `Enter`) also lands on your **local** Mac/iPad clipboard. Needs ghostty `clipboard-write = allow` on the client. **Works over SSH only** — mainline `mosh` drops OSC 52, so over mosh use **Shift-drag** (hold Shift while selecting → ghostty's own selection, bypasses tmux) instead. Shift-drag works on every transport.
- **100k scrollback** (`history-limit 100000`) · **status name width 40** (`status-left-length 40`, so `-2`/`-3` suffixes aren't cut off) · status bar at `bottom` (flip to `top` if it overlaps Claude's statusline).
- **`aggressive-resize on`** — a window sizes to the smallest client *actually viewing it*, not every client on the session (less shrink when devices differ).
- **`focus-events on`** — apps inside panes (Claude Code, vim) get focus in/out events.
- **extended keys** (`extended-keys always` + `*:extkeys`) — Alt/Ctrl key combos pass through to editors instead of being mangled.
- **bell pass-through** (`monitor-bell on`, `bell-action any`, `visual-bell off`, `bel` override) — a terminal bell from any window reaches the outer terminal / VS Code so Claude notifications ring; the ringing window is flagged red in the status bar.
- **`update-environment VSCODE_IPC_HOOK_CLI`** — the VS Code IPC socket flows into the session env on attach, so a **new** pane's `code` targets the current window. It can't refresh an already-open shell, and a reconnect leaves the *old* socket file on disk (dead but present) — so the VM-side `code` wrapper (`deploy/66-code-ipc.sh`) is the backstop: on each `code` run it repoints `$VSCODE_IPC_HOOK_CLI` at the newest socket that actually accepts a connection. If `code .` ever errors with `connect ENOENT/ECONNREFUSED .../vscode-ipc-*.sock`, that means no live window is reachable (reconnect VS Code to the VM), not a wrapper bug. Dead `vscode-ipc-*.sock` files in `$XDG_RUNTIME_DIR` (`/run/user/<uid>`) accumulate but are harmless and clear on reboot. To prune, do it **with no VS Code window connected** (then every socket is dead, so you can't remove a live one): `find "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" -maxdepth 1 -name 'vscode-ipc-*.sock' -delete`. A blunt delete while a window is connected would remove the live socket too — the wrapper itself never does that, it only ever *selects* a live socket. This VM-side `code` is distinct from the Mac-side `rcode`, which opens a **new** window over Remote-SSH.
- reload after edits: `Ctrl-b :source-file ~/.tmux.conf`. (10-base.sh only drops the repo copy if `~/.tmux.conf` is absent — it won't overwrite an existing one.)

## Claude Code
- Run `claude` **inside a tmux session** → it survives the laptop going offline.
- Reattach from anywhere: VS Code terminal · `ssh __VM_NAME__` · `mosh __VM_NAME__` then `cs`.
- **Claude reconnected as `<folder>-2` after a long laptop-off?** VS Code *revived* the dead
  terminal, which re-ran the auto-attach and grabbed the base session before the Claude tab did.
  Fixed VM-side by `deploy/67-vscode-terminal-settings.sh` (sets `persistentSessionReviveProcess:
  never` for both Remote-SSH and code-server). Immediate workaround if it still happens: exit and
  `cs <folder>`. Test the fix by fully **closing** the window (not Reload Window) and reopening.
- The code-server **extension** panel is window-bound; the **tmux terminal** is the durable one.
- Runs **fullscreen with the mouse enabled** (`"tui": "fullscreen"`, no `CLAUDE_CODE_DISABLE_MOUSE`). To click Claude's UI cleanly, hand it the mouse: `Ctrl-b m` to turn **tmux** mouse OFF (else the two fight → `aN;NaNM` garbage). For wheel scroll without clicks instead, set `CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1`. **Copy from Claude:** Shift-drag (ghostty native) always works; over SSH a tmux copy also hits the local clipboard (OSC 52).

## Secrets (`op` proxy)
- `op-mode status` — current mode + whether the Mac resolver socket is present
- **mac mode** (default): `op read 'op://…'` or `op run --env-file=.env -- wrangler deploy`
  → resolves on the Mac with **TouchID** (needs a Mac-originated session)
- **token mode** (headless): place a service-account token, `op-mode token`; revert with `op-mode mac`
- full notes: `~/OP-SECRETS.md` on the VM

## Updates
- Security updates apply **daily, automatically** (`dnf-automatic.timer`); the VM **never
  reboots on its own**. When a reboot becomes pending you're alerted via the same bridge as
  Claude: Mac desktop notification if the laptop's connected, else a push (Blink-mosh link).
- Status: `systemctl status dnf-automatic.timer reboot-notify.timer` · last run:
  `journalctl -u dnf-automatic.service -n 30` · check now: `dnf needs-restarting -r` (exit 1 = reboot needed).
- Reboot when ready: `sudo reboot` (or `sudo systemctl reboot`).

## Memory / swap
- The VM has a **swapfile** (`/swapfile`, sized to RAM) so a memory spike pages instead of
  OOM-killing every session — `10-base.sh` provisions it; `swap-notify.timer` warns before it fills.
- Status: `swapon --show` · `free -h` · `systemctl status swap-notify.timer`.
- The alert fires at **≥50%** swap used, via the same bridge as Claude (Mac desktop when connected,
  else push). Tunables in `~/.notify/swap-check.sh`: `SWAP_HIGH_PCT` / `SWAP_REARM_PCT` / `SWAP_REMIND_SECS`.
- Test it (forces a send, then clears state):
  `sudo -u __DEV_USER__ HOME=/home/__DEV_USER__ SWAP_HIGH_PCT=0 NOTIFY_PUSH_MODE=always /home/__DEV_USER__/.notify/swap-check.sh; rm -f /home/__DEV_USER__/.notify/swap-check.state`
- Running low? Fewer simultaneous `claude` sessions is the real lever — swap is a cushion, not a cap.

## After a reboot
- `ssh __VM_NAME__` works on its own (tailscaled + sshd auto-start).
- The `claude` session is re-created empty by the boot service; anything that was *running* stopped — re-run `claude`.
- tmux + linger survive disconnect/logout, **not** reboot.
