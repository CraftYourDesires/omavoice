"""Private dictation history, word statistics and omavoice settings.

Shared by bin/omavoice-output (saves each finished dictation), bin/omavoice-store
(the command line the omavoice app calls) and the tests.

History lives in ~/.local/share/omavoice/history.jsonl, one JSON object per
dictation, readable only by you (directory 0700, files 0600). Statistics live
next to it in stats.json as per-day totals with no text, so clearing or
turning off history keeps your word counts. Nothing here ever logs text.

Env overrides (tests): OMAVOICE_DATA_DIR, OMAVOICE_CONFIG_DIR.
"""
import contextlib
import datetime as dt
import fcntl
import json
import os
import re
import shutil
import struct
import subprocess
import time
import tomllib
import uuid

DATA_DIR = os.path.expanduser(os.environ.get("OMAVOICE_DATA_DIR", "~/.local/share/omavoice"))
CONFIG_DIR = os.path.expanduser(os.environ.get("OMAVOICE_CONFIG_DIR", "~/.config/voxtype"))
HISTORY_PATH = os.path.join(DATA_DIR, "history.jsonl")
STATS_PATH = os.path.join(DATA_DIR, "stats.json")
LOCK_PATH = os.path.join(DATA_DIR, ".lock")
SETTINGS_PATH = os.path.join(CONFIG_DIR, "omavoice.toml")

STYLES = ("neon", "trace", "scope", "clip", "glass", "bezel", "depth")
RETENTION_CHOICES = (0, 1, 7, 30, 90, 365)  # days, 0 = forever
DEFAULTS = {
    "overlay": True,
    "overlay_position": "top",
    "overlay_style": "neon",
    "history": True,
    "history_days": 30,
    "notify_unpasted": True,
}
SETTING_TYPES = {
    "overlay": bool,
    "overlay_position": ("top", "bottom"),
    "overlay_style": STYLES,
    "history": bool,
    "history_days": RETENTION_CHOICES,
    "notify_unpasted": bool,
}
# The same dictation seen twice this close together is one dictation.
DEDUP_SECONDS = 2.0
# Recordings shorter than this give meaningless words per minute.
MIN_TIMED_SECONDS = 1.0

# A word is a run of letters or digits, optionally joined by an apostrophe,
# hyphen, period or slash inside it: don't, e-mail, 3.5, U.S, n8n and
# gemma4:e4b's parts all count once each. Punctuation, list dashes and
# emoji do not count.
WORD_RE = re.compile(r"[^\W_]+(?:['’.\-/][^\W_]+)*", re.UNICODE)


def count_words(text):
    return len(WORD_RE.findall(text or ""))


# ---------------------------------------------------------------- files

def _private_dir():
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
    os.chmod(DATA_DIR, 0o700)


@contextlib.contextmanager
def _locked():
    _private_dir()
    fd = os.open(LOCK_PATH, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _write_private(path, data):
    """Atomically replace path with data (str), mode 0600."""
    tmp = f"{path}.{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.remove(tmp)
        raise


def _read_history():
    try:
        with open(HISTORY_PATH, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return []
    out = []
    for line in lines:
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(e, dict) and isinstance(e.get("text"), str) and e.get("id"):
            out.append(e)
    return out


def _write_history(entries):
    _write_private(HISTORY_PATH, "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in entries))


def _read_stats():
    try:
        with open(STATS_PATH, encoding="utf-8") as f:
            s = json.load(f)
        if isinstance(s, dict) and isinstance(s.get("days"), dict):
            return s
    except (OSError, json.JSONDecodeError):
        pass
    return {"version": 1, "days": {}}


# ---------------------------------------------------------------- settings

def settings():
    """omavoice.toml merged over the defaults."""
    out = dict(DEFAULTS)
    try:
        with open(SETTINGS_PATH, "rb") as f:
            raw = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError):
        raw = {}
    for k, v in raw.items():
        out[k] = v
    if out.get("overlay_style") not in STYLES:
        out["overlay_style"] = DEFAULTS["overlay_style"]
    try:
        out["history_days"] = max(0, int(out.get("history_days", 30)))
    except (TypeError, ValueError):
        out["history_days"] = DEFAULTS["history_days"]
    return out


def parse_setting(key, value):
    kind = SETTING_TYPES.get(key)
    if kind is None:
        raise ValueError(f"unknown setting {key}")
    if kind is bool:
        v = str(value).strip().lower()
        if v in ("true", "1", "on", "yes"):
            return True
        if v in ("false", "0", "off", "no"):
            return False
        raise ValueError(f"{key} takes true or false")
    if all(isinstance(c, int) for c in kind):
        try:
            n = int(value)
        except ValueError:
            raise ValueError(f"{key} takes one of {', '.join(map(str, kind))}") from None
        if n not in kind:
            raise ValueError(f"{key} takes one of {', '.join(map(str, kind))}")
        return n
    if value not in kind:
        raise ValueError(f"{key} takes one of {', '.join(kind)}")
    return value


def _toml_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    return json.dumps(v)


def set_setting(key, value):
    """Set one key in omavoice.toml in place, keeping every other line and
    comment as it is. A commented-out example line (# key = ...) is replaced;
    otherwise the key is appended."""
    v = parse_setting(key, value)
    line = f"{key} = {_toml_value(v)}"
    try:
        with open(SETTINGS_PATH, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        text = ""
    lines = text.split("\n")
    # Only top-level keys: stop at the first [table].
    end = next((i for i, l in enumerate(lines) if re.match(r"^\s*\[", l)), len(lines))
    active = re.compile(rf"^\s*{re.escape(key)}\s*=")
    commented = re.compile(rf"^\s*#\s*{re.escape(key)}\s*=")
    idx = next((i for i in range(end) if active.match(lines[i])), None)
    if idx is None:
        idx = next((i for i in range(end) if commented.match(lines[i])), None)
    if idx is not None:
        lines[idx] = line
    else:
        at = end
        while at > 0 and lines[at - 1].strip() == "":
            at -= 1
        lines.insert(at, line)
    new = "\n".join(lines)
    if not new.endswith("\n"):
        new += "\n"
    os.makedirs(CONFIG_DIR, exist_ok=True)
    mode = 0o644
    with contextlib.suppress(OSError):
        mode = os.stat(SETTINGS_PATH).st_mode & 0o777
    tmp = f"{SETTINGS_PATH}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new)
    os.chmod(tmp, mode)
    os.replace(tmp, SETTINGS_PATH)
    if key == "history_days":
        prune()
    return v


# ---------------------------------------------------------------- history

def add(text, seconds=None, app="", source_key=""):
    """Record one finished dictation. Returns the entry id, or "" when the
    text is empty. Stats are always updated; the text is kept only while
    history is on. The same dictation delivered twice (same source_key, or
    the same text within DEDUP_SECONDS) is stored once."""
    text = (text or "").strip()
    if not text:
        return ""
    now = time.time()
    words = count_words(text)
    timed = seconds is not None and seconds >= MIN_TIMED_SECONDS
    cfg = settings()
    with _locked():
        entries = _read_history()
        for e in reversed(entries[-20:]):
            if source_key and e.get("source") == source_key:
                return e["id"]
            if e["text"] == text and now - float(e.get("t", 0)) < DEDUP_SECONDS:
                return e["id"]
        stats = _read_stats()
        last = stats.get("last") or {}
        if (source_key and last.get("source") == source_key) or (
                last.get("words") == words and last.get("len") == len(text) and now - float(last.get("t", 0)) < DEDUP_SECONDS):
            return last.get("id", "")
        entry_id = uuid.uuid4().hex[:12]
        day = dt.date.fromtimestamp(now).isoformat()
        d = stats["days"].setdefault(day, {"dictations": 0, "words": 0, "timed_words": 0, "seconds": 0.0})
        d["dictations"] += 1
        d["words"] += words
        if timed:
            d["timed_words"] += words
            d["seconds"] = round(d["seconds"] + seconds, 3)
        # Only lengths, never text, for the duplicate check.
        stats["last"] = {"id": entry_id, "t": now, "words": words, "len": len(text), "source": source_key}
        _write_private(STATS_PATH, json.dumps(stats, indent=1, sort_keys=True) + "\n")
        if cfg["history"]:
            entry = {"id": entry_id, "t": round(now, 3), "text": text, "words": words}
            if timed:
                entry["seconds"] = round(seconds, 2)
                entry["wpm"] = round(words / seconds * 60, 1)
            if app:
                entry["app"] = app[:80]
            if source_key:
                entry["source"] = source_key
            entries.append(entry)
            entries = _pruned(entries, cfg["history_days"], now)
            _write_history(entries)
        return entry_id


def _pruned(entries, days, now=None):
    if not days:
        return entries
    cutoff = (now or time.time()) - days * 86400
    return [e for e in entries if float(e.get("t", 0)) >= cutoff]


def prune():
    """Drop entries older than history_days. Returns how many went."""
    days = settings()["history_days"]
    with _locked():
        entries = _read_history()
        keep = _pruned(entries, days)
        if len(keep) != len(entries) or not os.path.exists(HISTORY_PATH):
            _write_history(keep)
        return len(entries) - len(keep)


def entries():
    with _locked():
        return _read_history()


def get(entry_id):
    for e in entries():
        if e["id"] == entry_id:
            return e
    return None


def delete(entry_id):
    with _locked():
        items = _read_history()
        keep = [e for e in items if e["id"] != entry_id]
        if len(keep) != len(items):
            _write_history(keep)
        return len(items) - len(keep)


def clear():
    with _locked():
        n = len(_read_history())
        _write_history([])
        return n


TEXT_TYPES = ("text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT")
REPO_HELPER = os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "build", "omavoice-clipboard")


def clipboard_helper():
    for c in (os.environ.get("OMAVOICE_CLIPBOARD_BIN"), shutil.which("omavoice-clipboard"), REPO_HELPER):
        if c and os.access(c, os.X_OK):
            return c
    return None


def pack_snapshot(items):
    """omavoice-clipboard's snapshot format: [(mime, bytes), ...]."""
    out = b"OMVCLIP1\n" + struct.pack("<I", len(items))
    for mime, data in items:
        out += mime.encode() + b"\0" + struct.pack("<Q", len(data)) + data
    return out


def copy(entry_id):
    """Put one entry on the clipboard (the only way history touches it),
    offered under every common text type so any app can paste it. The text
    goes over stdin, never on a command line. OMAVOICE_COPY_HINT=1 (tests)
    also marks it so clipboard history watchers skip it."""
    e = get(entry_id)
    if not e:
        return False
    data = e["text"].encode()
    helper = clipboard_helper()
    if helper:
        items = [(m, data) for m in TEXT_TYPES]
        if os.environ.get("OMAVOICE_COPY_HINT"):
            items.append(("x-kde-passwordManagerHint", b"secret"))
        r = subprocess.run([helper, "load"], input=pack_snapshot(items), stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=5)
        if r.returncode == 0:
            return True
    r = subprocess.run(["wl-copy", "--type", "text/plain;charset=utf-8"], input=data,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    return r.returncode == 0


# ---------------------------------------------------------------- stats

def _sum(days):
    s = {"dictations": 0, "words": 0, "timed_words": 0, "seconds": 0.0}
    for d in days:
        for k in s:
            s[k] += d.get(k, 0)
    s["seconds"] = round(s["seconds"], 1)
    s["wpm"] = round(s["timed_words"] / s["seconds"] * 60, 1) if s["seconds"] >= MIN_TIMED_SECONDS else None
    return s


def stats(today=None):
    today = today or dt.date.today()
    raw = _read_stats()["days"]
    def span(n):
        return [raw.get((today - dt.timedelta(days=i)).isoformat(), {}) for i in range(n)]
    daily = []
    for i in range(13, -1, -1):
        day = (today - dt.timedelta(days=i)).isoformat()
        d = _sum([raw.get(day, {})])
        d["date"] = day
        daily.append(d)
    return {
        "today": _sum(span(1)),
        "week": _sum(span(7)),
        "month": _sum(span(30)),
        "all": _sum(raw.values()),
        "daily": daily,
        "active_days": sum(1 for d in raw.values() if d.get("dictations")),
    }


def reset_stats():
    with _locked():
        _write_private(STATS_PATH, json.dumps({"version": 1, "days": {}}) + "\n")


# ---------------------------------------------------------------- voxtype

OLD_OUTPUT_COMMENT = """# Paste the whole dictation at once (like Wispr Flow) instead of typing it
# character by character. Shift+Insert pastes in terminals and normal apps alike.
# The dictation stays on the clipboard afterwards (restore_clipboard = false),
# so it is never lost when no text box has focus."""

NEW_OUTPUT_COMMENT = """# Voxtype writes the finished dictation to a file in RAM ($XDG_RUNTIME_DIR)
# and omavoice-output pastes it with paste_keys (Shift+Insert pastes in
# terminals and normal apps alike). Your clipboard is put back afterwards with
# all its formats, and every dictation is kept in the omavoice app's private
# history, so nothing is lost when no text box has focus."""


def output_file():
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "voxtype", "omavoice-output.txt")


def configure_voxtype_output(path, out_file=None):
    """Point Voxtype's [output] at file mode for omavoice-output, in place.
    Only mode, file_path and file_mode change; everything else in the file
    (paste_keys, replacements, comments) stays. Returns True when changed."""
    out_file = out_file or output_file()
    with open(path, encoding="utf-8") as f:
        text = f.read()
    new = text.replace(OLD_OUTPUT_COMMENT, NEW_OUTPUT_COMMENT)
    lines = new.split("\n")
    start = next((i for i, l in enumerate(lines) if l.strip() == "[output]"), None)
    if start is None:
        lines += ["", "[output]"]
        start = len(lines) - 1
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"^\s*\[", lines[i])), len(lines))
    wanted = {"mode": '"file"', "file_path": json.dumps(out_file), "file_mode": '"overwrite"'}
    seen = set()
    for i in range(start + 1, end):
        m = re.match(r"^(\s*)(mode|file_path|file_mode)\s*=", lines[i])
        if m:
            lines[i] = f"{m.group(1)}{m.group(2)} = {wanted[m.group(2)]}"
            seen.add(m.group(2))
    at = next((i + 1 for i in range(start + 1, end) if re.match(r"^\s*mode\s*=", lines[i])), start + 1)
    for key in ("mode", "file_path", "file_mode"):
        if key not in seen:
            lines.insert(at, f"{key} = {wanted[key]}")
            at += 1
    # The omavoice.overlay plugin replaces Voxtype's own waveform OSD; with
    # both on, two animations show while you talk.
    if not any(l.strip() == "[osd]" for l in lines):
        lines += ["", "# The omavoice overlay replaces Voxtype's own OSD.", "[osd]", "enabled = false"]
    new = "\n".join(lines)
    if new == text:
        return False
    with open(path + ".omavoice.tmp", "w", encoding="utf-8") as f:
        f.write(new)
    os.chmod(path + ".omavoice.tmp", os.stat(path).st_mode & 0o777)
    os.replace(path + ".omavoice.tmp", path)
    return True


def paste_keys(path=None):
    path = path or os.path.join(CONFIG_DIR, "config.toml")
    try:
        with open(path, "rb") as f:
            return str(tomllib.load(f).get("output", {}).get("paste_keys") or "shift+insert")
    except (OSError, tomllib.TOMLDecodeError):
        return "shift+insert"
