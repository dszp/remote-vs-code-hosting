# Tests

Plain-bash tests for the shell helpers the deploy scripts install. No framework —
`tests/lib.sh` holds the assertions, `tests/run-all.sh` runs every `test-*.sh` and
exits non-zero if any file fails.

## Build the artifacts first

The tests exercise the **exact bytes** the deploy scripts write, rather than a copy
that could drift. So the artifacts have to be extracted before the tests can run.
Each deploy script takes an env var telling it to drop a second copy under
`deploy/build/` (gitignored):

```bash
cd remote-vs-code
sudo WS_LIB_COPY="$PWD/deploy/build/ws-name.sh" \
     HS_COMPLETE_COPY="$PWD/deploy/build/complete.sh" \
     MUX_COPY="$PWD/deploy/build/mux.sh" \
     bash deploy/65-auto-attach.sh DEV_USER="$(id -un)"
sudo HS_BIN="$PWD/deploy/build/hs" bash deploy/71-hs-shortcut.sh
sudo PVAULT_BIN="$PWD/deploy/build/pvault" bash deploy/72-plans-vault.sh
sudo chown "$(id -un)" deploy/build/*
# 69 needs no sudo: every path it writes is redirected below, so nothing lands in
# /usr/local, /etc, or your ~/.config.
LIB_DIR=/tmp/rvc-build HOME_DIR=/tmp/rvc-build UNIT=/tmp/rvc-build/unit.service \
  HERDR_BIN=/tmp/rvc-build/none \
  HERDR_TITLE_COPY="$PWD/deploy/build/herdr-title.py" \
  bash deploy/69-herdr-title.sh
# 95 needs sudo (it installs a system unit) and always writes the dev user's
# /usr/local/bin/swap-check.sh; SWAP_CHECK_COPY additionally drops a copy for the tests.
sudo SWAP_CHECK_COPY="$PWD/deploy/build/swap-check.sh" bash deploy/95-swap-monitor.sh DEV_USER="$(id -un)"
sudo chown "$(id -un)" deploy/build/*
bash tests/run-all.sh
```

`sudo` is needed because both scripts also install to `/usr/local/`; the build
copies are a side effect. Re-run the same commands after editing either script.

## What is covered

| file | covers |
|---|---|
| `test-ws-name.sh` | `_rvc_ws_name` — the shared session-naming rule (deploy/65) |
| `test-pvault.sh` | `pvault` — config parsing, fstab reconciliation, file-vs-dir mountpoints, add/rm guards (deploy/72) |
| `test-mux.sh` | `mux` / `_mux_herdr` — what each form dispatches, `default` vs `--session default`, policy independence (deploy/65) |
| `test-hs-list.sh` | `hs ls`, session enumeration, `session.json` cwd enrichment |
| `test-hs-launch.sh` | `hs` create/attach paths, `-n` suffixing, name safety, nesting guard |
| `test-hs-verbs.sh` | `hs s`/`x`/`k`/`rm` semantics, guards, the destructive prompt |
| `test-hs-complete.sh` | `_hs_complete` bash completion |
| `test-swap-policy.sh` | `rvc_swap_policy_gib` / `rvc_swap_total_gib` — the swap sizing rule shared by deploy/10 and deploy/95 |
| `test-inotify-sysctl.sh` | `rvc_ensure_inotify_limits` — the persistent inotify raise (deploy/lib.sh, called by deploy/10) |
| `test-vscode-settings.sh` | the JSONC settings merge, `files.watcherExclude` in particular (deploy/67) |
| `test-herdr-title.sh` | `herdr-title.py` — tab-title rendering and the snapshot/event view builder (deploy/69) |
| `test-herdr-title-ptys.sh` | painting every client of a session directly (real ptys + a fake `/proc`) |
| `test-herdr-title-daemon.sh` | the same daemon against **fake herdr sockets**: snapshot → subscribe → event → `client.window_title.set`, with two concurrent sessions |

Nothing touches the real environment: each test builds a throwaway `$HOME`, a stub
`herdr` on `PATH`, and a fixture `~/.config/herdr` tree. `hs` itself exposes
`HS_DRY_RUN` (print the herdr command instead of running it), `HS_HERDR_DIR`, and
`HS_WS_LIB` for exactly this purpose. The deploy-script tests use the same idea via the
scripts' own `SYSCTL_DIR` / `HOME_DIR` overrides, and a stub `sysctl` on `PATH`.

`tests/lib.sh` also unsets the `HERDR_*` / `RVC_MUX_ACTIVE` vars it inherits, so the
suite passes when run from inside a herdr pane — otherwise `hs`'s nesting guard fires
and every launch test fails with "already inside herdr". Tests that *want* the guard set
those vars per-invocation, which is unaffected.

The two deploy-script tests need no build step — `test-inotify-sysctl.sh` sources
`deploy/lib.sh` directly and `test-vscode-settings.sh` runs `deploy/67-*.sh` itself.
