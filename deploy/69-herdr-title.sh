#!/usr/bin/env bash
# Put live herdr session state in the OUTER terminal's tab title, so a Ghostty tab
# attached over ssh/mosh reads e.g. "⚡ Remote-VS-Code · Fix JWT refresh loop" instead of
# the same "__DEV_USER__@host:~/dir" every other tab shows.
#
# WHY A DAEMON AND NOT A herdr PLUGIN: herdr has a plugin system (herdr-plugin.toml,
# [startup] + [[events]] hooks) that would own the lifecycle idiomatically — but the
# manifest format is undocumented, the plugin API is young, and herdr AUTO-UPDATES on a
# channel. A feature built on that can break silently on a background upgrade, and stale
# tab titles are the kind of failure you don't notice for days. This uses only the
# versioned socket API (protocol 17): client.window_title.set + events.subscribe.
#
# HOW IT REACHES THE TERMINAL: two ways, because one is not enough.
#   1. `client.window_title.set` — herdr writes the OSC to the client it considers
#      FOREGROUND. Supported, but reaches exactly one client.
#   2. Direct OSC writes to every client pty (write_all_clients, on by default). Sessions
#      here routinely have several clients — a Ghostty tab plus Moshi clients that stay
#      attached on purpose to deliver push alerts — and the tabs that most need a title
#      are the ones you are NOT looking at. Measured on __VM_NAME__: a session actively
#      worked in for 40 minutes never got a title from (1); (2) landed immediately.
# mosh prepends "[mosh] " to the title it forwards — that is mosh's doing, not ours, and
# it is why the notification click handler cannot anchor its tab match at the start of
# the string. See mac/notify-bridge-setup.sh.
#
# ONE DAEMON FOR ALL SESSIONS: it rescans ~/.config/herdr for session sockets every 5s,
# so sessions started later are picked up with no per-session unit and nothing to trigger.
# Deliberately NOT inotify — this VM has a history of exhausting inotify watches (the
# VS Code ENOSPC incident, see rvc_ensure_inotify_limits in lib.sh), and a 5s stat of one
# directory costs nothing next to that.
#
# CONFIG: ~/.config/rvc/herdr-title.toml, written only if absent and never overwritten —
# same non-destructive contract as deploy/67 and 68, so hand edits always win.
#
# RUN ON: the VM.  ./deploy/run-remote.sh __VM_NAME__ deploy/69-herdr-title.sh DEV_USER=__DEV_USER__
# Set HERDR_TITLE_COPY=<path> to also drop the daemon there for the test suite.
set -euo pipefail

DEV_USER="${DEV_USER:-__DEV_USER__}"
HOME_DIR="${HOME_DIR:-/home/$DEV_USER}"
HERDR_BIN="${HERDR_BIN:-$HOME_DIR/.local/bin/herdr}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/remote-vs-code}"
DAEMON="$LIB_DIR/herdr-title.py"
CONF_DIR="$HOME_DIR/.config/rvc"
CONF="$CONF_DIR/herdr-title.toml"
UNIT="${UNIT:-/etc/systemd/system/rvc-herdr-title.service}"

command -v python3 >/dev/null 2>&1 || { echo "!! python3 not found — install python3 first" >&2; exit 1; }

install -d -m 0755 "$LIB_DIR"
cat > "$DAEMON" <<'PYEOF'
#!/usr/bin/env python3
"""Mirror live herdr session state into the attached terminal's window/tab title.

Source of truth: remote-vs-code deploy/69-herdr-title.sh. Overwritten on redeploy.

Talks the herdr socket API directly (newline-delimited JSON):
  session.snapshot        -> the full session state, for labels
  events.subscribe        -> live changes; subscribing REPLAYS current state
  client.window_title.set -> herdr writes the OSC to the attached client's pty

Run with no arguments to daemonize over every session. --render-once / --render-snapshot
are the seams the test suite drives; they touch no socket.
"""
import json
import os
import socket
import sys
import threading
import time

DEFAULTS = {
    "format": "{icon} {session_path} · {agent_title|tab_name|host}",
    "max_length": 72,
    "ensure_session_token": True,
    "write_all_clients": True,
    "icons": {
        "working": "⚡",
        "blocked": "❓",
        "idle": "○",
        "done": "✓",
        "unknown": "·",
    },
}

# Global, zero-argument subscriptions. pane.agent_status_changed is deliberately NOT used:
# its subscription variant requires a pane_id, so it would need re-subscribing on every
# pane creation, and pane.updated already carries agent_status AND the terminal title.
SUBSCRIPTIONS = [
    "pane.updated", "pane.focused", "tab.focused",
    "workspace.focused", "tab.renamed", "workspace.renamed",
]

DEBOUNCE_S = 0.2
RESCAN_S = 5.0
BACKOFF_MAX_S = 30.0
# How often to re-assert the title, even when nothing changed.
#
# This is not just a retry. The title is state living in the CLIENT's terminal, while
# last_sent is state in this daemon — and herdr publishes no client-attach event, so a
# new client is invisible here. Reopening a Ghostty tab, reattaching over mosh, or a
# client that was absent when the daemon started all produce an unchanged session that
# nonetheless needs painting. Skipping the write because "we already sent it" sends it
# to a terminal that no longer exists. Re-asserting also heals a title changed out of
# band. One tiny write per session per interval, far under herdr's own rate limiting.
REASSERT_S = 3.0


# ---------------------------------------------------------------- config

def load_config(path):
    """Config, falling back to DEFAULTS. A broken file must never cost you every title."""
    cfg = {k: (dict(v) if isinstance(v, dict) else v) for k, v in DEFAULTS.items()}
    if not path or not os.path.exists(path):
        return cfg
    try:
        import tomllib
        with open(path, "rb") as fh:
            raw = tomllib.load(fh)
    except Exception as e:
        print(f"herdr-title: {path}: {e} — using the default format", file=sys.stderr)
        return cfg
    for key in ("format", "max_length", "ensure_session_token", "write_all_clients"):
        if key in raw:
            cfg[key] = raw[key]
    if isinstance(raw.get("icons"), dict):
        cfg["icons"].update(raw["icons"])
    return cfg


# ---------------------------------------------------------------- rendering

def _tokens(view, cfg):
    session = view.get("session") or ""
    workspace = view.get("workspace") or ""
    status = view.get("status") or "unknown"
    icons = cfg["icons"]
    cwd = view.get("cwd") or ""
    home = os.environ.get("HOME") or ""
    if home and (cwd == home or cwd.startswith(home + "/")):
        cwd = "~" + cwd[len(home):]
    return {
        "icon": icons.get(status, icons.get("unknown", "")),
        "status": status,
        "session": session,
        "workspace": workspace,
        "tab": view.get("tab") or "",
        # herdr auto-names tabs "1", "2", ... A bare number is a placeholder, not a name
        # you chose, so it must not win a {a|b} fallback over something informative.
        "tab_name": "" if view.get("tab", "").isdigit() else (view.get("tab") or ""),
        "agent": view.get("agent") or "",
        "title": view.get("title") or "",
        # terminal_title_stripped is whatever the pane last set — for a plain shell that
        # is "__DEV_USER__@host:~/dir", the exact string this feature exists to replace. Only
        # treat it as meaningful when an agent is actually detected in the pane, so
        # {agent_title|...} can fall through to something useful instead.
        "agent_title": (view.get("title") or "") if view.get("agent") else "",
        "host": view.get("host") or "",
        "cwd": cwd,
        # `hs` names a session and its first space after the same folder, so
        # "Remote-VS-Code/Remote-VS-Code" would be pure noise. Collapse it.
        "session_path": session if (not workspace or workspace == session)
                        else f"{session}/{workspace}",
    }


def _expand(fmt, tok):
    """Substitute {token} and {a|b} (a, or b when a renders empty)."""
    out, i, n = [], 0, len(fmt)
    while i < n:
        c = fmt[i]
        if c != "{":
            out.append(c)
            i += 1
            continue
        end = fmt.find("}", i)
        if end == -1:
            out.append(c)
            i += 1
            continue
        for name in fmt[i + 1:end].split("|"):
            val = tok.get(name.strip(), "")
            if val:
                out.append(val)
                break
        i = end + 1
    return "".join(out)


def render(view, cfg):
    tok = _tokens(view, cfg)
    text = _expand(cfg.get("format") or DEFAULTS["format"], tok).strip()

    # Click-to-focus (mac/notify-bridge-setup.sh) finds the Ghostty tab by looking for the
    # session name in the title. A hand-edited format could drop it, so put it back unless
    # explicitly told not to.
    if cfg.get("ensure_session_token", True):
        sess = tok["session"]
        if sess and f"{sess} · " not in text and f"{sess}/" not in text:
            text = f"{sess} · {text}" if text else sess

    limit = cfg.get("max_length") or 0
    try:
        limit = int(limit)
    except (TypeError, ValueError):
        limit = 0
    if limit > 0 and len(text) > limit:
        text = text[:limit - 1] + "…"
    return text


# ---------------------------------------------------------------- painting clients

# WHY THIS EXISTS: client.window_title.set reaches only the ONE client herdr considers
# foreground. A session routinely has several — a Ghostty tab per machine, plus Moshi
# clients that stay attached while disconnected on purpose, to deliver push alerts. The
# tabs that most need a title are the ones you are NOT looking at, and foreground routing
# structurally cannot paint those. Observed on __VM_NAME__: a session actively worked in for
# 40 minutes never received a title, while a direct pty write landed immediately.
#
# So the title is also written straight to every client's terminal, the way tmux does it.
# herdr has no client-targeting or kick-client request, so there is no supported route.
#
# RISK, and why the write is shaped as it is: these bytes interleave with herdr's own
# output on the same pty. A complete sequence emitted in ONE os.write() cannot be split
# by us; the residual risk is landing between bytes of a sequence herdr is emitting,
# which costs a transient glitch until its next redraw. Set write_all_clients = false to
# fall back to foreground-only.

TITLE_OSC = "\033]0;{}\007"


def sanitize_title(text):
    """Strip anything that could terminate or escape the OSC sequence."""
    return "".join(ch for ch in text if ord(ch) >= 0x20 and ch != "\x7f")


def client_ptys(session, procfs="/proc"):
    """Controlling ptys of every attached client of `session`.

    A client is exactly `herdr --session <name>` (or bare `herdr` for the default
    session). Anything with a trailing subcommand is either the session server or a
    one-shot CLI call, and must not be painted.
    """
    want = [] if session == "default" else ["--session", session]
    found = []
    try:
        entries = os.listdir(procfs)
    except OSError:
        return found
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            with open(os.path.join(procfs, entry, "cmdline"), "rb") as fh:
                argv = [a for a in fh.read().decode("utf-8", "replace").split("\x00") if a]
            if not argv or os.path.basename(argv[0]) != "herdr":
                continue
            if argv[1:] != want:
                continue
            pty = os.readlink(os.path.join(procfs, entry, "fd", "0"))
        except OSError:
            continue
        if pty.startswith("/dev/pts/"):
            found.append(pty)
    return found


def paint_ptys(ptys, title):
    """Write the title to each pty. A client can vanish mid-loop; that is not fatal."""
    payload = TITLE_OSC.format(sanitize_title(title)).encode()
    for pty in ptys:
        try:
            fd = os.open(pty, os.O_WRONLY | os.O_NOCTTY | os.O_NONBLOCK)
        except OSError:
            continue
        try:
            os.write(fd, payload)
        except OSError:
            pass
        finally:
            os.close(fd)


# ------------------------------------------------- snapshot -> focused view

class SessionView:
    """The bit of a herdr session a title cares about, kept current by events."""

    def __init__(self, session, host, snapshot=None):
        self.session = session
        self.host = host
        self.panes = {}
        self.workspaces = {}
        self.tabs = {}
        self.focused_workspace = None
        self.focused_tab = None
        self.focused_pane = None
        if snapshot:
            self.load_snapshot(snapshot)

    def load_snapshot(self, snap):
        self.panes = {p["pane_id"]: p for p in snap.get("panes", []) if p.get("pane_id")}
        self.workspaces = {w["workspace_id"]: w for w in snap.get("workspaces", []) if w.get("workspace_id")}
        self.tabs = {t["tab_id"]: t for t in snap.get("tabs", []) if t.get("tab_id")}
        self.focused_workspace = snap.get("focused_workspace_id")
        self.focused_tab = snap.get("focused_tab_id")
        self.focused_pane = snap.get("focused_pane_id")

    def apply(self, envelope):
        """Apply one event. Unknown kinds are ignored: herdr may add more."""
        data = envelope.get("data") or {}
        kind = envelope.get("event") or data.get("type") or ""
        if kind == "pane_updated":
            pane = data.get("pane") or {}
            pid = pane.get("pane_id")
            if pid:
                self.panes[pid] = pane
                if pane.get("focused"):
                    self.focused_pane = pid
        elif kind == "pane_focused":
            self.focused_pane = data.get("pane_id") or self.focused_pane
        elif kind == "tab_focused":
            self.focused_tab = data.get("tab_id") or self.focused_tab
        elif kind == "workspace_focused":
            self.focused_workspace = data.get("workspace_id") or self.focused_workspace
        elif kind in ("tab_renamed", "workspace_renamed"):
            key = "tab_id" if kind == "tab_renamed" else "workspace_id"
            store = self.tabs if kind == "tab_renamed" else self.workspaces
            ident, label = data.get(key), data.get("label")
            if ident and label is not None:
                store.setdefault(ident, {key: ident})["label"] = label

    def focused(self):
        """The pane actually being looked at: focused pane of focused tab of focused space."""
        ws = self.focused_workspace
        panes = [p for p in self.panes.values() if not ws or p.get("workspace_id") == ws]
        if not panes:
            panes = list(self.panes.values())
        pane = next((p for p in panes if p.get("pane_id") == self.focused_pane), None)
        if pane is None:
            pane = next((p for p in panes if p.get("focused")), None)
        if pane is None:
            pane = panes[0] if panes else {}
        return pane

    def view(self):
        pane = self.focused()
        ws = pane.get("workspace_id") or self.focused_workspace
        tab = pane.get("tab_id") or self.focused_tab
        return {
            "session": self.session,
            "host": self.host,
            "workspace": (self.workspaces.get(ws) or {}).get("label") or "",
            "tab": (self.tabs.get(tab) or {}).get("label") or "",
            "agent": pane.get("agent") or "",
            "status": pane.get("agent_status") or "unknown",
            "title": pane.get("terminal_title_stripped") or "",
            "cwd": pane.get("cwd") or "",
        }


# ---------------------------------------------------------------- socket API

class ApiError(Exception):
    pass


class Conn:
    """Newline-delimited JSON over a Unix socket, with its own read buffer.

    ONE REQUEST PER CONNECTION. herdr answers a request and then closes the socket —
    verified against 0.7.5, where a second request on the same connection gets EPIPE.
    So the snapshot and every title write open their own short-lived connection, and
    only events.subscribe gets a long-lived one, which herdr holds open to stream.

    Deliberately NOT socket.makefile(): a buffered file object is not safe to mix with
    per-read timeouts, and this client depends on them — a read timeout IS the debounce.
    A timeout raised mid-read would strand already-received bytes inside the file object's
    buffer, where the next read cannot see them. Holding the buffer here means a timeout
    keeps whatever arrived and simply resumes.
    """

    def __init__(self, path, timeout):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""

    def send(self, obj):
        self.sock.sendall((json.dumps(obj) + "\n").encode())

    def readline(self, timeout):
        """One parsed message. Raises socket.timeout when nothing completes in time."""
        self.sock.settimeout(timeout)
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ApiError("socket closed")
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b"\n")
        return json.loads(line)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def one_shot(path, method, params, req_id, timeout=10):
    """Open a connection, make one request, return its result, close. See Conn."""
    conn = Conn(path, timeout)
    try:
        conn.send({"id": req_id, "method": method, "params": params})
        msg = conn.readline(timeout)
        if "error" in msg:
            raise ApiError(str(msg["error"]))
        return msg.get("result") or {}
    finally:
        conn.close()


def session_sockets(herdr_dir):
    """(name, socket path) for the default session and every named one."""
    found = []
    default = os.path.join(herdr_dir, "herdr.sock")
    if os.path.exists(default):
        found.append(("default", default))
    sessions = os.path.join(herdr_dir, "sessions")
    try:
        names = sorted(os.listdir(sessions))
    except OSError:
        names = []
    for name in names:
        path = os.path.join(sessions, name, "herdr.sock")
        if os.path.exists(path):
            found.append((name, path))
    return found


class Watcher(threading.Thread):
    """One session: snapshot, subscribe, then keep the title in step with the events."""

    def __init__(self, name, path, cfg_path, host, stop):
        super().__init__(daemon=True, name=f"herdr-title[{name}]")
        self.session, self.path, self.cfg_path, self.host, self.stop = name, path, cfg_path, host, stop
        self.last_sent = None

    def run(self):
        backoff = 1.0
        while not self.stop.is_set():
            try:
                self.serve()
                backoff = 1.0
            except Exception as e:
                if self.stop.is_set():
                    return
                print(f"herdr-title[{self.session}]: {e}", file=sys.stderr)
            if not os.path.exists(self.path):
                return  # session stopped; the rescan loop will drop us
            self.stop.wait(backoff)
            backoff = min(backoff * 2, BACKOFF_MAX_S)

    def serve(self):
        cfg = load_config(self.cfg_path)
        # Labels (space/tab names) only come from the snapshot, so fetch it first — on
        # its own connection, because herdr closes one after each request.
        snap = one_shot(self.path, "session.snapshot", {}, "rvc-title-snap")
        view = SessionView(self.session, self.host, snap.get("snapshot") or snap)

        stream = Conn(self.path, 10)
        try:
            # The ONLY request on this connection; herdr holds it open and streams.
            stream.send({"id": "rvc-title-sub", "method": "events.subscribe",
                         "params": {"subscriptions": [{"type": t} for t in SUBSCRIPTIONS]}})
            ack = stream.readline(10)
            if "error" in ack:
                raise ApiError(str(ack["error"]))

            self.flush(view, cfg)
            # A read timeout IS the debounce: a burst of events is fully applied before
            # the first quiet moment, so the title is written once rather than per event.
            dirty = False
            quiet = 0.0
            while not self.stop.is_set():
                try:
                    msg = stream.readline(DEBOUNCE_S)
                except socket.timeout:
                    if dirty:
                        self.flush(view, cfg)
                        dirty = False
                        quiet = 0.0
                        continue
                    # Nothing changed — re-assert anyway. A client that attached since
                    # the last write (reopened tab, mosh reattach) has a blank title and
                    # no event announces it. See REASSERT_S.
                    quiet += DEBOUNCE_S
                    if quiet >= REASSERT_S:
                        quiet = 0.0
                        self.flush(view, cfg, force=True)
                    continue
                except json.JSONDecodeError:
                    continue
                view.apply(msg)
                dirty = True
        finally:
            stream.close()

    def flush(self, view, cfg, force=False):
        title = render(view.view(), cfg)
        if title == self.last_sent and not force:
            return
        res = one_shot(self.path, "client.window_title.set", {"title": title}, "rvc-title-set")
        # herdr only reached the foreground client. Paint the rest ourselves.
        if cfg.get("write_all_clients", True):
            paint_ptys(client_ptys(self.session), title)
        # Only remember it once herdr actually WROTE it. A session with no attached
        # client answers changed:false/no_foreground_client; latching that would mean the
        # tab never gets a title when you attach later, because from then on nothing
        # would ever look changed. Leaving last_sent alone makes the retry above pick
        # it up as soon as a client appears.
        if res.get("changed"):
            self.last_sent = title


def daemon(cfg_path, herdr_dir, host):
    stop = threading.Event()
    watchers = {}
    try:
        while True:
            live = dict(session_sockets(herdr_dir))
            for name, path in live.items():
                w = watchers.get(name)
                if w is None or not w.is_alive():
                    w = Watcher(name, path, cfg_path, host, stop)
                    watchers[name] = w
                    w.start()
            for name in [n for n in watchers if n not in live]:
                watchers.pop(name, None)
            time.sleep(RESCAN_S)
    except KeyboardInterrupt:
        stop.set()


# ---------------------------------------------------------------- entry point

def main(argv):
    cfg_path = os.path.expanduser("~/.config/rvc/herdr-title.toml")
    mode = None
    args = list(argv[1:])
    while args:
        a = args.pop(0)
        if a == "--config" and args:
            cfg_path = args.pop(0)
        elif a in ("--render-once", "--render-snapshot"):
            mode = a
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print(f"herdr-title: unknown argument {a!r}", file=sys.stderr)
            return 2

    if mode:
        payload = json.load(sys.stdin)
        cfg = load_config(cfg_path)
        if mode == "--render-once":
            print(render(payload, cfg))
            return 0
        view = SessionView(payload.get("session") or "",
                           payload.get("host") or "",
                           payload.get("snapshot") or {})
        for ev in payload.get("events") or []:
            view.apply(ev)
        print(render(view.view(), cfg))
        return 0

    daemon(cfg_path,
           os.environ.get("HERDR_CONFIG_DIR") or os.path.expanduser("~/.config/herdr"),
           socket.gethostname().split(".")[0])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PYEOF
chmod 0755 "$DAEMON"
echo "installed $DAEMON"

# Optional second copy so the repo's test suite can drive the same bytes.
if [ -n "${HERDR_TITLE_COPY:-}" ]; then
  install -d -m 0755 "$(dirname "$HERDR_TITLE_COPY")"
  install -m 0644 "$DAEMON" "$HERDR_TITLE_COPY"
  echo "copied daemon to $HERDR_TITLE_COPY"
fi

# ---- config: create if absent, NEVER overwrite ----------------------------
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0755 "$CONF_DIR"
if [ ! -s "$CONF" ]; then
  cat > "$CONF" <<'TOML'
# Ghostty/terminal tab title for herdr sessions — managed by remote-vs-code
# deploy/69-herdr-title.sh, which creates this file once and never rewrites it.
# Edit freely; `systemctl restart rvc-herdr-title` picks changes up.
#
# Tokens: {icon} {status} {session} {workspace} {tab} {agent} {title} {host} {cwd}
#         {session_path}   — {session}, or {session}/{workspace} when they differ
#         {agent_title}    — {title}, but ONLY when an agent is detected in the pane.
#                            Plain {title} is whatever the pane last set, which for a
#                            shell is "__DEV_USER__@host:~/dir" — the string this replaces.
#         {tab_name}       — {tab}, unless it is herdr's auto-number ("1", "2", …)
#         {a|b|c}          — the first that renders non-empty
format = "{icon} {session_path} · {agent_title|tab_name|host}"

# Ellipsised at this length. Ghostty truncates the tab itself, but the window title
# shows the full string, so this is deliberately generous.
max_length = 72

# Keep the session name in the title even if `format` drops it, so the notification
# click handler can still find the tab (mac/notify-bridge-setup.sh).
ensure_session_token = true

# Write the title straight to EVERY attached client's terminal, not just the one herdr
# calls foreground. Without this, a session with several clients (a Ghostty tab plus the
# Moshi clients that stay attached to deliver push alerts) paints only one of them — and
# the tabs worth glancing at are the ones you are NOT in. Trade-off: these bytes share
# the pty with herdr's own output, so on rare occasions one of its escape sequences can
# be split, costing a transient glitch until the next redraw. Set false for
# foreground-only.
write_all_clients = true

[icons]
working = "⚡"
blocked = "❓"
idle    = "○"
done    = "✓"
unknown = "·"
TOML
  chown "$DEV_USER:$DEV_USER" "$CONF"; chmod 0644 "$CONF"
  echo ">> $CONF: created"
else
  echo ">> $CONF: already present — left as-is"
fi

if [ ! -x "$HERDR_BIN" ]; then
  echo ">> herdr not installed at $HERDR_BIN — daemon installed but not enabled"
  exit 0
fi

# ---- systemd: a system unit running as the dev user, like reboot/swap-notify ----
cat > "$UNIT" <<UNITEOF
# Managed by remote-vs-code deploy/69-herdr-title.sh — regenerated on redeploy.
[Unit]
Description=herdr session state in the terminal tab title
After=network.target

[Service]
Type=simple
User=$DEV_USER
ExecStart=/usr/bin/python3 $DAEMON
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNITEOF
chmod 0644 "$UNIT"
systemctl daemon-reload
systemctl enable --now "$(basename "$UNIT")" >/dev/null 2>&1 \
  && echo ">> enabled $(basename "$UNIT")" \
  || echo "!! could not enable $(basename "$UNIT") — check: systemctl status $(basename "$UNIT")" >&2

echo ">> done. Titles follow the focused pane; debug with: journalctl -u $(basename "$UNIT") -f"
