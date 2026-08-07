#!/usr/bin/env bash
# Install `speak-phone`: turn a written summary into per-sentence audio and serve it to a
# phone as a read-along page.
#
# WHY THIS EXISTS: sessions are often followed from a phone over a mobile terminal app,
# where a screen full of code and paths is hard to read. This speaks the prose while the
# text stays on screen, with the sentence being spoken highlighted, and shows commands and
# tables without reading them aloud.
#
# WHY IT IS ALL LOCAL: iOS exposes no good voices to web pages (its Premium and assistant
# voices are withheld from `speechSynthesis`, in Safari as well as third-party webviews),
# so the browser cannot speak this acceptably. Rendering on the box instead costs ~2s and
# ~220MB transient, needs no account, token, or cloud service, and works while the laptop
# is asleep. The service binds to loopback ONLY and is reached through the SSH session the
# phone already holds, so nothing is exposed to the LAN or anywhere else.
#
# WHY PER SENTENCE: one audio file per sentence is what lets the page know which sentence
# is playing. That buys highlighting, previous/next, and tap-a-sentence-to-jump with no
# word-timing data, which the TTS engine does not emit.
#
# RUN ON: the VM.  ./deploy/run-remote.sh <ssh-target> deploy/87-speak-phone.sh DEV_USER=<user>
# Set SPEAK_PHONE_COPY=<path> to also drop the program there for the test suite.
#
# Idempotent: re-running re-installs the program, leaves an existing config alone, and
# skips any voice already present.
set -euo pipefail

DEV_USER="${DEV_USER:-${SUDO_USER:-$(id -un)}}"
HOME_DIR="${HOME_DIR:-/home/$DEV_USER}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/remote-vs-code}"
BIN="${BIN:-/usr/local/bin/speak-phone}"
VOICE_DIR="${VOICE_DIR:-/usr/local/share/piper-voices}"
UNIT_DIR="${UNIT_DIR:-$HOME_DIR/.config/systemd/user}"
CONF_DIR="${CONF_DIR:-$HOME_DIR/.config/remote-vs-code}"
CONF="$CONF_DIR/speak.env"

PIPER_DIR="$LIB_DIR/piper"
PIPER_REL="${PIPER_REL:-2023.11.14-2}"
PIPER_URL="https://github.com/rhasspy/piper/releases/download/$PIPER_REL/piper_linux_x86_64.tar.gz"
VOICE_BASE="${VOICE_BASE:-https://huggingface.co/rhasspy/piper-voices/resolve/main}"

# Judged by ear on the device. amy is the default; hfc_female is the fastest to render;
# ryan is the male option; jenny_dioco is a backup but noticeably accented. Others tested
# and rejected: kristin, lessac, cori.
VOICES="${VOICES:-en_US-amy-medium en_US-hfc_female-medium en_US-ryan-high en_GB-jenny_dioco-medium}"

command -v python3 >/dev/null 2>&1 || { echo "!! python3 not found" >&2; exit 1; }
command -v curl    >/dev/null 2>&1 || { echo "!! curl not found" >&2; exit 1; }

echo ">> [1/5] piper -> $PIPER_DIR"
if [ -x "$PIPER_DIR/piper" ]; then
  echo "   already installed"
else
  install -d -m 0755 "$LIB_DIR"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/piper.tgz" "$PIPER_URL"
  tar xzf "$TMP/piper.tgz" -C "$LIB_DIR"      # unpacks a `piper/` directory
  [ -x "$PIPER_DIR/piper" ] || { echo "!! piper missing after unpack" >&2; exit 1; }
  echo "   installed $("$PIPER_DIR/piper" --version 2>&1 | head -1 || echo ok)"
fi

echo ">> [2/5] voices -> $VOICE_DIR"
install -d -m 0755 "$VOICE_DIR"
for v in $VOICES; do
  if [ -s "$VOICE_DIR/$v.onnx" ]; then
    echo "   have $v"
    continue
  fi
  lang="${v%%-*}"; rest="${v#*-}"; name="${rest%-*}"; qual="${rest##*-}"
  url="$VOICE_BASE/${lang:0:2}/$lang/$name/$qual/$v"
  echo "   fetching $v"
  curl -fsSL -o "$VOICE_DIR/$v.onnx"      "$url.onnx"
  curl -fsSL -o "$VOICE_DIR/$v.onnx.json" "$url.onnx.json"
done
chmod 0644 "$VOICE_DIR"/*.onnx "$VOICE_DIR"/*.json 2>/dev/null || true

echo ">> [3/5] $BIN"
install -m 0755 /dev/stdin "$BIN" <<'SPEAKPHONE'
#!/usr/bin/env python3
"""speak-phone — read a written summary, speak it on a phone, and read along.

Claude writes a summary in markdown on stdin. Prose is split into sentences and rendered
to one small audio file each by piper; fenced blocks and tables are kept for the screen and
never spoken. A local web page then plays the sentences in order, highlighting each as it
goes, so the page can be followed while listening.

Why per sentence rather than one file: it is the whole trick. Each sentence being its own
audio source is what lets the page know which one is playing, which buys highlighting,
previous/next, and tap-a-sentence-to-jump without any word-timing data — piper emits none.

Everything is local. The service binds to loopback only and is reached through the SSH
session the phone already holds, so there is no account, token, or cloud service anywhere
in this path.

Subcommands:
  (default)      read markdown on stdin, render, store, print the URL
  serve          run the HTTP service (the systemd user unit runs this)
  voices         list installed voices, marking the default
  voice <name>   set the default voice
  url            print the local URL
  prune          drop old summaries now (normally automatic on write)
"""

from __future__ import annotations

import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# ---------------------------------------------------------------- configuration

HOME = Path.home()
CONF = Path(os.environ.get("SPEAK_CONF", HOME / ".config/remote-vs-code/speak.env"))
STATE = Path(os.environ.get("SPEAK_STATE", HOME / ".local/state/speak"))
PIPER = Path(os.environ.get("SPEAK_PIPER", "/usr/local/lib/remote-vs-code/piper/piper"))
VOICES = Path(os.environ.get("SPEAK_VOICES", "/usr/local/share/piper-voices"))

DEFAULTS = {
    "VOICE": "en_US-amy-medium",
    # length_scale: LOWER is faster. 0.595 is about 1.68x, chosen by ear on the device.
    # Slow synthesis exposes its own flatness -- voices rejected at natural pace became
    # acceptable fast -- so this is a quality setting as much as a speed one. Baked in
    # rather than applied at playback: piper's duration model produces more natural fast
    # speech than time-stretching, and a baked rate also applies in the car, where the
    # page's control is out of reach.
    "RATE": "0.595",
    "PORT": "8790",
    "KEEP": "10",     # summaries kept per AGENT stream (session--workspace--tab)
    "DAYS": "3",      # hard age cap, swept on every write by any agent
}


def config() -> dict:
    cfg = dict(DEFAULTS)
    try:
        for line in CONF.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return cfg


def set_config(key: str, value: str) -> None:
    CONF.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    found = False
    if CONF.exists():
        for line in CONF.read_text().splitlines():
            if re.match(rf"\s*{re.escape(key)}\s*=", line):
                lines.append(f"{key}={value}")
                found = True
            else:
                lines.append(line)
    if not found:
        lines.append(f"{key}={value}")
    CONF.write_text("\n".join(lines).rstrip() + "\n")


def die(msg: str, code: int = 1):
    print(f"speak-phone: {msg}", file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------- session identity

def session_name() -> str:
    """Which session is publishing.

    Same precedence as the notify hook: tmux wins, then herdr, then the directory. A pane
    can sit inside both multiplexers, and only one name can own the summary.
    """
    if os.environ.get("TMUX"):
        try:
            out = subprocess.run(["tmux", "display-message", "-p", "#S"],
                                 capture_output=True, text=True, timeout=5)
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
    if os.environ.get("HERDR_SESSION"):
        return os.environ["HERDR_SESSION"]
    return Path.cwd().name or "session"


def safe(name: str) -> str:
    """A session name that is safe as a single path component and in a URL."""
    return re.sub(r"[^A-Za-z0-9._-]", "-", name)[:64] or "session"


def _run(cmd: list[str]) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def _herdr_state(session: str, ws_id: str, tab_id: str) -> tuple[str, str]:
    """Resolve ids to names from the file herdr persists, not from its API socket.

    The socket is not a dependable dependency. Detaching every client at once takes the
    API listener down on all three long-running sessions here and it does NOT come back
    when they are reattached -- the servers keep running, so nothing looks broken, but
    every lookup after that returns nothing and the ids leak into the slug. A URL like
    `NetSapiens--w1--w1-tC` is exactly that: workspace w1, tab w1:tC, unresolved.

    session.json is written by the server every few seconds and survives all of it. Tab
    ids carry the public tab number in hex -- `w1:tC` is tab 12 -- and
    `public_tab_numbers` lists those in the same order as `tabs`.
    """
    if not session or "/" in session or session in (".", ".."):
        return "", ""
    f = HOME / ".config/herdr/sessions" / session / "session.json"
    try:
        d = json.loads(f.read_text())
    except (OSError, ValueError):
        return "", ""

    ws_name = tab_name = ""
    for w in d.get("workspaces") or []:
        if w.get("id") != ws_id:
            continue
        # A workspace rarely has a name of its own; herdr labels it with its directory.
        ws_name = w.get("custom_name") or Path(w.get("identity_cwd") or "").name
        want = tab_id.rsplit(":t", 1)[-1].lower() if ":t" in tab_id else ""
        for num, tb in zip(w.get("public_tab_numbers") or [], w.get("tabs") or []):
            if isinstance(num, int) and f"{num:x}" == want:
                tab_name = tb.get("custom_name") or ""
                break
        break
    return ws_name, tab_name


def _herdr_names(session: str, ws_id: str, tab_id: str) -> tuple[str, str]:
    """Turn herdr ids into the names a human uses.

    The persisted file answers first: it needs no running server, costs no subprocess,
    and matches what the tab bar shows. The API is the fallback, so a change to the file
    format degrades to a query rather than to raw ids.
    """
    ws_name, tab_name = _herdr_state(session, ws_id, tab_id)
    if ws_name and tab_name:
        return ws_name, tab_name
    if ws_id and not ws_name:
        try:
            d = json.loads(_run(["herdr", "workspace", "list", "--session", session]) or "{}")
            for w in (d.get("result") or {}).get("workspaces", []):
                if w.get("workspace_id") == ws_id:
                    ws_name = w.get("label") or ""
                    break
        except ValueError:
            pass
    if tab_id and not tab_name:
        try:
            d = json.loads(_run(["herdr", "tab", "list", "--session", session]) or "{}")
            for tb in (d.get("result") or {}).get("tabs", []):
                if tb.get("tab_id") == tab_id:
                    tab_name = tb.get("name") or tb.get("label") or ""
                    break
        except ValueError:
            pass
    return ws_name, tab_name


def where() -> dict:
    """Identify the pane that is CALLING, not the one on screen.

    This must never consult a focus-derived source. `moshi-hook context` resolves its herdr
    fields from the focused pane while taking cwd from the caller, and that mixed provenance
    silently filed one agent's summaries into another agent's stream -- whichever tab was
    being looked at at the time -- so two agents interleaved and evicted each other under the
    retention cap. A wrong label is cosmetic; a shared stream loses work.

    herdr exports the calling pane's own ids into its environment, which is authoritative no
    matter what is focused. Names come from asking herdr to resolve those ids; git and cwd
    are read locally. Nothing here depends on what is on screen.
    """
    info: dict = {"cwd": os.getcwd()}

    branch = _run(["git", "rev-parse", "--abbrev-ref", "HEAD"])
    if branch and branch != "HEAD":
        info["branch"] = branch
        info["dirty"] = bool(_run(["git", "status", "--porcelain"]))

    pane = os.environ.get("HERDR_PANE_ID", "")
    if pane:
        session = os.environ.get("HERDR_SESSION", "")
        ws_id = os.environ.get("HERDR_WORKSPACE_ID", "")
        tab_id = os.environ.get("HERDR_TAB_ID", "")
        ws_name, tab_name = _herdr_names(session, ws_id, tab_id)
        info.update({
            "mux": "herdr",
            "pane": pane,
            "workspace": ws_name or ws_id,
            "tab": tab_name or tab_id,
        })
        return info

    if os.environ.get("TMUX"):
        # -t the caller's own pane: without it tmux answers for the active window.
        target = os.environ.get("TMUX_PANE", "")
        args = ["tmux", "display-message", "-p"] + (["-t", target] if target else [])
        info.update({
            "mux": "tmux",
            "pane": target,
            "tab": _run(args + ["#W"]),
        })
    return info


def identity(w: dict, session: str) -> tuple[str, str]:
    """(display name, storage slug) for the agent publishing this summary.

    Session alone is not an identity: one herdr session holds several workspaces, each
    holding several tabs, each typically one agent. Keyed on the session, six agents in one
    workspace share a stream and evict each other under the retention cap.

    Tab alone is not an identity either -- `cli` exists in three different workspaces here.
    So the slug is session, workspace and tab together, with duplicates collapsed (a
    workspace named after its session is the common case) and the pane id standing in when
    a tab has no name.
    """
    parts, seen = [], set()
    for x in (session, w.get("workspace"), w.get("tab") or w.get("pane")):
        x = (x or "").strip()
        if x and x.lower() not in seen:
            seen.add(x.lower())
            parts.append(x)
    # The FULL identity is the name -- session, workspace and tab. Dropping the leading
    # part made siblings from different sessions read identically on the overview, which
    # is exactly the collision this key exists to prevent.
    return " / ".join(parts), "--".join(safe(x) for x in parts)


def subpath(cwd: str, session: str) -> str:
    """Where in the project this session actually is.

    The session name is the project; this is the rest of the path below it, which is what
    distinguishes two sessions in the same repo. Falls back to a home-relative path when
    the directory is outside the workspace root entirely.
    """
    ws = Path(os.environ.get("SPEAK_WORKSPACE", Path.home() / "workspace"))
    p = Path(cwd)
    try:
        parts = list(p.relative_to(ws).parts)
    except ValueError:
        try:
            return "~/" + str(p.relative_to(Path.home()))
        except ValueError:
            return str(p)
    if parts and parts[0] == session:
        parts = parts[1:]
    return "/".join(parts)


# ---------------------------------------------------------------- markdown parsing

_FENCE = re.compile(r"^\s*(```|~~~)")
# Sentence boundary: end punctuation, then space, then something that starts a sentence.
# The lookbehind list keeps common abbreviations from splitting mid-sentence.
_ABBREV = r"(?<!\bMr)(?<!\bMrs)(?<!\bDr)(?<!\be\.g)(?<!\bi\.e)(?<!\bvs)(?<!\betc)"
_SENT = re.compile(rf"{_ABBREV}(?<=[.!?])[\"')\]]*\s+(?=[A-Z\"'(\[])")

_STRIP = [
    (re.compile(r"!?\[([^\]]*)\]\([^)]*\)"), r"\1"),   # links/images -> their text
    (re.compile(r"(?<!\w)https?://\S+"), ""),           # bare URLs: noise when spoken
    (re.compile(r"`([^`]*)`"), r"\1"),                  # inline code -> bare words
    (re.compile(r"\*\*([^*]+)\*\*"), r"\1"),
    (re.compile(r"(?<!\*)\*([^*]+)\*(?!\*)"), r"\1"),
    (re.compile(r"^\s*[-*+]\s+", re.M), ""),            # bullet markers
    (re.compile(r"^\s*#{1,6}\s+", re.M), ""),           # heading markers
    (re.compile(r"\s+"), " "),
]


_URL = re.compile(r"""(?<![\w>"'=])(https?://[^\s<>)\]}"']+)""")
_MDLINK = re.compile(r"\[([^\]]+)\]\((https?://[^)\s]+)\)")


def shown_html(text: str) -> str:
    """A shown block, with any URL in it made tappable.

    Shown blocks are where paths and references live, and a reference he cannot tap is a
    reference he has to retype on a phone.
    """
    return _URL.sub(r"<a href='\1'>\1</a>", html.escape(text))


def inline_html(text: str) -> str:
    """One sentence as it appears ON SCREEN — the counterpart to speakable().

    Speech and display diverge on purpose: the voice gets the label with no URL, because
    reading one aloud is a stream of noise, and the screen gets a real anchor. Same source
    text, two renderings, so a link never has to be omitted to keep the audio listenable.
    """
    out, last = [], 0
    for m in _MDLINK.finditer(text):
        out.append(html.escape(text[last:m.start()]))
        out.append("<a href='%s'>%s</a>" % (html.escape(m.group(2), quote=True),
                                            html.escape(m.group(1))))
        last = m.end()
    out.append(html.escape(text[last:]))
    s = "".join(out)
    s = _URL.sub(r"<a href='\1'>\1</a>", s)          # bare URLs too
    s = re.sub(r"`([^`]*)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"^\s*[-*+]\s+", "", s)
    return s.strip()


def speakable(text: str) -> str:
    """Markdown prose as something worth hearing: no syntax read aloud."""
    for pat, rep in _STRIP:
        text = pat.sub(rep, text)
    return text.strip()


def split_sentences(text: str) -> list[str]:
    parts = [p.strip() for p in _SENT.split(text) if p.strip()]
    return parts or ([text.strip()] if text.strip() else [])


_LIST = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+(.*)")


def parse_blocks(md: str) -> list[dict]:
    """Split markdown into spoken and shown-but-unspoken blocks.

    One rule, so Claude does not have to maintain two documents: paragraphs and lists are
    spoken, fenced blocks and tables are shown. Code, paths and commands stay visible and
    silent.

    Lists are their own kind rather than prose. Flattening bullets into a paragraph runs
    the choices together into one breathless sentence; keeping them separate makes each
    item its own audio segment, so they can be tapped individually and, when the list
    answers a question, announced as "Option one", "Option two", …

    Every spoken block carries parallel `sentences` (what is displayed) and `say` (what is
    voiced). They differ only where speech needs a cue the screen does not.
    """
    blocks: list[dict] = []
    para: list[str] = []
    items: list[str] = []
    fence_char: str | None = None
    shown: list[str] = []

    def last_prose_is_question() -> bool:
        for b in reversed(blocks):
            if b["kind"] == "prose" and b["sentences"]:
                return b["sentences"][-1].rstrip().endswith("?")
            if b["kind"] != "shown":
                return False
        return False

    def flush_para():
        if para:
            raw = " ".join(para)
            text = speakable(raw)
            if text:
                s = split_sentences(text)
                # Sentences are split on the SPOKEN text so `say` and `sentences` stay in
                # step; the display HTML is matched back by position, and falls back to the
                # plain sentence when the paragraph has no markup worth rendering.
                shows = split_sentences(inline_html(raw))
                blocks.append({"kind": "prose", "sentences": s, "say": list(s),
                               "html": shows if len(shows) == len(s) else None})
            para.clear()

    def flush_items():
        if items:
            shows = [speakable(i) for i in items if speakable(i)]
            if shows:
                # "Option one, …" only when the list is answering a question — otherwise
                # the numbering is noise read aloud.
                if last_prose_is_question():
                    words = ["one", "two", "three", "four", "five", "six", "seven",
                             "eight", "nine", "ten"]
                    says = [f"Option {words[i] if i < len(words) else i + 1}. {t}"
                            for i, t in enumerate(shows)]
                else:
                    says = list(shows)
                blocks.append({"kind": "list", "sentences": shows, "say": says,
                               "html": [inline_html(i) for i in items
                                        if speakable(i)]})
            items.clear()

    def flush_shown():
        if shown:
            blocks.append({"kind": "shown", "text": "\n".join(shown).rstrip()})
            shown.clear()

    for line in md.splitlines():
        m = _FENCE.match(line)
        if fence_char:
            if m and m.group(1) == fence_char:
                fence_char = None
                flush_shown()
            else:
                shown.append(line)
            continue
        if m:
            flush_para(); flush_items()
            fence_char = m.group(1)
            continue
        if line.lstrip().startswith("|"):          # markdown table
            flush_para(); flush_items()
            shown.append(line)
            continue
        if shown:
            flush_shown()
        li = _LIST.match(line)
        if li:
            flush_para()
            items.append(li.group(1).strip())
            continue
        if not line.strip():
            flush_para(); flush_items()
            continue
        flush_items()
        para.append(line.strip())

    flush_para()
    flush_items()
    flush_shown()
    return blocks


# ---------------------------------------------------------------- rendering

def voice_path(cfg: dict, name: str | None = None) -> Path:
    name = name or cfg["VOICE"]
    p = VOICES / f"{name}.onnx"
    if not p.exists():
        have = ", ".join(sorted(v.stem for v in VOICES.glob("*.onnx"))) or "none installed"
        die(f"voice not found: {name}\n  available: {have}")
    return p


def concat(parts: list[Path], out: Path) -> list[float]:
    """Join the per-sentence wavs into ONE file, returning each part's start time.

    Playing a file per sentence is what caused a 2-3 second stall BETWEEN sentences on
    wireless CarPlay: every `play()` on an idle stream re-establishes the audio route. One
    continuous file pays that cost once. Highlighting survives because the start offsets
    are kept -- the page tracks position by time instead of by file, which also makes
    scrubbing a single timeline rather than 30 disconnected ones.
    """
    starts: list[float] = []
    w = None
    try:
        for src in parts:
            with wave.open(str(src), "rb") as r:
                if w is None:
                    w = wave.open(str(out), "wb")
                    w.setparams(r.getparams())
                starts.append(w.tell() / r.getframerate())
                w.writeframes(r.readframes(r.getnframes()))
    finally:
        if w is not None:
            w.close()
    return starts


def render(blocks: list[dict], out: Path, cfg: dict, voice: str | None) -> int:
    """Render every sentence to its own wav in ONE piper invocation.

    piper reloads its model per process (~0.25s), so calling it per sentence would pay that
    cost N times. --json-input takes one line per utterance with an explicit output_file,
    which keeps ordering exact and the model load singular.
    """
    if not PIPER.exists():
        die(f"piper not found at {PIPER} (run deploy/87-speak-phone.sh)")
    model = voice_path(cfg, voice)

    jobs, n = [], 0
    for b in blocks:
        if b["kind"] not in ("prose", "list"):
            continue
        b["audio"] = []
        # `say` is what gets voiced; `sentences` is what stays on screen. They diverge for
        # option lists, where speech gets an "Option one" cue the screen does not need.
        for s in b.get("say") or b["sentences"]:
            n += 1
            fn = f"s{n}.wav"
            b["audio"].append(fn)
            jobs.append({"text": s, "output_file": str(out / fn)})

    if not jobs:
        return 0

    stdin = "\n".join(json.dumps(j) for j in jobs) + "\n"
    proc = subprocess.run(
        [str(PIPER), "--model", str(model), "--length_scale", cfg["RATE"], "--json-input"],
        input=stdin, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        die("piper failed:\n" + (proc.stderr or "").strip()[-800:])

    # A sentence whose audio is missing must not stall playback -- the page shows it and
    # skips it, which is why it is dropped from the timeline rather than dropped entirely.
    ordered: list[Path] = []
    for b in blocks:
        if b["kind"] not in ("prose", "list"):
            continue
        keep = [a for a in b["audio"] if (out / a).exists()]
        b["audio"] = [a if (out / a).exists() else None for a in b["audio"]]
        ordered += [out / a for a in keep]

    starts = concat(ordered, out / "audio.wav")
    at = {p.name: s for p, s in zip(ordered, starts)}
    for b in blocks:
        if b["kind"] not in ("prose", "list"):
            continue
        b["at"] = [at.get(a) if a else None for a in b["audio"]]
    for f in ordered:                      # the parts are redundant once joined
        f.unlink(missing_ok=True)
    for b in blocks:
        if b["kind"] in ("prose", "list"):
            b.pop("audio", None)
    return n


# ---------------------------------------------------------------- store

def store(session: str, blocks: list[dict], cfg: dict, voice: str | None,
          forced: bool = False) -> Path:
    w = where()
    if forced:
        display, sess = session, safe(session)
    else:
        display, sess = identity(w, session)
    ts = time.strftime("%Y%m%d-%H%M%S")
    out = STATE / sess / ts
    out.mkdir(parents=True, exist_ok=True)

    count = render(blocks, out, cfg, voice)

    title = ""
    for b in blocks:
        if b["kind"] in ("prose", "list") and b["sentences"]:
            title = b["sentences"][0]
            break

    meta = {
        "session": display,
        "root": session,
        "slug": sess,
        "ts": ts,
        "created": time.time(),
        "voice": voice or cfg["VOICE"],
        "rate": cfg["RATE"],
        "sentences": count,
        "title": title,
        "where": w,
        "path": subpath(w.get("cwd", ""), session),
        "blocks": blocks,
    }
    (out / "meta.json").write_text(json.dumps(meta, indent=1))
    prune(cfg)
    return out


def summaries(sess_dir: Path) -> list[Path]:
    return sorted((d for d in sess_dir.iterdir() if (d / "meta.json").exists()), reverse=True)


def prune(cfg: dict) -> int:
    """Keep the last KEEP per session and nothing older than DAYS. Runs on write, so
    there is no timer and no cleanup service to forget about."""
    keep, days = int(cfg["KEEP"]), int(cfg["DAYS"])
    cutoff = time.time() - days * 86400
    removed = 0
    if not STATE.exists():
        return 0
    for sess in STATE.iterdir():
        if not sess.is_dir():
            continue
        for i, d in enumerate(summaries(sess)):
            old = i >= keep
            try:
                stale = json.loads((d / "meta.json").read_text()).get("created", 0) < cutoff
            except (OSError, ValueError):
                stale = True
            if old or stale:
                shutil.rmtree(d, ignore_errors=True)
                removed += 1
        # An agent that stops publishing leaves its stream behind. Its summaries age out
        # like anyone's, but without this the empty directory outlives it forever -- and
        # with the cap now PER AGENT rather than shared, abandoned streams accumulate
        # instead of being evicted by newer ones.
        if not summaries(sess):
            try:
                sess.rmdir()
            except OSError:
                pass
    return removed


def load(path: Path) -> dict | None:
    try:
        return json.loads((path / "meta.json").read_text())
    except (OSError, ValueError):
        return None


def installed_voices() -> list[str]:
    return sorted(v.stem for v in VOICES.glob("*.onnx"))


def rerender(d: Path, voice: str, cfg: dict) -> bool:
    """Re-speak an existing summary in a different voice, in place.

    Judging a voice from a sample paragraph is not the same as judging it on your own
    summary, so switching has to be doable from the phone on real content rather than by
    editing a config file and waiting for the next turn.
    """
    m = load(d)
    if not m or voice not in installed_voices():
        return False
    for old in d.glob("*.wav"):
        old.unlink(missing_ok=True)
    m["sentences"] = render(m["blocks"], d, cfg, voice)
    m["voice"] = voice
    (d / "meta.json").write_text(json.dumps(m, indent=1))
    return True


# ---------------------------------------------------------------- pages

CSS = """
:root{color-scheme:light dark}
*{-webkit-tap-highlight-color:transparent}
body{font:17px/1.6 -apple-system,system-ui,sans-serif;margin:0;
     padding:18px 16px 40px;max-width:42rem}
h1{font-size:1.16rem;margin:0 0 1px}
h2.path{font-size:.95rem;font-weight:600;opacity:.78;margin:0 0 2px;
        font-family:ui-monospace,monospace}
.who{font-size:.8rem;opacity:.62;margin:0 0 2px}
.sub{opacity:.6;font-size:.88rem;margin:0 0 20px}
a{color:#2563eb;text-decoration:none}
.card{display:flex;align-items:stretch;margin:0 0 11px;border-radius:13px;
      background:rgba(127,127,127,.12);color:inherit;overflow:hidden}
.card .body{flex:1;min-width:0;padding:14px 4px 14px 15px;color:inherit;
            text-decoration:none;display:block}
/* A deliberately wide target: this is tapped one-handed, often while walking. */
.card .mark{flex:0 0 62px;border:0;background:transparent;color:inherit;
            font-size:1.3rem;opacity:.22;cursor:pointer;
            border-left:1px solid rgba(127,127,127,.18)}
.card.done .mark{opacity:1;color:#22c55e}
.card .n{font-weight:600;font-size:1.02rem;line-height:1.35}
.card.done .body{opacity:.45}
.card.done .n{font-weight:500}
.card .m{font-size:.82rem;opacity:.6;margin-top:2px}
.card .t{font-size:.9rem;opacity:.85;margin-top:6px}
.sent{display:inline;padding:2px 0;border-radius:4px;cursor:pointer;
      transition:background-color .15s}
.sent.on{background:rgba(37,99,235,.30)}
.sent.done{opacity:.55}
.sent.mute{opacity:.45;cursor:default}
.voices{display:flex;flex-wrap:wrap;gap:6px;margin:14px 0 4px;font-size:.8rem}
.voices a{padding:5px 10px;border-radius:99px;background:rgba(127,127,127,.16);
          color:inherit;opacity:.7}
.voices a.cur{background:rgba(37,99,235,.26);opacity:1;font-weight:700}
/* Back pairs with the heard control at BOTH ends, so whichever end you are at, the
   two things you might want next are side by side and the same shape. */
.mini{display:none}
@media(max-width:640px){
  .mini{display:block;position:sticky;top:0;z-index:6;margin:-18px -16px 12px;
        padding:9px 16px;font-size:.82rem;font-weight:600;
        background:rgba(28,28,32,.94);backdrop-filter:blur(12px);
        box-shadow:0 1px 0 rgba(127,127,127,.22);
        white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
}
@media(max-width:640px) and (prefers-color-scheme:light){
  .mini{background:rgba(250,250,252,.95)}
}
.row{display:flex;gap:9px;align-items:stretch;margin:22px 0 12px}
.row .heard{flex:1;margin:0}
.back{flex:0 0 auto;display:flex;align-items:center;padding:13px 15px;border-radius:12px;
      background:rgba(127,127,127,.16);color:inherit;font-size:.9rem;font-weight:600;
      text-decoration:none;white-space:nowrap}
.heard{display:flex;align-items:center;gap:10px;margin:22px 0 0;padding:13px 14px;
       border-radius:12px;background:rgba(127,127,127,.12);cursor:pointer;
       font-size:.92rem;user-select:none}
.heard .box{width:20px;height:20px;border-radius:6px;flex:0 0 20px;
            border:2px solid rgba(127,127,127,.55);display:flex;align-items:center;
            justify-content:center;font-size:.8rem;color:#fff}
.heard.on .box{background:#22c55e;border-color:#22c55e}
.heard.on{opacity:.72}
.spd{display:flex;flex-wrap:wrap;gap:6px;margin:26px 0 4px;font-size:.8rem}
.spd button{padding:5px 10px;border-radius:99px;border:0;font-size:.8rem;
            background:rgba(127,127,127,.16);color:inherit;opacity:.7}
.spd button.cur{background:rgba(37,99,235,.26);opacity:1;font-weight:700}
ol.opts{margin:14px 0;padding:0;list-style:none;counter-reset:o}
ol.opts li{counter-increment:o;display:flex;gap:10px;padding:9px 11px;margin:0 0 7px;
           border-radius:11px;background:rgba(127,127,127,.11)}
ol.opts li::before{content:counter(o);flex:0 0 1.4em;height:1.4em;line-height:1.4em;
                   text-align:center;border-radius:50%;background:rgba(37,99,235,.28);
                   font-size:.78rem;font-weight:700;margin-top:2px}
.shown{margin:18px 0;padding:13px 14px;border-radius:11px;background:rgba(127,127,127,.13);
       border-left:3px solid rgba(127,127,127,.45);font-family:ui-monospace,monospace;
       font-size:.82rem;line-height:1.5;white-space:pre-wrap;overflow-x:auto}
.shown a{color:#5b9dff;word-break:break-all}
.sent a{color:#5b9dff}
.shown .tag{display:block;font-family:-apple-system,system-ui,sans-serif;font-size:.7rem;
            text-transform:uppercase;letter-spacing:.06em;opacity:.55;margin-bottom:7px}
/* In the flow on a wide screen: pinned to the viewport bottom it was stranded far from
   everything it belongs with. On a phone it pins, because pause has to stay reachable
   partway down a long summary -- tapping a sentence can start playback, but nothing else
   can stop it. */
.bar{display:flex;gap:9px;align-items:center;margin:0 0 14px}
@media(max-width:640px){
  .bar{position:fixed;left:0;right:0;bottom:0;z-index:5;margin:0;
       padding:11px 14px calc(11px + env(safe-area-inset-bottom));
       background:rgba(28,28,32,.94);backdrop-filter:blur(12px);
       box-shadow:0 -1px 0 rgba(127,127,127,.22)}
  body{padding-bottom:96px}
}
@media(max-width:640px) and (prefers-color-scheme:light){
  .bar{background:rgba(250,250,252,.95)}
}
.bar button{padding:13px 15px;font-size:1rem;font-weight:600;border:0;border-radius:11px;
            background:rgba(127,127,127,.26);color:inherit}
.bar button.play{flex:1;background:#2563eb;color:#fff}
#pos{font-size:.82rem;opacity:.65;min-width:3.4em;text-align:right;
     font-variant-numeric:tabular-nums}
/* Mirrors #pos on the other end. When the bar is pinned this is the only way back that
   is always on screen -- the other two scroll away with the text. */
/* Same chrome as the prev/next buttons, so it reads as touchable rather than as a label
   that happens to be tappable. Narrower padding keeps Play the widest thing in the bar. */
.allmini{display:flex;align-items:center;justify-content:center;
         padding:13px 12px;border-radius:11px;background:rgba(127,127,127,.26);
         font-size:.82rem;font-weight:600;color:inherit;text-decoration:none;
         white-space:nowrap}
"""

PLAYER_JS = """
(function(){
  var sents=[].slice.call(document.querySelectorAll('.sent[data-at]'));
  var audio=document.getElementById('au');
  var play=document.getElementById('play'),pos=document.getElementById('pos');
  if(!audio||!sents.length)return;
  var at=sents.map(function(s){return parseFloat(s.dataset.at)});
  var i=-1;
  // Land slightly BEFORE the boundary. Seeking exactly onto it clips the first syllable:
  // the decoder starts mid-phoneme. Never rewind past the previous sentence's start, so a
  // short sentence cannot swallow the one before it.
  var LEAD=0.35, pin=-1;

  function paint(){
    sents.forEach(function(s,j){s.className='sent'+(j===i?' on':(j<i?' done':''))});
    pos.textContent=(i<0?'\\u2013':i+1)+'/'+sents.length;
    play.innerHTML=audio.paused?'\\u25b6\\ufe0e Play':'\\u258c\\u258c Pause';
  }
  // Which sentence owns this instant. Driven by playback position rather than by file
  // boundaries, so the stream never stops -- that is what removes the CarPlay stall.
  function idxAt(t){
    var k=-1;
    for(var j=0;j<at.length;j++){if(at[j]<=t+0.02)k=j;else break}
    return k;
  }
  function seek(j){
    if(j<0||j>=at.length)return;
    var floor=j>0?at[j-1]:0;
    audio.currentTime=Math.max(floor,at[j]-LEAD);
    if(audio.paused)audio.play();
    // Hold the highlight on the sentence asked for while the lead-in plays, otherwise it
    // flicks back to the previous one for half a second.
    i=j;pin=at[j];paint();
    sents[j].scrollIntoView({block:'center',behavior:'smooth'});
  }

  audio.addEventListener('timeupdate',function(){
    if(pin>=0){ if(audio.currentTime<pin)return; pin=-1; }
    var k=idxAt(audio.currentTime);
    if(k!==i){i=k;paint();
      if(sents[i])sents[i].scrollIntoView({block:'center',behavior:'smooth'})}
  });
  audio.addEventListener('play',paint);
  audio.addEventListener('pause',paint);
  audio.addEventListener('ended',function(){i=-1;paint()});

  // Speed is applied at PLAYBACK, not re-rendered: it is instant, it costs nothing, and
  // the browser preserves pitch. The labels are absolute speeds, computed from the rate
  // the file was baked at, so "1.4" means 1.4 whatever the render settings become.
  var spd=document.getElementById('spd');
  if(spd){
    var baked=parseFloat(spd.dataset.baked)||1.39;
    var want=parseFloat(localStorage.getItem('speakSpeed2'))||baked;
    var opts=[baked-0.6,baked-0.45,baked-0.3,baked-0.15,baked,baked+0.15];
    opts.forEach(function(s){
      var b=document.createElement('button');
      b.textContent=s.toFixed(2).replace(/0$/,'')+'\\u00d7';
      b.onclick=function(){
        want=s;localStorage.setItem('speakSpeed2',s);
        audio.playbackRate=s/baked;mark();
      };
      b._s=s;spd.appendChild(b);
    });
    var mark=function(){
      [].slice.call(spd.querySelectorAll('button')).forEach(function(b){
        b.className=Math.abs(b._s-want)<0.01?'cur':'';
      });
    };
    audio.playbackRate=want/baked;mark();
  }

  // Heard state. Kept on the server so it is the same on every device, and applied
  // optimistically so a tap feels instant on a phone.
  var boxes=[].slice.call(document.querySelectorAll('.heard'));
  if(boxes.length){
    var on=boxes[0].classList.contains('on');
    // NOT `paint`: `var` is function-scoped, so declaring it here overwrote the sentence
    // highlighter's paint() for the whole script and every timeupdate repainted
    // checkboxes instead of sentences.
    var paintHeard=function(){
      boxes.forEach(function(b){
        b.className='heard'+(on?' on':'');
        b.querySelector('.lab').textContent=on?'Heard':'Mark as heard';
      });
    };
    var send=function(what){
      fetch(boxes[0].dataset.url+'/'+what,{method:'GET'}).catch(function(){});
    };
    paintHeard();
    // One state, two controls -- top and bottom stay in step without a reload.
    boxes.forEach(function(b){
      b.addEventListener('click',function(){on=!on;paintHeard();send(on?1:0)});
    });
    // Finishing marks it, but only until a deliberate choice is made: from then on the
    // server ignores the automatic mark, so unchecking something you have heard sticks.
    audio.addEventListener('ended',function(){
      if(!on){on=true;paintHeard();send('auto')}
    });
  }

  play.addEventListener('click',function(){audio.paused?audio.play():audio.pause()});
  document.getElementById('next').addEventListener('click',function(){seek(i+1)});
  document.getElementById('prev').addEventListener('click',function(){
    // Back a sentence, unless we are mid-sentence -- then restart this one, which is what
    // "say that again" means.
    var s=at[i]||0;
    seek(audio.currentTime-s>1.5?i:i-1);   // mid-sentence "prev" means say that again
  });
  sents.forEach(function(s,j){s.addEventListener('click',function(e){
    // A link inside a sentence must open, not start reading the sentence it sits in.
    // The whole sentence is a tap target, so without this the anchor's click bubbles
    // straight into seek() and the paragraph starts playing as you leave the page.
    if(e.target.closest && e.target.closest('a'))return;
    seek(j);
  })});
  paint();
})();
"""


INDEX_JS = """
(function(){
  [].slice.call(document.querySelectorAll('.card .mark')).forEach(function(b){
    b.addEventListener('click',function(e){
      // The tick sits inside the card but must not follow the card's link.
      e.preventDefault();e.stopPropagation();
      var card=b.closest('.card');
      var on=!card.classList.contains('done');
      card.className='card'+(on?' done':'');
      fetch(card.dataset.url+'/'+(on?1:0),{method:'GET'}).catch(function(){});
    });
  });
})();
"""


def page(title: str, body: str, script: str = "") -> bytes:
    return (
        "<!doctype html><html lang=en><head><meta charset=utf-8>"
        "<meta name=viewport content='width=device-width,initial-scale=1,viewport-fit=cover'>"
        # Moshi's server list shows this title, so it is how the entry is recognised there.
        f"<title>{html.escape(title)}</title><style>{CSS}</style></head><body>"
        f"{body}"
        + (f"<script>{script}</script>" if script else "")
        + "</body></html>"
    ).encode()


def ago(t: float) -> str:
    d = max(0, int(time.time() - t))
    if d < 90:
        return f"{d}s ago"
    if d < 5400:
        return f"{d // 60}m ago"
    if d < 172800:
        return f"{d // 3600}h ago"
    return f"{d // 86400}d ago"


def newest_summary() -> str:
    """Slug of the most recent summary across every session, or empty."""
    best, when = "", 0.0
    if not STATE.exists():
        return ""
    for sess in STATE.iterdir():
        if not sess.is_dir():
            continue
        got = summaries(sess)
        if not got:
            continue
        m = load(got[0])
        if m and m.get("created", 0) > when:
            best, when = m["slug"], m["created"]
    return best


def index_page() -> bytes:
    rows = []
    if STATE.exists():
        latest = []
        for sess in STATE.iterdir():
            if not sess.is_dir():
                continue
            got = summaries(sess)
            if not got:
                continue
            m = load(got[0])
            if m:
                latest.append((m["created"], m, len(got)))
        for _, m, n in sorted(latest, key=lambda r: -r[0]):
            more = f" &middot; {n} kept" if n > 1 else ""
            w = m.get("where") or {}
            ident = " &middot; ".join(html.escape(b) for b in
                                      (m.get("path"), w.get("pane")) if b)
            done = " done" if m.get("read") else ""
            rows.append(
                f"<div class='card{done}' data-url='/r/{html.escape(m['slug'])}/{m['ts']}'>"
                f"<a class=body href='/s/{html.escape(m['slug'])}'>"
                f"<div class=n>{html.escape(m['session'])}</div>"
                + (f"<div class=who>{ident}</div>" if ident else "") +
                f"<div class=m>{ago(m['created'])} &middot; {m['sentences']} sentences{more}</div>"
                f"<div class=t>{html.escape(m['title'][:130])}</div></a>"
                "<button class=mark aria-label='mark heard'>&#10003;</button></div>"
            )
    body = ("<h1>Claude summaries</h1>"
            "<p class=sub>Newest first. Tap to listen; tap the tick to mark it heard.</p>"
            + ("".join(rows) or "<p class=sub>Nothing yet.</p>"))
    return page("Claude summaries", body, INDEX_JS)


def summary_page(m: dict, base: str, older: list[Path]) -> bytes:
    def span(b: dict, j: int, s: str) -> str:
        t0 = (b.get("at") or [None] * len(b["sentences"]))[j]
        shown = (b.get("html") or [None] * len(b["sentences"]))[j] or html.escape(s)
        if t0 is None:
            return f"<span class='sent mute'>{shown}</span>"
        return f"<span class=sent data-at='{t0:.3f}'>{shown}</span>"

    out = []
    for b in m["blocks"]:
        if b["kind"] == "shown":
            out.append(f"<div class=shown><span class=tag>shown, not spoken</span>"
                       f"{shown_html(b['text'])}</div>")
        elif b["kind"] == "list":
            lis = "".join(f"<li>{span(b, j, s)}</li>"
                          for j, s in enumerate(b["sentences"]))
            out.append(f"<ol class=opts>{lis}</ol>")
        else:
            out.append("<p>" + " ".join(span(b, j, s)
                                        for j, s in enumerate(b["sentences"])) + "</p>")

    # Which voice is speaking, and what else is installed — tap to re-speak this summary
    # in that voice and make it the default.
    strip = "".join(
        f"<a class='{'cur' if v == m.get('voice') else ''}' "
        f"href='/v/{m['slug']}/{m['ts']}/{v}'>{html.escape(v.split('-')[1])}</a>"
        for v in installed_voices())

    w = m.get("where") or {}

    hist = ""
    if len(older) > 1:
        links = " &middot; ".join(
            f"<a href='/s/{m['slug']}/{d.name}'>{d.name[9:11]}:{d.name[11:13]}</a>"
            for d in older[1:6])
        hist = f"<p class=sub style='margin-top:26px'>Earlier: {links}</p>"

    # Identity, most-specific last: which project, where in it, which tab/agent. With a
    # dozen sessions running, the project name alone does not identify anything.
    bits = [b for b in (w.get("mux"), w.get("pane")) if b]
    if w.get("branch"):
        bits.append(w["branch"] + ("*" if w.get("dirty") else ""))
    head = f"<h1>{html.escape(m['session'])}</h1>"
    if m.get("path"):
        head += f"<h2 class=path>{html.escape(m['path'])}</h2>"
    if bits:
        head += f"<p class=who>{html.escape(' · '.join(bits))}</p>"
    # Back sits beside the title rather than under it: it is the one control you want
    # before reading anything, and at the top of a long page it must not be scrolled to.


    body = (f"<div class=mini>{html.escape(m['session'])}</div>" + head +
            f"<p class=sub>{ago(m['created'])} &middot; {m['sentences']} sentences &middot; "
            f"<a href='/all'>all sessions</a></p>"
            + (f"<div class=row><a class=back href='/all'>&larr; All</a>"
               f"<div class='heard{' on' if m.get('read') else ''}' "
               f"data-url='/r/{m['slug']}/{m['ts']}'>"
               "<span class=box>&#10003;</span><span class=lab></span></div></div>")
            + "".join(out)

            + (f"<div class=row><a class=back href='/all'>&larr; All</a>"
               f"<div class='heard{' on' if m.get('read') else ''}' "
               f"data-url='/r/{m['slug']}/{m['ts']}'>"
               "<span class=box>&#10003;</span><span class=lab></span></div></div>")
            + ("<div class=bar><a class=allmini href='/all'>&larr; All</a>"
               "<button id=prev>&#9664;</button>"
               "<button class=play id=play>&#9654;&#65038; Play</button>"
               "<button id=next>&#9654;</button><span id=pos>&ndash;/&ndash;</span></div>")
            + f"<div class=spd id=spd data-baked='{1.0 / float(m.get('rate', 0.595)):.3f}'>"
              "<span style='opacity:.5;align-self:center;margin-right:2px'>speed</span>"
              "</div>"
            + f"<div class=voices>{strip}</div>"
            + hist +
            f"<audio id=au preload=auto src='{base}/audio.wav'></audio>"
            "")
    tab_title = m["session"] + (f" / {m['path']}" if m.get("path") else "")
    return page(tab_title, body, PLAYER_JS)


# ---------------------------------------------------------------- server

def inside(path: Path) -> bool:
    """True when `path` really is under the store, after symlinks and dots resolve.

    The component check should make this unreachable; it is here because a single
    permissive character class was enough to defeat that check once already, and the
    consequence was reading a file from outside the store.
    """
    try:
        return STATE.resolve() in path.resolve().parents or path.resolve() == STATE.resolve()
    except OSError:
        return False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass  # journald does not need a line per audio segment

    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _wav(self, path: Path):
        # Range support: without it iOS will not scrub, and scrubbing is the whole point
        # of using real audio files rather than a speech engine.
        data = path.read_bytes()
        rng = self.headers.get("Range", "")
        m = re.match(r"bytes=(\d+)-(\d*)", rng or "")
        if not m:
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            return
        start = int(m.group(1))
        end = int(m.group(2)) if m.group(2) else len(data) - 1
        end = min(end, len(data) - 1)
        chunk = data[start:end + 1]
        self.send_response(206)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.send_header("Content-Length", str(len(chunk)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(chunk)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        parts = [p for p in path.split("/") if p]

        # No traversal. The alphabet alone is NOT enough: it permits "." and "-", so ".."
        # matches it happily, and `/a/../../x.wav` served a file from outside the store.
        # Reject dot components outright, and check the resolved path below as well.
        if any(not re.fullmatch(r"[A-Za-z0-9._-]+", p) or p in (".", "..")
               for p in parts):
            return self._send(400, b"bad path", "text/plain")

        if not parts:
            newest = newest_summary()
            if newest:
                self.send_response(303)
                self.send_header("Location", f"/s/{newest}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            return self._send(200, index_page(), "text/html; charset=utf-8")

        if parts == ["all"]:
            return self._send(200, index_page(), "text/html; charset=utf-8")

        if parts[0] == "s" and len(parts) in (2, 3):
            sess = STATE / parts[1]
            if not sess.is_dir() or not inside(sess):
                return self._send(404, page("not found", "<h1>No such session</h1>"),
                                  "text/html; charset=utf-8")
            got = summaries(sess)
            if not got:
                return self._send(404, page("nothing yet",
                                            "<h1>Nothing yet</h1>"
                                            "<p class=sub><a href='/'>all sessions</a></p>"),
                                  "text/html; charset=utf-8")
            want = sess / parts[2] if len(parts) == 3 else got[0]
            m = load(want)
            if not m:
                return self._send(404, b"not found", "text/plain")
            return self._send(200, summary_page(m, f"/a/{parts[1]}/{want.name}", got),
                              "text/html; charset=utf-8")

        # /v/<session>/<ts>/<voice> — re-speak this summary in that voice, make it the
        # default, and come back to the page. A GET that changes state is normally wrong,
        # but this is a loopback-only page reached through an authenticated SSH session,
        # and a link is the only thing that is one tap on a phone.
        if parts[0] == "v" and len(parts) == 4:
            d = STATE / parts[1] / parts[2]
            if not (d / "meta.json").exists() or not inside(d):
                return self._send(404, b"not found", "text/plain")
            cfg = config()
            if not rerender(d, parts[3], cfg):
                return self._send(400, b"unknown voice", "text/plain")
            set_config("VOICE", parts[3])
            self.send_response(303)
            self.send_header("Location", f"/s/{parts[1]}/{parts[2]}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        # /r/<slug>/<ts>/<0|1> — mark heard or unheard. The flag lives in the summary's
        # own metadata rather than in browser storage, so it is the same on the phone and
        # in a desktop browser, and it dies with the summary exactly as asked.
        if parts[0] == "r" and len(parts) == 4 and parts[3] in ("0", "1", "auto"):
            f = STATE / parts[1] / parts[2] / "meta.json"
            if not f.is_file() or not inside(f):
                return self._send(404, b"not found", "text/plain")
            try:
                m = json.loads(f.read_text())
                if parts[3] == "auto":
                    # Finishing playback marks it -- but a deliberate choice outranks the
                    # automation permanently. Unchecking something you have heard is a
                    # decision (come back to it), and re-marking it would erase that.
                    if m.get("manual"):
                        return self._send(200, b"manual", "text/plain")
                    m["read"] = True
                else:
                    m["read"] = parts[3] == "1"
                    m["manual"] = True
                f.write_text(json.dumps(m, indent=1))
            except (OSError, ValueError):
                return self._send(500, b"could not update", "text/plain")
            return self._send(200, b"ok", "text/plain")

        if parts[0] == "a" and len(parts) == 4 and parts[3].endswith(".wav"):
            wav = STATE / parts[1] / parts[2] / parts[3]
            if not wav.is_file() or not inside(wav):
                return self._send(404, b"not found", "text/plain")
            return self._wav(wav)

        self._send(404, b"not found", "text/plain")


def serve(cfg: dict):
    STATE.mkdir(parents=True, exist_ok=True)
    port = int(cfg["PORT"])
    # Loopback only. The phone reaches this through the SSH session it already holds, so
    # nothing here is exposed to the LAN, the tailnet, or anything else.
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"speak-phone serving http://127.0.0.1:{port}/", flush=True)
    srv.serve_forever()


# ---------------------------------------------------------------- cli

def cmd_voices(cfg: dict):
    got = sorted(VOICES.glob("*.onnx"))
    if not got:
        die(f"no voices installed in {VOICES}")
    for v in got:
        mark = "*" if v.stem == cfg["VOICE"] else " "
        print(f" {mark} {v.stem}")
    print(f"\n * = default. Change it with:  speak-phone voice <name>")
    print(f"   config: {CONF}")


def main(argv: list[str]) -> int:
    cfg = config()
    args = argv[1:]

    if args and args[0] == "serve":
        serve(cfg)
        return 0
    if args and args[0] == "voices":
        cmd_voices(cfg)
        return 0
    if args and args[0] == "voice":
        if len(args) < 2:
            die("usage: speak-phone voice <name>")
        voice_path(cfg, args[1])
        set_config("VOICE", args[1])
        print(f"default voice: {args[1]}")
        return 0
    if args and args[0] == "url":
        print(f"http://127.0.0.1:{cfg['PORT']}/")
        return 0
    if args and args[0] == "prune":
        print(f"removed {prune(cfg)} summaries")
        return 0

    voice, session = None, None
    i = 0
    while i < len(args):
        if args[i] in ("--voice", "-v") and i + 1 < len(args):
            voice = args[i + 1]; i += 2
        elif args[i] in ("--session", "-s") and i + 1 < len(args):
            session = args[i + 1]; i += 2
        elif args[i] in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            die(f"unknown argument: {args[i]}")

    md = sys.stdin.read()
    if not md.strip():
        die("nothing on stdin")

    blocks = parse_blocks(md)
    if not any(b["kind"] == "prose" for b in blocks):
        die("no prose to speak (everything was a code block or table)")

    out = store(session or session_name(), blocks, cfg, voice, forced=bool(session))
    m = load(out) or {}
    print(f"http://127.0.0.1:{cfg['PORT']}/s/{m.get('slug', '')}"
          f"   ({m.get('sentences', 0)} sentences, {m.get('voice', '')})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        sys.exit(130)
SPEAKPHONE

# A second copy for the test suite, which exercises the exact bytes installed above.
if [ -n "${SPEAK_PHONE_COPY:-}" ]; then
  install -d -m 0755 "$(dirname "$SPEAK_PHONE_COPY")"
  install -m 0755 "$BIN" "$SPEAK_PHONE_COPY"
  echo "   copy -> $SPEAK_PHONE_COPY"
fi

echo ">> [4/5] config -> $CONF"
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0755 "$CONF_DIR"
if [ -e "$CONF" ]; then
  echo "   exists — leaving your settings alone"
else
  install -o "$DEV_USER" -g "$DEV_USER" -m 0644 /dev/stdin "$CONF" <<'CONFEOF'
# speak-phone settings.  `speak-phone voices` lists what is installed.

# Default voice. Change with: speak-phone voice <name>
VOICE=en_US-amy-medium

# Speed. LOWER is faster; 0.595 is about 1.68x, chosen by ear on the device. Slow
# synthesis sounds flatter, so this is a quality setting as much as a speed one — voices
# rejected at 1.0 were fine fast. The page also has a playback-speed control, but baking
# it in sounds better and applies in the car too.
RATE=0.595

# Loopback port the read-along page is served on.
PORT=8790

# Retention: summaries kept per AGENT stream, and a hard age cap in days. Pruned on write,
# so there is no timer to maintain.
KEEP=10
DAYS=3
CONFEOF
fi

echo ">> [5/5] user service -> $UNIT_DIR/speak-phone.service"
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0755 "$UNIT_DIR"
install -o "$DEV_USER" -g "$DEV_USER" -m 0644 /dev/stdin "$UNIT_DIR/speak-phone.service" <<UNITEOF
[Unit]
Description=speak-phone read-along summaries (loopback only)
After=default.target

[Service]
Type=simple
ExecStart=$BIN serve
Restart=on-failure
RestartSec=5
# Small, short-lived renders; this cap exists so a runaway can never repeat the
# out-of-memory incident this box has already had once.
MemoryMax=1G

[Install]
WantedBy=default.target
UNITEOF

cat <<EOM

speak-phone installed.

  speak-phone voices                 # list voices, * marks the default
  speak-phone voice <name>           # change it
  echo "Some prose." | speak-phone   # render + print the URL
  speak-phone url                    # http://127.0.0.1:<port>/

Start the service (as $DEV_USER, not root):

  systemctl --user daemon-reload
  systemctl --user enable --now speak-phone.service

Then open it from the phone: the terminal app's server list shows it as
"Claude summaries" once it is listening.
EOM
