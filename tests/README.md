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
     bash deploy/65-auto-attach.sh DEV_USER="$(id -un)"
sudo HS_BIN="$PWD/deploy/build/hs" bash deploy/71-hs-shortcut.sh
sudo chown "$(id -un)" deploy/build/*
bash tests/run-all.sh
```

`sudo` is needed because both scripts also install to `/usr/local/`; the build
copies are a side effect. Re-run the same commands after editing either script.

## What is covered

| file | covers |
|---|---|
| `test-ws-name.sh` | `_rvc_ws_name` — the shared session-naming rule (deploy/65) |
| `test-hs-list.sh` | `hs ls`, session enumeration, `session.json` cwd enrichment |
| `test-hs-launch.sh` | `hs` create/attach paths, `-n` suffixing, name safety, nesting guard |
| `test-hs-verbs.sh` | `hs s`/`x`/`k`/`rm` semantics, guards, the destructive prompt |
| `test-hs-complete.sh` | `_hs_complete` bash completion |

Nothing touches the real environment: each test builds a throwaway `$HOME`, a stub
`herdr` on `PATH`, and a fixture `~/.config/herdr` tree. `hs` itself exposes
`HS_DRY_RUN` (print the herdr command instead of running it), `HS_HERDR_DIR`, and
`HS_WS_LIB` for exactly this purpose.
