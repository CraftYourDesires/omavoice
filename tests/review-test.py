#!/usr/bin/env python3
"""Weekly dictionary review on synthetic history, dictionary and config in
scratch folders: near-miss finding, filters, ignore list, dictionary edits
and validated replacements. No model calls, never touches your files."""
import json
import os
import sys
import tempfile
import time
import tomllib

REPO = os.path.join(os.path.dirname(os.path.realpath(__file__)), "..")
tmp = tempfile.mkdtemp(prefix="omavoice-review-test.")
os.environ["OMAVOICE_DATA_DIR"] = os.path.join(tmp, "data")
os.environ["OMAVOICE_CONFIG_DIR"] = os.path.join(tmp, "config")
os.makedirs(os.environ["OMAVOICE_CONFIG_DIR"])
sys.path.insert(0, os.path.join(REPO, "lib"))
import omavoice_store as store  # noqa: E402
import omavoice_review as review  # noqa: E402

failed = 0


def check(name, ok, detail=""):
    global failed
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""))


open(review.DICT_PATH, "w").write("# test dictionary\n## Tools\nNorthwind | the CRM\nZephyrus\nAoife | coworker\n")
open(review.VOXTYPE_CONFIG, "w").write('[output]\nmode = "file"\n\n[text.replacements]\n"air table" = "Airtable"\n\n[osd]\nenabled = false\n')
for t in ("Can you open North wind and check it", "We shipped Zephyrous today, the new build is on Northwind",
          "Send it to Aoife please", "Zephyrous is fast"):
    store.add(t)
    time.sleep(0.01)

d = review.load_dictionary()
near = review.find_near(review.recent_texts(), d, english={"can", "you", "open", "and", "check", "it", "north", "wind", "we",
                                                           "shipped", "today", "the", "new", "build", "is", "on", "send", "to",
                                                           "please", "fast"})
pairs = {(s["heard"], s["term"]) for s in near}
check("finds a near miss of a dictionary term", ("Zephyrous", "Zephyrus") in pairs, pairs)
check("finds a two word split of a term", ("North wind", "Northwind") in pairs, pairs)
check("ignores phrases that already contain the term", not any("Northwind" in h for h, _ in pairs), pairs)
z = next(s for s in near if s["heard"] == "Zephyrous")
check("counts how often it was heard", z["count"] == 2, z["count"])

items = review.scan(use_model=False)
check("scan saves suggestions privately", oct(os.stat(review.SUGGESTIONS).st_mode & 0o777) == "0o600")
check("scan attaches the sentence it came from", all(s["context"] for s in items), [s["context"] for s in items])

line = review.add_to_dictionary("Zephyrus", "Zephyrous")
check("extends an existing term with a misheard hint", line == 'Zephyrus | misheard as "Zephyrous"', line)
line = review.add_to_dictionary("Northwind", "North wind")
check("keeps an existing hint and adds to it", line == 'Northwind | the CRM, misheard as "North wind"', line)
check("adding twice changes nothing", review.add_to_dictionary("Northwind", "North wind") == line)
line = review.add_to_dictionary("Quillon", "Quill on")
text = open(review.DICT_PATH).read()
check("a new term goes under its own section", review.ADDED_SECTION in text and text.rstrip().endswith('Quillon | misheard as "Quill on"'))
check("comments and other lines are untouched", text.startswith("# test dictionary\n## Tools\n") and "Aoife | coworker" in text)

check("adds a replacement", review.add_replacement("North wind", "Northwind"))
cfg = tomllib.load(open(review.VOXTYPE_CONFIG, "rb"))
check("replacement lands in [text.replacements] and the file parses",
      cfg["text"]["replacements"].get("north wind") == "Northwind" and cfg["osd"]["enabled"] is False, cfg)
check("never adds a duplicate key", review.add_replacement("NORTH WIND", "Northwind") is False)
before = open(review.VOXTYPE_CONFIG).read()
try:
    review.add_replacement('bad"', 'x\\')
except Exception:
    pass
check("config.toml stays valid whatever is added", tomllib.loads(open(review.VOXTYPE_CONFIG).read()) is not None)

items = review.scan(use_model=False)
check("handled mishearings are not suggested again", not any(s["heard"] in ("Zephyrous", "North wind") for s in items),
      [s["heard"] for s in items])
store.add("Zephyrus fans: Zephyros again")
items = review.scan(use_model=False)
s = next((s for s in items if s["heard"] == "Zephyros"), None)
check("a new form of a term is suggested", s is not None, [x["heard"] for x in items])
review.ignore(s)
check("never suggest again is remembered", not any(x["heard"] == "Zephyros" for x in review.scan(use_model=False)))
old = time.time() + 8 * 86400
check("only the last week is scanned", review.recent_texts(7, now=old) == [])
sys.exit(1 if failed else 0)
