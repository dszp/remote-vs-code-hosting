#!/usr/bin/env bash
# herdr-title.py running as the DAEMON, against fake herdr sockets. Covers the layer the
# renderer tests can't reach: snapshot -> subscribe -> event -> client.window_title.set,
# with TWO concurrent sessions (each session gets its own watcher thread, and they must
# not share state). No real herdr, no real terminal.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

BIN="../deploy/build/herdr-title.py"
[ -r "$BIN" ] || { printf 'missing %s — build it first (see tests/README.md)\n' "$BIN" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The harness prints PASS:<name> / FAIL:<name>:<detail>; bash turns those into assertions
# so this file reports like every other test in the suite.
python3 - "$PWD/$BIN" "$TMP" <<'PY' > "$TMP/results" 2>"$TMP/err"
import json, os, socket, subprocess, sys, threading, time

BIN, TMP = sys.argv[1], sys.argv[2]
HERDR = os.path.join(TMP, "herdr")
os.makedirs(os.path.join(HERDR, "sessions", "Alpha"))
os.makedirs(os.path.join(HERDR, "sessions", "Beta"))
os.makedirs(os.path.join(HERDR, "sessions", "Gamma"))
os.makedirs(os.path.join(HERDR, "sessions", "Delta"))

CFG = os.path.join(TMP, "title.toml")
with open(CFG, "w") as fh:
    fh.write('format = "{icon} {session_path} · {title|host}"\n')


def snapshot(ws_label, title, status="working"):
    return {"snapshot": {
        "focused_workspace_id": "w1", "focused_tab_id": "w1:t1", "focused_pane_id": "w1:p1",
        "workspaces": [{"workspace_id": "w1", "label": ws_label, "focused": True}],
        "tabs": [{"tab_id": "w1:t1", "workspace_id": "w1", "label": "1", "focused": True}],
        "panes": [{"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "focused": True,
                   "agent": "claude", "agent_status": status,
                   "terminal_title_stripped": title, "cwd": "/tmp"}]}}


def pane_event(title, status):
    return {"event": "pane_updated", "data": {"type": "pane_updated", "pane": {
        "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "focused": True,
        "agent": "claude", "agent_status": status,
        "terminal_title_stripped": title, "cwd": "/tmp"}}}


class FakeSession(threading.Thread):
    """One fake herdr server, matching the REAL socket contract.

    herdr answers ONE request per connection and then closes it — verified against
    herdr 0.7.5, where a second request on the same socket gets EPIPE. Only
    events.subscribe keeps its connection open, to stream. A fake that accepted many
    requests per connection is exactly what let a broken daemon pass this suite.
    """

    def __init__(self, name, ws_label, first_title, replay=None, push=None, refuse=0):
        super().__init__(daemon=True)
        self.name_ = name
        # Answer this many title writes with no_foreground_client, as herdr does for a
        # session nobody is attached to, before behaving as if a client showed up.
        self.refuse = refuse
        self.path = os.path.join(HERDR, "sessions", name, "herdr.sock")
        self.ws_label, self.first_title = ws_label, first_title
        self.replay, self.push = replay, push
        self.titles = []
        self.stamps = []          # send time of each title, for the rate assertion
        self.lock = threading.Lock()
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(self.path)
        self.srv.listen(8)

    def run(self):
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        buf = b""

        def readline():
            nonlocal buf
            while b"\n" not in buf:
                chunk = conn.recv(65536)
                if not chunk:
                    return None
                buf += chunk
            line, _, buf = buf.partition(b"\n")
            return json.loads(line)

        def send(obj):
            conn.sendall((json.dumps(obj) + "\n").encode())

        try:
            msg = readline()
            if msg is None:
                return
            method, mid = msg.get("method"), msg.get("id")
            if method == "session.snapshot":
                send({"id": mid, "result": snapshot(self.ws_label, self.first_title)})
            elif method == "client.window_title.set":
                with self.lock:
                    refusing = self.refuse > 0
                    if refusing:
                        self.refuse -= 1
                    else:
                        self.titles.append(msg["params"]["title"])
                        self.stamps.append(time.time())
                if refusing:
                    send({"id": mid, "result": {"type": "client_window_title",
                                                "changed": False,
                                                "reason": "no_foreground_client"}})
                else:
                    send({"id": mid, "result": {"type": "client_window_title",
                                                "changed": True, "reason": "set"}})
            elif method == "events.subscribe":
                send({"id": mid, "result": {"type": "subscription_started"}})
                # herdr replays current state right after the response.
                for ev in (self.replay or []):
                    send(ev)
                for ev in (self.push or []):
                    time.sleep(0.05)
                    send(ev)
                while True:            # stream stays open
                    time.sleep(0.2)
                return                 # (unreachable; closed when the client goes away)
            else:
                send({"id": mid, "error": {"code": "unknown_method"}})
        except OSError:
            pass
        finally:
            try:
                conn.close()           # one request per connection, like herdr
            except OSError:
                pass


# Both sockets exist before the daemon starts, so its first scan finds them and the test
# does not have to wait out a rescan interval.
alpha = FakeSession("Alpha", "Alpha", "first alpha title",
                    push=[pane_event("alpha moved on", "blocked")])
beta = FakeSession("Beta", "beta-space", "first beta title",
                   replay=[pane_event("beta replayed", "working")])
# Nothing attached when the daemon starts, then a client shows up. Nothing else about
# the session changes, so only a retry can get a title onto that tab.
gamma = FakeSession("Gamma", "Gamma", "gamma title", refuse=2)
# Quiet session, no events ever. Reopening a Ghostty tab makes a NEW client for an
# unchanged session: no event fires and the rendered title is identical, so only an
# unconditional periodic re-assert can paint the new client's tab.
delta = FakeSession("Delta", "Delta", "delta title")
alpha.start()
beta.start()
gamma.start()
delta.start()

env = dict(os.environ, HERDR_CONFIG_DIR=HERDR)
proc = subprocess.Popen([sys.executable, BIN, "--config", CFG],
                        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
deadline = time.time() + 25
while time.time() < deadline and not (alpha.titles and beta.titles and gamma.titles):
    time.sleep(0.1)
time.sleep(1.0)          # let any debounced follow-up land

# Simulate the reopened tab: forget everything Delta was sent, change nothing else,
# and see whether the daemon paints it again unprompted.
with delta.lock:
    delta_before = list(delta.titles)
    delta.titles.clear()
reasserted = False
deadline2 = time.time() + 12
while time.time() < deadline2:
    with delta.lock:
        if delta.titles:
            reasserted = True
            break
    time.sleep(0.2)

proc.terminate()
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
stderr = proc.stderr.read().decode()

out = []


def check(name, cond, detail=""):
    out.append(f"PASS:{name}" if cond else f"FAIL:{name}:{detail}")


check("alpha receives a title", bool(alpha.titles), "no client.window_title.set arrived")
check("alpha title comes from its own snapshot",
      bool(alpha.titles) and alpha.titles[0] == "⚡ Alpha · first alpha title",
      f"got {alpha.titles[:1]}")
check("alpha follows a pushed pane_updated",
      "❓ Alpha · alpha moved on" in alpha.titles, f"got {alpha.titles}")

# Beta is the one that catches cross-thread state sharing: a second concurrent session
# must render ITS OWN session/space, never Alpha's.
check("beta receives a title", bool(beta.titles), "no client.window_title.set arrived")
check("beta renders its own session, not alpha's",
      all(t.startswith("⚡ Beta/beta-space") or t.startswith("❓ Beta/beta-space")
          for t in beta.titles) and bool(beta.titles),
      f"got {beta.titles}")
check("beta applies the state herdr replays after subscribing",
      any("beta replayed" in t for t in beta.titles), f"got {beta.titles}")

# The daemon re-asserts on purpose (see REASSERT_S), so repeats are expected — but it
# must not write on every debounce tick. Any two *identical* consecutive writes should be
# a re-assert interval apart, not 0.2s apart.
gaps = [round(b - a, 2) for (a, b, t1, t2)
        in zip(alpha.stamps, alpha.stamps[1:], alpha.titles, alpha.titles[1:]) if t1 == t2]
check("unchanged titles are re-sent on the re-assert interval, not every tick",
      all(g >= 1.0 for g in gaps), f"gaps between duplicate writes: {gaps}")
check("a session with no attached client is retried until the title lands",
      bool(gamma.titles), "no title ever landed for Gamma")
check("the retried title is correct",
      bool(gamma.titles) and gamma.titles[-1] == "⚡ Gamma · gamma title",
      f"got {gamma.titles}")
check("quiet session gets an initial title", bool(delta_before), f"got {delta_before}")
check("title is re-asserted for a client that attached later (reopened tab)",
      reasserted, "no title was re-sent within 12s despite no events and no change")
check("daemon logged no errors", "Traceback" not in stderr and "Exception" not in stderr,
      stderr.strip()[:300])

print("\n".join(out))
PY

rc=$?
if [ $rc -ne 0 ] && [ ! -s "$TMP/results" ]; then
  printf 'harness failed to run:\n%s\n' "$(cat "$TMP/err")" >&2
fi
while IFS= read -r line; do
  case "$line" in
    PASS:*) ok "${line#PASS:}" ;;
    FAIL:*) rest="${line#FAIL:}"; fail "${rest%%:*}" "${rest#*:}" ;;
  esac
done < "$TMP/results"

printf '\n%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
