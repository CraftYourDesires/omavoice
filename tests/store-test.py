#!/usr/bin/env python3
"""History, stats, settings and Voxtype config tests for lib/omavoice_store.py.

Runs entirely in a scratch folder with synthetic text; your history, stats and
config are never read or changed (the Voxtype migration check works on a
scratch copy of your config and prints nothing from it).
"""
import datetime as dt
import importlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import tomllib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
work = tempfile.mkdtemp(prefix="omavoice-store.")
os.environ["OMAVOICE_DATA_DIR"] = os.path.join(work, "data")
os.environ["OMAVOICE_CONFIG_DIR"] = os.path.join(work, "config")
os.makedirs(os.environ["OMAVOICE_CONFIG_DIR"])
sys.path.insert(0, os.path.join(REPO, "lib"))
store = importlib.import_module("omavoice_store")

failed = 0


def check(name, ok, detail=""):
    global failed
    failed += not ok
    print(("PASS" if ok else "FAIL") + "  " + name + (f"  ({detail})" if detail else ""))


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


# ------------------------------------------------------------ word counts
words = {
    "": 0,
    "Hello": 1,
    "Hello, world.": 2,
    "I don't think it's ready.": 5,
    "The e-mail from U.S. staff costs 3.5 dollars.": 8,
    "- first item\n- second item": 4,
    "Ship gemma4:e4b and n8n today ✓": 6,
    "Well... um; okay?!": 3,
    "Café naïve résumé": 3,
    "path/to/file.txt": 1,
    "Omarchy’s shell": 2,
}
for text, n in words.items():
    check(f"word count {n:>2}: {text!r}", store.count_words(text) == n, f"got {store.count_words(text)}")

# ------------------------------------------------------------ history
eid = store.add("First synthetic dictation for the test.", seconds=3.0, app="foot", source_key="1:1")
e = store.entries()
check("add stores the final text once", len(e) == 1 and e[0]["text"] == "First synthetic dictation for the test.")
check("entry has words, seconds and wpm", e[0]["words"] == 6 and e[0]["seconds"] == 3.0 and e[0]["wpm"] == 120.0, json.dumps({k: e[0][k] for k in ("words", "wpm")}))
check("history folder is 0700", mode(store.DATA_DIR) == 0o700, oct(mode(store.DATA_DIR)))
check("history file is 0600", mode(store.HISTORY_PATH) == 0o600, oct(mode(store.HISTORY_PATH)))
check("stats file is 0600", mode(store.STATS_PATH) == 0o600, oct(mode(store.STATS_PATH)))
check("the same delivery twice is stored once", store.add("First synthetic dictation for the test.", 3.0, source_key="1:1") == eid and len(store.entries()) == 1)
check("the same text again within 2 s is stored once", store.add("First synthetic dictation for the test.", 3.0, source_key="2:2") == eid and len(store.entries()) == 1)
store.add("Second synthetic dictation.", seconds=0.4, source_key="3:3")
e = store.entries()
check("a different dictation is stored", len(e) == 2)
check("a recording under 1 s gets no wpm", "wpm" not in e[1] and "seconds" not in e[1])
check("empty text is not stored", store.add("   ", 2.0) == "" and len(store.entries()) == 2)
s = store.stats()
check("stats count every dictation once", s["today"]["dictations"] == 2 and s["today"]["words"] == 9, json.dumps(s["today"]))
check("wpm uses only timed dictations", s["today"]["wpm"] == 120.0 and s["today"]["timed_words"] == 6)

# Delete, clear
check("delete removes one entry", store.delete(eid) == 1 and [x["id"] for x in store.entries()] != [eid] and len(store.entries()) == 1)
check("delete of an unknown id changes nothing", store.delete("nope") == 0 and len(store.entries()) == 1)
check("clear removes every entry", store.clear() == 1 and store.entries() == [])
check("history file stays 0600 after rewrite", mode(store.HISTORY_PATH) == 0o600)
check("stats survive clearing history", store.stats()["today"]["dictations"] == 2)

# Retention
old = {"id": "old000000000", "t": time.time() - 40 * 86400, "text": "Synthetic old entry.", "words": 3}
store._write_history([old])
store.add("Fresh synthetic entry.", 2.0)
check("default retention (30 days) drops older entries on add", [x["text"] for x in store.entries()] == ["Fresh synthetic entry."])
store._write_history([old] + store.entries())
store.set_setting("history_days", "0")
check("history_days = 0 keeps everything", len(store.entries()) == 2)
store.set_setting("history_days", "7")
check("choosing a shorter retention prunes right away", len(store.entries()) == 1)

# History off: stats only
store.set_setting("history", "false")
before = store.stats()["today"]["dictations"]
store.add("Synthetic dictation while history is off.", 2.0)
check("history off stores no text", all("off" not in x["text"] for x in store.entries()))
check("history off still counts words", store.stats()["today"]["dictations"] == before + 1)
store.set_setting("history", "true")

# Stats over days
store.reset_stats()
check("reset-stats zeroes the counts", store.stats()["all"]["words"] == 0)
day = (dt.date.today() - dt.timedelta(days=3)).isoformat()
old_stats = {"version": 1, "days": {day: {"dictations": 2, "words": 100, "timed_words": 100, "seconds": 40.0}}}
store._write_private(store.STATS_PATH, json.dumps(old_stats))
s = store.stats()
check("week includes three days ago, today does not", s["week"]["words"] == 100 and s["today"]["words"] == 0 and s["week"]["wpm"] == 150.0)
check("daily series covers 14 days ending today", len(s["daily"]) == 14 and s["daily"][-1]["date"] == dt.date.today().isoformat() and s["daily"][-4]["words"] == 100)

# ------------------------------------------------------------ settings
toml = os.path.join(store.CONFIG_DIR, "omavoice.toml")
shutil.copy(os.path.join(REPO, "config", "omavoice.toml"), toml)
with open(toml) as f:
    original = f.read().replace("__NAME__", "Test").replace("__CLEANUP__", "true")
with open(toml, "w") as f:
    f.write(original)
store.set_setting("overlay_style", "trace")
store.set_setting("overlay_position", "bottom")
with open(toml) as f:
    after = f.read()
parsed = tomllib.loads(after)
check("style and position are saved", parsed["overlay_style"] == "trace" and parsed["overlay_position"] == "bottom")
kept = [l for l in original.splitlines() if not l.lstrip("# ").startswith(("overlay_style", "overlay_position", "history", "notify_unpasted"))]
check("every other line and comment is kept", all(l in after.splitlines() for l in kept))
check("name and cleanup untouched", parsed["name"] == "Test" and parsed["cleanup"] is True)
store.set_setting("overlay_style", "neon")
check("switching back rewrites the same line", tomllib.loads(open(toml).read())["overlay_style"] == "neon" and open(toml).read().count("overlay_style =") == 1)
for key, value in (("overlay_style", "sparkles"), ("history_days", "12"), ("history", "maybe"), ("rm -rf", "x")):
    try:
        store.set_setting(key, value)
        check(f"rejects {key}={value}", False)
    except ValueError:
        check(f"rejects {key}={value}", True)
cli = subprocess.run([os.path.join(REPO, "bin", "omavoice-store"), "set", "overlay_style", "trace"], capture_output=True, text=True)
check("omavoice-store set works from the command line", cli.returncode == 0 and tomllib.loads(open(toml).read())["overlay_style"] == "trace")
cli = subprocess.run([os.path.join(REPO, "bin", "omavoice-store"), "get"], capture_output=True, text=True)
check("omavoice-store get reports settings", json.loads(cli.stdout)["overlay_style"] == "trace")

# ------------------------------------------------------------ voxtype output
def migrate(src, label):
    cfg = os.path.join(work, f"{label}.toml")
    text = open(src).read().replace("__HOME__", "/home/test").replace("__RUNTIME__", "/run/user/1000")
    open(cfg, "w").write(text)
    before = tomllib.loads(text)
    changed = store.configure_voxtype_output(cfg, "/run/user/1000/voxtype/omavoice-output.txt")
    after_text = open(cfg).read()
    after = tomllib.loads(after_text)
    out = after["output"]
    check(f"{label}: [output] now writes the RAM file", out["mode"] == "file" and out["file_path"].endswith("/voxtype/omavoice-output.txt") and out["file_mode"] == "overwrite")
    same = {k: v for k, v in before.items() if k != "output"} == {k: v for k, v in after.items() if k != "output"}
    rest = {k: v for k, v in before["output"].items() if k not in ("mode", "file_path", "file_mode")} == \
        {k: v for k, v in out.items() if k not in ("mode", "file_path", "file_mode")}
    check(f"{label}: everything else (replacements, paste_keys, post_process) unchanged", same and rest)
    check(f"{label}: running it again changes nothing", not store.configure_voxtype_output(cfg, "/run/user/1000/voxtype/omavoice-output.txt"))
    check(f"{label}: paste keys still read from the config", store.paste_keys(cfg) == before["output"].get("paste_keys", "shift+insert"))


migrate(os.path.join(REPO, "config", "config.toml"), "repo template")
real = os.path.expanduser("~/.config/voxtype/config.toml")
if os.path.exists(real):
    migrate(real, "copy of your config")

shutil.rmtree(work)
sys.exit(1 if failed else 0)
