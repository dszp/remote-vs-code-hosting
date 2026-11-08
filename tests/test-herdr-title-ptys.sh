#!/usr/bin/env bash
# herdr-title.py painting EVERY client of a session directly, rather than relying on
# herdr's single foreground client. Uses real ptys and a fake /proc; touches no session.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

BIN="../deploy/build/herdr-title.py"
[ -r "$BIN" ] || { printf 'missing %s — build it first (see tests/README.md)\n' "$BIN" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$PWD/$BIN" "$TMP" <<'PY' > "$TMP/results" 2>"$TMP/err"
import importlib.util, os, pty, sys

BIN, TMP = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("ht", BIN)
ht = importlib.util.module_from_spec(spec); spec.loader.exec_module(ht)

out = []
def check(name, cond, detail=""):
    out.append(f"PASS:{name}" if cond else f"FAIL:{name}:{detail}")

# ---- a fake /proc: herdr clients, a server, another session, and a stray CLI call ----
PROC = os.path.join(TMP, "proc")
def mkproc(pid, argv, fd0):
    d = os.path.join(PROC, str(pid)); os.makedirs(os.path.join(d, "fd"), exist_ok=True)
    with open(os.path.join(d, "cmdline"), "wb") as fh:
        fh.write(b"\x00".join(a.encode() for a in argv) + b"\x00")
    os.symlink(fd0, os.path.join(d, "fd", "0"))       # dangling is fine; readlink works

mkproc(101, ["herdr", "--session", "Alpha"], "/dev/pts/11")
mkproc(102, ["/home/__DEV_USER__/.local/bin/herdr", "--session", "Alpha"], "/dev/pts/12")
mkproc(103, ["herdr", "--session", "Alpha", "server"], "/dev/pts/13")   # server, not a client
mkproc(104, ["herdr", "--session", "Beta"], "/dev/pts/14")              # other session
mkproc(105, ["herdr", "--session", "Alpha", "api", "snapshot"], "/dev/pts/15")  # CLI call
mkproc(106, ["herdr"], "/dev/pts/16")                                   # default session
mkproc(107, ["python3", "/usr/local/lib/remote-vs-code/herdr-title.py"], "/dev/pts/17")
mkproc(108, ["herdr", "--session", "Alpha"], "socket:[12345]")           # not a pty

alpha = ht.client_ptys("Alpha", procfs=PROC)
check("finds both Alpha clients", sorted(alpha) == ["/dev/pts/11", "/dev/pts/12"], f"got {alpha}")
check("excludes the session server", "/dev/pts/13" not in alpha, f"got {alpha}")
check("excludes another session", "/dev/pts/14" not in alpha, f"got {alpha}")
check("excludes a one-shot herdr CLI call", "/dev/pts/15" not in alpha, f"got {alpha}")
check("excludes the title daemon itself", "/dev/pts/17" not in alpha, f"got {alpha}")
check("excludes a client whose fd0 is not a pty", len(alpha) == 2, f"got {alpha}")
check("default session matches a bare `herdr`",
      ht.client_ptys("default", procfs=PROC) == ["/dev/pts/16"],
      f"got {ht.client_ptys('default', procfs=PROC)}")
check("unknown session yields nothing", ht.client_ptys("Nope", procfs=PROC) == [], "")

# ---- transport: walk up from the client to mosh-server / sshd ---------------------
def mkstat(pid, comm, ppid):
    d = os.path.join(PROC, str(pid)); os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "stat"), "w") as fh:
        fh.write(f"{pid} ({comm}) S {ppid} {pid} {pid} 0 -1 4194560\n")

mkstat(101, "herdr", 201); mkstat(201, "bash", 202); mkstat(202, "mosh-server", 1)
mkstat(102, "herdr", 301); mkstat(301, "bash", 302); mkstat(302, "sshd-session", 303)
mkstat(303, "sshd", 1)
mkstat(104, "herdr", 401); mkstat(401, "bash", 402); mkstat(402, "sshd", 1)       # older OpenSSH
mkstat(106, "herdr", 501); mkstat(501, "weird) (name", 1)                         # parens in comm
mkstat(601, "loop", 602); mkstat(602, "loop", 601)                                # ppid cycle
check("a mosh client is mosh", ht.client_transport("101", PROC) == "mosh",
      ht.client_transport("101", PROC))
check("an sshd-session client is ssh", ht.client_transport("102", PROC) == "ssh",
      ht.client_transport("102", PROC))
check("a pre-9.8 sshd client is ssh", ht.client_transport("104", PROC) == "ssh",
      ht.client_transport("104", PROC))
check("no known ancestor is local", ht.client_transport("106", PROC) == "local",
      ht.client_transport("106", PROC))
check("a ppid cycle terminates", ht.client_transport("601", PROC) == "local", "")
check("a vanished pid is local", ht.client_transport("999", PROC) == "local", "")
check("client_procs pairs each pty with its pid",
      sorted(ht.client_procs("Alpha", procfs=PROC)) == [("/dev/pts/11", "101"), ("/dev/pts/12", "102")],
      f"got {ht.client_procs('Alpha', procfs=PROC)}")

cfg = ht.load_config(None)
view = {"session": "MISC", "workspace": "chat", "tab": "chat", "status": "idle"}
check("renders the mosh glyph", ht.render(dict(view, transport="mosh"), cfg) == "🌐○ MISC/chat · chat",
      ht.render(dict(view, transport="mosh"), cfg))
check("renders the ssh glyph", ht.render(dict(view, transport="ssh"), cfg) == "🔐○ MISC/chat · chat",
      ht.render(dict(view, transport="ssh"), cfg))
check("no transport renders no glyph", ht.render(view, cfg) == "○ MISC/chat · chat",
      ht.render(view, cfg))

# ---- painting a REAL pty ----------------------------------------------------------
master, slave = pty.openpty()
slave_path = os.ttyname(slave)
ht.paint_ptys([slave_path], "hello ⚡ world")
os.set_blocking(master, False)
got = os.read(master, 4096).decode()
check("writes an OSC 0 title sequence", got == "\033]0;hello ⚡ world\007", repr(got))

# One atomic write: a sequence split across writes can interleave with herdr's output.
ht.paint_ptys([slave_path], "second")
got2 = os.read(master, 4096).decode()
check("re-paints on demand", got2 == "\033]0;second\007", repr(got2))

# ---- a title can never break out of the escape sequence ----------------------------
ht.paint_ptys([slave_path], "ev\033il\007and\nnewline")
got3 = os.read(master, 4096).decode()
check("strips ESC/BEL/newline from the title",
      got3 == "\033]0;evilandnewline\007", repr(got3))
check("exactly one BEL terminator", got3.count("\007") == 1, repr(got3))
check("exactly one ESC introducer", got3.count("\033") == 1, repr(got3))
os.close(master); os.close(slave)

# ---- a vanished or unwritable pty must not take the daemon down --------------------
try:
    ht.paint_ptys(["/dev/pts/999999", "/nonexistent/pty"], "x")
    check("a dead pty is survivable", True)
except Exception as e:
    check("a dead pty is survivable", False, f"raised {type(e).__name__}: {e}")

print("\n".join(out))
PY

while IFS= read -r line; do
  case "$line" in
    PASS:*) ok "${line#PASS:}" ;;
    FAIL:*) rest="${line#FAIL:}"; fail "${rest%%:*}" "${rest#*:}" ;;
  esac
done < "$TMP/results"
[ -s "$TMP/results" ] || { printf 'harness failed:\n%s\n' "$(cat "$TMP/err")" >&2; }

printf '\n%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
