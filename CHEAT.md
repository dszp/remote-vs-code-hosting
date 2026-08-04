# Cheatsheet — remote dev VM (`__VM_NAME__`)

## Connect
- `ssh __VM_NAME__` — lands in a **plain shell**; human logins are never auto-attached.
  Ask for what you want: `mux` / `hs` (this project, herdr) · `cs [folder]` (tmux) · `herdr`.
- `mosh __VM_NAME__` — resilient over roaming / flaky links, then `mux`.
- **VS Code:** Remote-SSH → `__VM_NAME__` (or `__VM_NAME__-cf` when off-tailnet) → open `~/workspace/<project>`.
- **Any browser (incl. iPad):** `https://__CODE_HOSTNAME__` (Access → code-server password).

## Plans vault — read/edit Claude's docs from Obsidian on any device (`pvault`)
Selected folders are bind-mounted into a Realtime vault at `~/vaults/plans`, so a plan
Claude writes on the VM shows up in Obsidian in seconds, and an edit made on the phone
writes **through** to the repo's own file. Bind mounts, not symlinks: the rtmd CLI skips
symlinks outright, so a symlink farm would sync nothing.
- `pvault list` — what's published + mount state · `pvault apply` — reconcile mounts to config
- `pvault add <src> [vault-path]` — publish a folder OR a single file, and mount it now
- `pvault rm <src>` — stop publishing it · `pvault sync` — force a pull+push
- `pvault check` — the live **attachment policy** plus the published files it filters out.
  Anything not `.md`/`.canvas`/`.base` is an *attachment*, and rtmd 0.1.0+ filters them
  per bound folder (stored as `attachmentSync` in `~/vaults/plans/.rtmd`):

  ```bash
  rtmd config attachments                        # show the current policy
  rtmd config attachments off                    # ignore every attachment
  rtmd config attachments on --include "**/*.html,assets/**"
  rtmd config attachments on --all               # sync everything (the old behaviour)
  ```
  **This host publishes `**/*.html`.** Ignored files are never uploaded, downloaded, or
  deleted — which is what lets whole repo folders be bound instead of markdown files one
  at a time. Three traps: ignoring is **silent** (a `.pdf` in a bound folder simply never
  appears, nothing warns you); `rtmd ls` still *lists* ignored files with their
  classified kind — use `rtmd attach ls` to see what is actually on the server; and a
  synced attachment can still be **invisible in Obsidian** — the file explorer hides
  extensions it can't open (`.html` among them) until **Settings → Files and links →
  "Show all file types"** is on. That is a **per-device** setting: Realtime skips
  dot-directories, so `.obsidian/app.json` never syncs and each device needs its own
  toggle. Symptom is a folder that appears with nothing in it.
  ⚠ Under `--all`, one extension the server's allowlist rejects fails the **entire push**
  and nothing syncs, plans included; symptom is a silent stall with the error in
  `journalctl --user -u pvault-pull.service`. This is CLI-side and unrelated to the vault's
  own "Sync attachments"/"Attachment exclusions" settings in Obsidian, which are plugin-side.
- A **vault-path may contain spaces** (`REPORTS/Monthly Invoice Review`); the source may not.
  Parsing splits on the first whitespace run only.
- `pvault link <path>` — clickable Obsidian permalink (`https://.../n/<guid>`) for a repo
  path, a `~/workspace`-relative path, or a vault path. `pvault where <vault-path>` goes the
  other way, to the real file on disk. Needed because a vault-path override collapses levels,
  so the mapping can't be derived without the config.
- Every plan/spec carries tracing frontmatter, so a note read on the phone says where it
  lives on the VM and which repo it belongs to (`workspace` is the sort/group key):

  ```yaml
  ---
  source_path: ~/workspace/<repo>/docs/superpowers/specs/<file>.md
  workspace: NetSapiens          # _rvc_ws_name — the project root / herdr session name
  repo: web-console            # bare repo name (from origin, else the directory)
  repo_url: https://github.com/__GIT_ORG__/web-console   # omit when there is no remote
  permalink: https://realtime.__BASE_DOMAIN__/n/<guid>
  ---
  ```
  79 files across the published projects are backfilled; write new ones the same way.
  `permalink` survives content edits — the guid is keyed to the note's path. Folders bound
  wholesale (reports, not plans) are not stamped.
- Config: `~/.config/remote-vs-code/plans-vault.conf` (`<source> [<vault-path>]`; source is
  relative to `~/workspace`). Give a vault-path to flatten a deep source.
- Push is **event-driven** (inotify on the vault, ~5s); pull is a **60s timer**
  (`pvault-push.service`, `pvault-pull.timer`). rtmd has no watch mode, hence the polling.
- ⚠ A push is **refused** while any configured mount is inactive — an unmounted dir looks
  empty, and rtmd would read that as "delete every file". `pvault apply` fixes it.
- Not published: git worktrees (same files on another branch) and third-party checkouts.
  `pvault add` warns about both but lets you override.
- Needs `rtmd` on PATH: **`npm i -g @realtime-md/cli`** (published 2026-08-02; upgrade with
  `@latest`). It stays wrapped as `~/.local/bin/rtmd` because npm's own `rtmd` symlink and
  its `#!/usr/bin/env node` shebang are both pinned to one nvm node version that a systemd
  user unit's PATH can't see — the wrapper picks the newest node that actually has the
  package. `rtmd whoami` prints the bound **vault id**.

## Multiplexer: tmux or herdr (`mux` on the VM)
Two multiplexers coexist as peers — never nest them. tmux is the default and the one VS Code
integrated terminals auto-attach (so the Claude extension's terminal stays persistent); herdr
is the agent-aware one, project-oriented, useful when several coding agents run at once.
Moshi lists **both** backends' sessions in its picker.
- `mux` — **this project's herdr session** (same as bare `hs`), whatever the policy says
- `mux herdr [<name>|ws|default]` — this project (default) · a named session · herdr's shared
  `default`. `mux tmux` — tmux, via `cs`
- `mux use <tmux|herdr|off>` — the policy: what VS Code **auto-attaches** (`off` = plain
  shells). It does **not** change what `mux` does — a command you typed on purpose shouldn't
  depend on a setting you last touched weeks ago.
- `mux status` — policy + session counts · policy file: `~/.config/remote-vs-code/mux.env`
- **Prefix collision:** both use `Ctrl-b`. Harmless as peers; rebind before ever nesting.
- herdr detach `Ctrl-b q` · panes survive in its server · `herdr integration status` shows the
  Claude hook (a no-op outside herdr panes — it only reports session identity)
- **Sessions:** named after the `.code-workspace` (else the project dir), and a subdir joins
  its project's one session. `mux` / `hs` / VS Code auto-attach all derive the same name, so
  they land together **on purpose** — every client on one session renders the same view
  (herdr focus is session-level). Want an independent view? `mux herdr default` or bare
  `herdr`. `herdr session list`
- **Persist a named session across reboots:** `systemctl --user enable herdr-session@<name>.service`
  (template from `deploy/60-session-boot.sh`; `default` has its own unit). Use `enable` without
  `--now` when it is already running on demand — `start` would collide on its socket.
- **Renaming** (all four levels, after creation): `herdr workspace rename <ws> <label…>` ·
  `herdr agent rename <pane> <name>|--clear` · `herdr tab rename <tab> <name>` ·
  `herdr pane rename <pane> <name>`. Add `--session <name>` for a non-default session.
- Not in herdr: the `moshi <dir>` project launcher is tmux-only.

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

## Sessions (`hs` on the VM — herdr)

Same shape as `cs`, for herdr. Naming is shared with VS Code auto-attach, so `hs`
from any subdirectory joins that project's one session (`~/workspace/Remote-VS-Code/remote-vs-code`
→ `Remote-VS-Code`, not a near-duplicate).

- `hs` — attach/create the current project's session; `hs .` is the same
- `hs <dir>` — name a session after a folder **and** start it there; Tab-completes like `cd`
- `hs <name>` — attach/create a plain **named** session
- `hs -n [base]` — a **new independent** session (`folder-2`, `folder-3`, …)
- `hs s` — **s**witch to a session (also `switch`/`attach`); revives a stopped one
- `hs x` — **stop** it: processes die, the saved layout stays on disk (also `stop`)
- `hs rm` — **delete** a stopped session (refuses while it is running; also `delete`)
- `hs k` — **k**ill = stop **and** delete in one go; prompts while running, `-y` skips
- `hs ls` — list name / status / directory
- bare `s`/`x`/`k`/`rm` = **fzf picker**; `hs rm`'s picker lists stopped sessions only

`herdr session list` has no directory column — `hs ls` adds one by reading each
session's `session.json`, which survives a stop, so stopped sessions still show
where they live.

**The `default` session can be stopped but never deleted** — herdr answers
`session delete` on it with `session_delete_failed`. `hs rm`/`hs k` refuse it up
front (so `hs k` can't stop it and then fail on the delete), and the pickers don't
offer it. `hs x default` is the operation that exists; it revives on the next
bare `herdr`.

There is deliberately no `hs d`. `cs d` exists because tmux mirrors one grid across
clients, so a stale client locks everyone's size and scroll; herdr renders per-client
(two clients attach at different sizes without mirroring), so a second client costs
nothing — and its socket API has no kick-client request.

| you want | tmux | herdr |
|---|---|---|
| stop it, keep the layout | — | `hs x` |
| throw it away entirely | `cs k` | `hs k` |
| boot other clients off | `cs d` | not needed |

## From the Mac (helpers in `~/.zshrc` — source: `config/shell-helpers.sh`)
- `dv` — mosh in via `__VM_NAME__` (= `mosh __VM_NAME__`); 1Password agent → TouchID prompt
- `da` — same VM via the silent `__VM_SSH_ALIAS__` key, **no prompt** (= `mosh __VM_SSH_ALIAS__`)
  - under mosh the ssh channel closes after bootstrap, so *neither* forwards the agent or the op/notify sockets (`__VM_NAME__-fwd` does that) — the only difference is the prompt
  - needs UDP 60000-61000: fine over Tailscale, not over Cloudflare Access → there use `ssh __VM_NAME__-cf`
- `devx` — **new** independent session (= `ssh -t __VM_NAME__ cs -n`; `DEVX_HOST=__VM_SSH_ALIAS__` to skip the prompt)
- `devx <name>` — reattach/create a named session
- `devsh` — quick **non-tmux** scratch shell on the VM
- `ssh __VM_NAME__ cs ls` — list sessions without attaching

## Multiple terminals — which tool
- **More shells, one tab, same session:** tmux windows — `Ctrl-b c` new · `Ctrl-b n`/`p` or `Ctrl-b 0-9` switch · `Ctrl-b w` list · `Ctrl-b ,` rename
- **Independent tab/session:** `devx` (Mac) or `cs -n` (VM) — won't mirror
- **Non-tmux scratch:** VS Code "+" → **"shell (no tmux)"** · Mac `devsh` · inline `NO_AUTO_TMUX=1 bash` · any plain `ssh __VM_NAME__`
- **One tab on a specific backend:** VS Code "+" → **"herdr"** or **"tmux: folder session"**
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
- **Pinged too often by "Claude is waiting for your input"?** That's the *idle* ping:
  `messageIdleNotifThresholdMs` in `~/.claude.json` (ms; default `60000`, now `600000` = 10 min).
  It's both the threshold **and** the repeat interval, so the default re-nags every minute while
  you sit at the prompt. **Not** a `settings.json` key — it's silently ignored there. Permission
  and question prompts ignore it and stay immediate. Edit atomically; no restart needed
  (live-reloaded). Full notes + snippet: README **B**.
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
  else push). Tunables in `/usr/local/bin/swap-check.sh`: `SWAP_HIGH_PCT` / `SWAP_REARM_PCT` / `SWAP_REMIND_SECS`.
- Test it (forces a send, then clears state):
  `sudo -u __DEV_USER__ HOME=/home/__DEV_USER__ SWAP_HIGH_PCT=0 NOTIFY_PUSH_MODE=always /usr/local/bin/swap-check.sh; rm -f /home/__DEV_USER__/.notify/swap-check.state`
- Running low? Fewer simultaneous `claude` sessions is the real lever — swap is a cushion, not a cap.

### Memory caps (the actual cap)
`96-memory-caps.sh` bounds a runaway with cgroup v2 limits, because a warning can't outrun a
leak: on 2026-08-03 two `claude.exe` processes hit ~10.5 GiB **each**, took swap 91% → 0 in
about a minute, and the box OOM-killed. The alert fired 63s ahead of the kill — correct, useless.
- Two nested slices, sized from RAM (`rvc_mem_cap_gib` in `deploy/lib.sh`). On a 15.9 GiB box:
  - `app-herdr\x2dsession.slice` — herdr sessions: High **9G** / Max **12G** / Swap **4G**.
  - `user-1000.slice` — *everything* the user runs, incl. Claude in a plain VS Code terminal
    (a login `session-N.scope`, which the herdr cap never reaches): Max **13G** / Swap **6G**.
    No `MemoryHigh` here on purpose — throttling an interactive slice stalls it all at once.
- **`MemorySwapMax` is the load-bearing one.** `memory.max` bounds anon+file only; the kernel
  relieves that by paging anon to swap — the resource that actually ran out.
- Did a cap bite? `cat /sys/fs/cgroup/user.slice/user-1000.slice/memory.events` — `high`/`max`
  are the counters that matter. **`oom_kill` is cumulative and never resets**, so a stale `1`
  is not a new kill; check `journalctl -k | grep oom-kill` for a real one.
- Effective limits: `systemctl show user-1000.slice -p MemoryMax -p MemorySwapMax`. But trust
  the cgroup files — `daemon-reload` updates systemd's view **without** pushing values to the
  kernel on an already-running slice, so `set-property` (what the script does) is what applies.
- Re-run after a RAM change: `sudo DEV_USER=__DEV_USER__ bash deploy/96-memory-caps.sh`. It refuses to
  apply a cap below current usage (that would OOM-kill on the spot) and says so.

## After a reboot
- `ssh __VM_NAME__` works on its own (tailscaled + sshd auto-start).
- The `claude` session is re-created empty by the boot service; anything that was *running* stopped — re-run `claude`.
- tmux + linger survive disconnect/logout, **not** reboot.
