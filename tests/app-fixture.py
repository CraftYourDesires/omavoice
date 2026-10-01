#!/usr/bin/env python3
"""Build a synthetic omavoice data and config folder for app tests and
screenshots, so they never show your own history or dictionary.

Usage: tests/app-fixture.py DIR    -> DIR/data and DIR/config
Then:  OMAVOICE_DATA_DIR=DIR/data OMAVOICE_CONFIG_DIR=DIR/config qs -p app
"""
import datetime as dt
import json
import os
import shutil
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
root = sys.argv[1]
data, config = os.path.join(root, "data"), os.path.join(root, "config")
os.makedirs(data, mode=0o700, exist_ok=True)
os.makedirs(config, exist_ok=True)
os.environ["OMAVOICE_DATA_DIR"] = data
os.environ["OMAVOICE_CONFIG_DIR"] = config
sys.path.insert(0, os.path.join(REPO, "lib"))
import omavoice_store as store  # noqa: E402

with open(os.path.join(REPO, "config", "omavoice.toml")) as f:
    toml = f.read().replace("__NAME__", "Sam").replace("__CLEANUP__", "true")
with open(os.path.join(config, "omavoice.toml"), "w") as f:
    f.write(toml)
shutil.copy(os.path.join(REPO, "config", "dictionary.example.txt"), os.path.join(config, "dictionary.txt"))

# Fictional dictations over the last two weeks.
samples = [
    ("slack", "Hey Priya, the Supabase migration is done. Can you check the staging dashboard before lunch?"),
    ("foot", "Run the omavoice tests again and paste the summary into the pull request description."),
    ("obsidian", "Meeting notes\n\n- Sam owns the HubSpot import\n- Priya reviews the Hyprland keybindings\n- Ship on Friday"),
    ("firefox", "Thanks for the quick turnaround. The new layout reads much better on mobile."),
    ("Code", "Rename the config loader to load settings and make it return defaults when the file is missing."),
    ("slack", "Running five minutes late, start without me."),
    ("hey", "Hi DHH, quick question about the Omarchy theme hooks. Do they run before or after the bar reloads?"),
    ("foot", "Write a script that pulls every n8n workflow and backs it up to the repo nightly."),
    ("obsidian", "Idea: dictate the weekly review straight into the vault with the per app style for Markdown."),
    ("slack", "Sounds good."),
    ("firefox", "The Wayland clipboard keeps every format until another app takes over the selection."),
    ("Code", "Add a test that the history file is created with owner only permissions."),
]
now = time.time()
entries = []
stats = {"version": 1, "days": {}}
for i, (app, text) in enumerate(samples):
    t = now - i * 97_000 - 1800
    words = store.count_words(text)
    seconds = round(words / (2.35 + 0.25 * (i % 4)), 2)
    entries.append({"id": f"fixture{i:05d}", "t": round(t, 3), "text": text, "words": words,
                    "seconds": seconds, "wpm": round(words / seconds * 60, 1), "app": app})
    day = dt.date.fromtimestamp(t).isoformat()
    d = stats["days"].setdefault(day, {"dictations": 0, "words": 0, "timed_words": 0, "seconds": 0.0})
    # Busier days than the history shows: history keeps only a sample here.
    scale = 9 + (i * 7) % 13
    d["dictations"] += scale
    d["words"] += words * scale
    d["timed_words"] += words * scale
    d["seconds"] = round(d["seconds"] + seconds * scale, 2)
entries.sort(key=lambda e: e["t"])
store._write_history(entries)
store._write_private(store.STATS_PATH, json.dumps(stats))
print(f"{len(entries)} synthetic dictations in {data}")
