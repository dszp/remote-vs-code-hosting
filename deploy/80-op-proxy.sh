#!/usr/bin/env bash
# Install an `op` proxy on the VM with two modes (toggle with `op-mode`):
#
#   mac   (default) — resolve secrets on the Mac via a REVERSE channel: your
#                     Mac->VM SSH connection carries ~/.op-proxy/mac.sock back to a
#                     tiny op resolver on the Mac (TouchID). Nothing listens on the
#                     Mac; nothing is stored on the VM. Works only while you're
#                     connected from the Mac (the socket exists only then).
#                     Supports `op read` and `op run --env-file` (covers wrangler).
#   token           — use the real `op` on the VM with a 1Password Service Account
#                     token in ~/.op-proxy/service-token (no biometric; headless).
#
# Mac side is set up by mac/op-resolver-setup.sh (socat + LaunchAgent + RemoteForward).
# RUN ON: the VM.  ./deploy/run-remote.sh __VM_NAME__ deploy/80-op-proxy.sh DEV_USER=__DEV_USER__
set -euo pipefail

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="/home/$DEV_USER"
DIR="$HOME_DIR/.op-proxy"

echo ">> install socat (mac-mode client) + the real 1Password CLI (token mode)"
dnf install -y socat >/dev/null
if [ ! -x /usr/bin/op ] && [ ! -x /bin/op ]; then
  rpm --import https://downloads.1password.com/linux/keys/1password.asc
  cat > /etc/yum.repos.d/1password.repo <<'REPO'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
REPO
  dnf install -y 1password-cli
fi
REAL_OP="$(command -v op || true)"; [ -z "$REAL_OP" ] || [ "$REAL_OP" = /usr/local/bin/op ] && REAL_OP=/usr/bin/op
ln -sf "$REAL_OP" /usr/local/bin/op.real

echo ">> config dir $DIR"
install -d "$DIR"; [ -f "$DIR/mode" ] || echo mac > "$DIR/mode"
chown -R "$DEV_USER:$DEV_USER" "$DIR"; chmod 700 "$DIR"

echo ">> let sshd unlink stale RemoteForward sockets (needed for the reverse op resolver)"
# For RemoteForward to a unix socket, the SERVER must be allowed to remove a stale
# socket before rebinding — the client-side StreamLocalBindUnlink does NOT cover this.
cat > /etc/ssh/sshd_config.d/20-rvc-streamlocal.conf <<'SSHD'
StreamLocalBindUnlink yes
SSHD
sshd -t && systemctl reload sshd
# clear any stale socket from before this setting existed (safe: a live forward rebinds)
rm -f "$DIR/mac.sock"

echo ">> install /usr/local/bin/op (proxy) and op-mode"
cat > /usr/local/bin/op <<'SHIM'
#!/usr/bin/env bash
# op proxy — see ~/OP-SECRETS.md. mode in ~/.op-proxy/mode: mac (default) | token.
set -euo pipefail
DIR="$HOME/.op-proxy"
MODE="$(cat "$DIR/mode" 2>/dev/null || echo mac)"

if [ "$MODE" = "token" ]; then
  tok="$DIR/service-token"
  [ -s "$tok" ] || { echo "op-proxy: mode=token but $tok is missing/empty. Add it or 'op-mode mac'." >&2; exit 1; }
  export OP_SERVICE_ACCOUNT_TOKEN; OP_SERVICE_ACCOUNT_TOKEN="$(cat "$tok")"
  exec /usr/local/bin/op.real "$@"
fi

# ---- mac mode: resolve via the RemoteForward'd socket (TouchID on the Mac) ----
SOCK="$DIR/mac.sock"
# Default account hint for the Mac resolver: an item outside the resolver's default
# 1Password account only resolves if we tell the Mac which account to read from. Set
# OP_ACCOUNT (or pass `--account` to read/run) to a sign-in address like foo.1password.com.
ACCT="${OP_ACCOUNT:-}"
_resolve() {  # $1 = op:// ref, $2 = account hint (optional) -> prints value or returns 1
  [ -S "$SOCK" ] || { echo "op(mac): resolver socket missing ($SOCK). Connect from your Mac, or 'op-mode token'." >&2; return 1; }
  local out
  if [ -n "${2:-}" ]; then                         # 2-line form: <account>\n<ref>
    out="$(printf '%s\n%s\n' "$2" "$1" | socat -t120 - UNIX-CONNECT:"$SOCK" 2>/dev/null)" || { echo "op(mac): resolver connect failed" >&2; return 1; }
  else                                             # legacy 1-line form: just the ref
    out="$(printf '%s\n' "$1" | socat -t120 - UNIX-CONNECT:"$SOCK" 2>/dev/null)" || { echo "op(mac): resolver connect failed" >&2; return 1; }
  fi
  case "$out" in ERR*|'') echo "op(mac): resolve failed for $1 ($out)" >&2; return 1 ;; esac
  printf '%s' "$out"
}

case "${1:-}" in
  read)
    shift; ref=""; acct="$ACCT"
    while [ $# -gt 0 ]; do
      case "$1" in
        --account=*) acct="${1#*=}"; shift ;;
        --account)   acct="${2:-}"; shift 2 ;;
        op://*)      ref="$1"; shift ;;
        *)           shift ;;
      esac
    done
    [ -n "$ref" ] || { echo "op(mac): no op:// reference in 'op read' args" >&2; exit 1; }
    val="$(_resolve "$ref" "$acct")" || exit 1
    printf '%s\n' "$val"
    ;;
  run)
    shift; envfiles=(); acct="$ACCT"
    while [ $# -gt 0 ]; do
      case "$1" in
        --env-file=*) envfiles+=("${1#*=}"); shift ;;
        --env-file)   envfiles+=("$2"); shift 2 ;;
        --account=*)  acct="${1#*=}"; shift ;;
        --account)    acct="${2:-}"; shift 2 ;;
        --)           shift; break ;;
        --*)          shift ;;
        *)            break ;;
      esac
    done
    declare -a kv=()
    for f in "${envfiles[@]}"; do
      [ -f "$f" ] || { echo "op(mac): env-file not found: $f" >&2; exit 1; }
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        [ "${line#*=}" = "$line" ] && continue
        name="${line%%=*}"; val="${line#*=}"
        case "$val" in op://*) val="$(_resolve "$val" "$acct")" || exit 1 ;; esac
        kv+=("$name=$val")
      done < "$f"
    done
    # also resolve op:// values already present in the environment
    while IFS= read -r ev; do
      n="${ev%%=*}"; v="${ev#*=}"
      case "$v" in op://*) kv+=("$n=$(_resolve "$v" "$acct")") ;; esac
    done < <(env)
    exec env "${kv[@]}" "$@"
    ;;
  ""|--help|-h)
    echo "op proxy (mode=mac). Supported here: 'op read op://...' and 'op run --env-file=F -- CMD'." >&2
    echo "For inject/item/other subcommands, switch to a service account: 'op-mode token'." >&2
    exit 0
    ;;
  *)
    echo "op(mac): '$1' isn't supported via the Mac resolver (only read / run --env-file)." >&2
    echo "Use 'op-mode token' for full op functionality." >&2
    exit 2
    ;;
esac
SHIM
chmod 0755 /usr/local/bin/op

cat > /usr/local/bin/op-mode <<'MODE'
#!/usr/bin/env bash
set -euo pipefail
DIR="$HOME/.op-proxy"; F="$DIR/mode"; TOK="$DIR/service-token"; SOCK="$DIR/mac.sock"
cur="$(cat "$F" 2>/dev/null || echo mac)"
case "${1:-status}" in
  status)
    echo "mode:        $cur"
    if [ -S "$SOCK" ]; then echo "mac socket:  present (Mac-originated session active)"; else echo "mac socket:  absent (not connected from the Mac)"; fi
    if [ -s "$TOK" ]; then echo "token file:  present"; else echo "token file:  absent"; fi
    ;;
  mac)   echo mac   > "$F"; echo "switched to mac (TouchID via your Mac; needs a Mac-originated session)";;
  token)
    [ -s "$TOK" ] || { echo "Add your service token first:  install -m600 /dev/stdin $TOK   (paste, then Ctrl-D)"; exit 1; }
    chmod 600 "$TOK"; echo token > "$F"; echo "switched to token (local service account)";;
  *) echo "usage: op-mode [status|mac|token]" >&2; exit 2;;
esac
MODE
chmod 0755 /usr/local/bin/op-mode

echo ">> write $HOME_DIR/OP-SECRETS.md"
cat > "$HOME_DIR/OP-SECRETS.md" <<'DOC'
# Secrets on this VM (op proxy)

`op` here is a **proxy** (`/usr/local/bin/op`). Check state with `op-mode status`.

## Default: mac mode (TouchID, no secrets on the VM)
Your Mac->VM SSH connection carries a socket (`~/.op-proxy/mac.sock`) back to a small
`op` resolver running on your Mac (a launchd agent). When something here runs
`op read 'op://...'` or `op run --env-file=.env -- wrangler deploy`, the reference is
resolved **on your Mac with TouchID** and the value returns over the encrypted hop —
nothing inbound to the Mac, nothing stored here.

- Works **only while you're connected from the Mac** (the socket exists only then).
  `op-mode status` shows whether the socket is present.
- Supported: `op read` and `op run --env-file`. For `op inject`/`op item`/other
  subcommands, use token mode.
- **Multiple 1Password accounts:** the Mac resolver reads from a default account. To
  resolve an item that lives in a different account, tell it which one — either export
  `OP_ACCOUNT=<sign-in-address>` (e.g. `foo.1password.com`; it's inherited by anything
  that shells out to `op`) or pass `op read --account <addr> op://...`. Without a hint,
  the default account is used (unchanged behavior).
- Each resolve prompts TouchID unless 1Password has a cached session (tune in 1Password's
  security settings). Accesses are logged on the Mac at `~/.op-resolver/access.log`.

## When off-Mac / headless: token mode (no biometric)
1. Create a scoped 1Password **Service Account**; put the token on the VM (mode 600):
   `install -m600 /dev/stdin ~/.op-proxy/service-token`   (paste, then Ctrl-D)
2. `op-mode token`
3. ...use op/wrangler with full functionality...
4. Revert + remove the token when done:
   `op-mode mac && shred -u ~/.op-proxy/service-token`

If mode is `token` but the file is missing, `op` refuses to run (fail-safe).
DOC
chown "$DEV_USER:$DEV_USER" "$HOME_DIR/OP-SECRETS.md"

echo; echo "Installed. State:"; sudo -u "$DEV_USER" /usr/local/bin/op-mode status
