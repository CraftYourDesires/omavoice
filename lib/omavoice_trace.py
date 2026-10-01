"""Opt-in dictation trace: where wording changes and where the time goes.

`omavoice-trace start N` arms it for the next N dictations. After each one,
omavoice-output calls capture(), which reads Voxtype's RAM chunk log
($XDG_RUNTIME_DIR/voxtype-daemon.log, emptied at every recording start) and
saves one record with three stages of text and the time each step took
after you released the key:

  raw      what Cohere transcribed (chunks plus tail), before anything else
  input    what dictation-cleanup received, after [text.replacements]
  final    what the cleanup returned and was pasted

Records live in $XDG_RUNTIME_DIR/omavoice-trace (RAM only, folder 0700,
files 0600), expire after EXPIRE_SECONDS, and are never logged. The screen
context Voxtype logs next to the cleanup input is not copied.
"""
import calendar
import difflib
import json
import os
import re
import time

RUNTIME = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
DIR = os.environ.get("OMAVOICE_TRACE_DIR") or os.path.join(RUNTIME, "omavoice-trace")
DAEMON_LOG = os.environ.get("OMAVOICE_DAEMON_LOG") or os.path.join(RUNTIME, "voxtype-daemon.log")
ARMED = os.path.join(DIR, "remaining")
EXPIRE_SECONDS = 24 * 3600
MAX_RECORDS = 50

ANSI = re.compile(r"\x1b\[[0-9;]*m")
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?)Z\s+\w+\s+(.*)$")


def _rust_str(s, i):
    """Parse a Rust Debug string literal starting at s[i] == '"'.
    Returns (text, index after the closing quote) or (None, i)."""
    if i >= len(s) or s[i] != '"':
        return None, i
    out, i = [], i + 1
    while i < len(s):
        c = s[i]
        if c == '"':
            return "".join(out), i + 1
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n == "u" and s[i + 2:i + 3] == "{":
                end = s.find("}", i + 3)
                if end != -1:
                    try:
                        out.append(chr(int(s[i + 3:end], 16)))
                    except ValueError:
                        pass
                    i = end + 1
                    continue
            out.append({"n": "\n", "t": "\t", "r": "\r", "0": "\0"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return None, i


def _quoted_after(msg, prefix):
    if not msg.startswith(prefix):
        return None
    text, _ = _rust_str(msg, msg.find('"', len(prefix)))
    return text


def _ts(stamp):
    """Voxtype's UTC log stamp (2026-10-01T01:52:57.949117) as epoch seconds."""
    head, _, frac = stamp.partition(".")
    return calendar.timegm(time.strptime(head, "%Y-%m-%dT%H:%M:%S")) + (float("0." + frac) if frac else 0.0)


def parse_log(text):
    """Pull one dictation's stages and timestamps out of the chunk log."""
    rec = {"chunks": [], "raw": None, "input": None, "final": None, "t": {}, "audio_seconds": None}
    for line in text.splitlines():
        m = STAMP.match(ANSI.sub("", line).strip())
        if not m:
            continue
        ts, msg = _ts(m.group(1)), m.group(2)
        t = rec["t"]
        if msg.startswith("Received SIGUSR2"):
            t["stop"] = ts
        elif msg.startswith("Eager recording stopped"):
            n = re.search(r"\(([\d.]+)s\)", msg)
            if n:
                rec["audio_seconds"] = float(n.group(1))
            t.setdefault("stop", ts)
        elif re.match(r"Chunk \d+ completed", msg):
            c = _rust_str(msg, msg.find('"'))[0] if '"' in msg else msg.split(":", 1)[-1].strip()
            if c is not None:
                rec["chunks"].append(c)
        elif msg.startswith("Tail transcription:"):
            t["tail"] = ts
        elif msg.startswith("Transcribed:"):
            rec["raw"] = _quoted_after(msg, "Transcribed:")
            t["asr"] = ts
        elif msg.startswith("Post-processing input:"):
            rec["input"] = _quoted_after(msg, "Post-processing input:")
            t["cleanup_start"] = ts
        elif msg.startswith("Post-processed result:"):
            rec["final"] = _quoted_after(msg, "Post-processed result:")
            t["cleanup_end"] = ts
        elif msg.startswith("wrote transcription"):
            t["written"] = ts
    return rec


def _secure_dir():
    os.makedirs(DIR, mode=0o700, exist_ok=True)
    os.chmod(DIR, 0o700)


def _records():
    try:
        names = sorted(n for n in os.listdir(DIR) if n.endswith(".json"))
    except OSError:
        return []
    return [os.path.join(DIR, n) for n in names]


def purge_expired(now=None):
    now = now or time.time()
    for p in _records():
        try:
            if now - os.stat(p).st_mtime > EXPIRE_SECONDS:
                os.remove(p)
        except OSError:
            pass
    try:
        if now - os.stat(ARMED).st_mtime > EXPIRE_SECONDS:
            os.remove(ARMED)
    except OSError:
        pass


def remaining():
    try:
        return max(0, int(open(ARMED).read().strip() or 0))
    except (OSError, ValueError):
        return 0


def start(n):
    _secure_dir()
    purge_expired()
    fd = os.open(ARMED, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(str(int(n)))


def stop():
    try:
        os.remove(ARMED)
    except OSError:
        pass


def clear():
    stop()
    for p in _records():
        try:
            os.remove(p)
        except OSError:
            pass


def capture(delivered_at, paste_ms=None, pasted_text=None):
    """Called by omavoice-output after each delivered dictation. Saves a
    record when the trace is armed; returns True when it did."""
    purge_expired()
    left = remaining()
    if left <= 0:
        return False
    try:
        log = open(DAEMON_LOG, encoding="utf-8", errors="replace").read()
    except OSError:
        log = ""
    rec = parse_log(log)
    t = rec.pop("t")
    stop_t = t.get("stop")
    rec["ms_after_release"] = {
        k: round((t[k] - stop_t) * 1000) for k in ("tail", "asr", "cleanup_start", "cleanup_end", "written") if stop_t and k in t
    }
    if stop_t:
        rec["ms_after_release"]["pasted"] = round((delivered_at - stop_t) * 1000)
    if paste_ms is not None:
        rec["paste_ms"] = round(paste_ms)
    # The log can miss a stage (a short recording without the debug line);
    # mark it missing instead of guessing it from another stage.
    for k in ("raw", "input", "final"):
        if rec[k] is None:
            rec[k + "_missing"] = True
    if rec["final"] is None and pasted_text is not None:
        rec["final"] = pasted_text
        rec["final_from"] = "pasted text"
    rec["time"] = time.time()
    _secure_dir()
    name = os.path.join(DIR, "%d.json" % time.time_ns())
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False, indent=1)
    for old in _records()[:-MAX_RECORDS]:
        os.remove(old)
    if left - 1 > 0:
        fd = os.open(ARMED, os.O_WRONLY | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(str(left - 1))
    else:
        stop()
    return True


def load():
    out = []
    for p in _records():
        try:
            out.append(json.load(open(p, encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            pass
    return out


def word_diff(a, b):
    """Words removed as [-x-], added as {+x+}; unchanged words as is."""
    aw, bw = (a or "").split(), (b or "").split()
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(a=aw, b=bw, autojunk=False).get_opcodes():
        if op == "equal":
            out.extend(aw[i1:i2])
        if op in ("delete", "replace"):
            out.append("[-" + " ".join(aw[i1:i2]) + "-]")
        if op in ("insert", "replace"):
            out.append("{+" + " ".join(bw[j1:j2]) + "+}")
    return " ".join(out)


def changed_words(a, b):
    """(removed, added) word counts between two stages, ignoring case and
    punctuation, so only real wording changes count."""
    norm = lambda s: [re.sub(r"[^\w']", "", w.lower()) for w in (s or "").split()]
    aw, bw = [w for w in norm(a) if w], [w for w in norm(b) if w]
    removed = added = 0
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(a=aw, b=bw, autojunk=False).get_opcodes():
        if op in ("delete", "replace"):
            removed += i2 - i1
        if op in ("insert", "replace"):
            added += j2 - j1
    return removed, added
