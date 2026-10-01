#!/usr/bin/env python3
"""End to end test of the omavoice app on the live desktop.

Launches the real app through bin/omavoice with synthetic data
(tests/app-fixture.py), a scratch settings folder and a scratch Omarchy theme
folder, so your history, dictionary, settings and theme are never read or
changed. Actions go through the app's IPC target, which calls the same
functions its buttons do; results are checked in the files, on the
clipboard (saved and restored around the test) and on screen.

Usage: tests/app-ui-test.py [--shots DIR]   (keeps real screenshots of each page)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clipguard as cg  # noqa: E402

REPO = cg.REPO
APP = os.path.join(REPO, "app")
THEMES = "/usr/share/omarchy/themes"
shots = sys.argv[sys.argv.index("--shots") + 1] if "--shots" in sys.argv else ""
failed = 0


def check(name, ok, detail=""):
    global failed
    failed += not ok
    print(("PASS" if ok else "FAIL") + "  " + name + (f"  ({detail})" if detail else ""))


def ipc(*args):
    r = subprocess.run(["qs", "-p", APP, "ipc", "call", "omavoice-app", *map(str, args)], capture_output=True, text=True, timeout=10)
    return r.stdout.strip() if r.returncode == 0 else ""


def status():
    try:
        return json.loads(ipc("status"))
    except json.JSONDecodeError:
        return {}


def until(fn, tries=60, delay=0.05):
    for _ in range(tries):
        v = fn()
        if v:
            return v
        time.sleep(delay)
    return fn()


def clients():
    return [c for c in json.loads(subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True).stdout)
            if c["class"] == "omavoice"]


def shoot(name):
    if not shots:
        return
    c = clients()[0]
    path = os.path.join(shots, name + ".png")
    subprocess.run(["grim", "-g", f"{c['at'][0]},{c['at'][1]} {c['size'][0]}x{c['size'][1]}", path], check=True)
    print(f"      captured {path}")


def grab(c):
    raw = subprocess.run(["grim", "-g", f"{c['at'][0]},{c['at'][1]} {c['size'][0]}x{c['size'][1]}", "-t", "ppm", "-"],
                         capture_output=True, check=True).stdout
    return raw


def switch_theme(state, name):
    nxt = os.path.join(state, "next-theme")
    os.makedirs(nxt, exist_ok=True)
    shutil.copy(os.path.join(THEMES, name, "colors.toml"), nxt)
    shutil.rmtree(os.path.join(state, "theme"), ignore_errors=True)
    os.rename(nxt, os.path.join(state, "theme"))
    with open(os.path.join(state, "theme.name"), "w") as f:
        f.write(name + "\n")


def run(work):
    subprocess.run([os.path.join(REPO, "tests", "app-fixture.py"), work], check=True, stdout=subprocess.DEVNULL)
    data, config = os.path.join(work, "data"), os.path.join(work, "config")
    state = os.path.join(work, "state", "omarchy", "current")
    os.makedirs(state)
    switch_theme(state, "tokyo-night")
    env = dict(os.environ, OMAVOICE_DATA_DIR=data, OMAVOICE_CONFIG_DIR=config, XDG_STATE_HOME=os.path.join(work, "state"),
               OMAVOICE_COPY_HINT="1")
    store_env = dict(os.environ, OMAVOICE_DATA_DIR=data, OMAVOICE_CONFIG_DIR=config)
    dict_before = open(os.path.join(config, "dictionary.txt")).read()

    subprocess.run([os.path.join(REPO, "bin", "omavoice")], env=env, check=True)
    check("app starts from the omavoice command", until(lambda: ipc("ping") == "ok", 80, 0.1))
    time.sleep(0.8)
    cs = clients()
    check("one window, class omavoice", len(cs) == 1, f"{len(cs)} windows")
    c = cs[0]
    check("opens floating, centered, at 1080x720", c["floating"] and c["size"] == [1080, 720], f"{c['size']} floating={c['floating']}")
    subprocess.run([os.path.join(REPO, "bin", "omavoice")], env=env, check=True)
    time.sleep(0.8)
    check("launching again focuses it instead of opening a second one", len(clients()) == 1 and clients()[0]["focusHistoryID"] == 0)

    s = status()
    check("loads the history", s.get("historyCount") == 12, str(s.get("historyCount")))
    check("loads the dictionary", s.get("dictionaryTerms") == 14, str(s.get("dictionaryTerms")))
    py = json.loads(subprocess.run([os.path.join(REPO, "bin", "omavoice-store"), "stats", "--json"], env=store_env,
                                   capture_output=True, text=True).stdout)
    check("stats match the store", s.get("todayWords") == py["today"]["words"] and s.get("weekWords") == py["week"]["words"],
          f"today {s.get('todayWords')} week {s.get('weekWords')}")
    check("uses the Omarchy font", s.get("font") == subprocess.run(["omarchy", "font", "current"], capture_output=True, text=True).stdout.strip())
    tokyo_bg = tomllib.load(open(os.path.join(THEMES, "tokyo-night", "colors.toml"), "rb"))["background"].lower()
    check("follows the (scratch) Omarchy theme", s.get("theme") == "tokyo-night" and s.get("bg", "").lower() == tokyo_bg, s.get("bg"))

    # Style page: both previews animate.
    ipc("page", "style")
    time.sleep(1.2)
    a = grab(clients()[0])
    time.sleep(0.25)
    b = grab(clients()[0])
    changed = sum(x != y for x, y in zip(a, b))
    check("style previews are animating", changed > 2000, f"{changed} bytes changed in 0.25 s")
    shoot("app-style-tokyo-night")
    ipc("pickStyle", "trace")
    ok = until(lambda: tomllib.load(open(os.path.join(config, "omavoice.toml"), "rb")).get("overlay_style") == "trace")
    check("choosing Trace writes overlay_style to omavoice.toml", ok)
    check("the app shows Trace as in use", until(lambda: status().get("style") == "trace"))
    ipc("pickStyle", "neon")
    check("switching back to Neon", until(lambda: tomllib.load(open(os.path.join(config, "omavoice.toml"), "rb")).get("overlay_style") == "neon"))
    toml_text = open(os.path.join(config, "omavoice.toml")).read()
    check("omavoice.toml keeps its name and comments", 'name = "Sam"' in toml_text and "# Recording overlay" in toml_text)

    # History: search, copy, delete, retention.
    ipc("page", "history")
    time.sleep(0.6)
    shoot("app-history")
    check("search narrows the list", ipc("search", "supabase migration") == "1")
    check("search is case-insensitive and matches apps too", int(ipc("search", "SLACK") or 0) == 3)
    ipc("search", "supabase migration")
    ipc("copyResult", 0)
    time.sleep(0.6)
    items = dict(cg.unpack(cg.dump()))
    want = [e for e in map(json.loads, open(os.path.join(data, "history.jsonl"))) if "Supabase migration" in e["text"]][0]["text"]
    check("clicking an entry copies exactly its text", items.get("text/plain;charset=utf-8", b"").decode() == want)
    check("copied under every text type", all(items.get(t) == want.encode() for t in ("text/plain", "UTF8_STRING", "STRING", "TEXT")))
    check("the app confirms the copy", status().get("copied") is True)
    ipc("search", "")
    before = status().get("historyCount")
    ipc("search", "Running five minutes late")
    ipc("deleteResult", 0)
    check("delete removes the entry", until(lambda: status().get("historyCount") == before - 1))
    check("and from the file", not any("five minutes late" in l for l in open(os.path.join(data, "history.jsonl"))))
    ipc("search", "")
    ipc("setting", "history_days", "7")
    n7 = until(lambda: status().get("historyCount") if status().get("historyCount", 99) < 11 else 0)
    check("choosing 7 days prunes older entries right away", n7 and n7 < 11, f"{n7} left")
    check("history file stays owner only", oct(os.stat(os.path.join(data, "history.jsonl")).st_mode & 0o777) == "0o600")

    # Dictionary: add a term through the editor and save.
    ipc("page", "dictionary")
    time.sleep(0.4)
    check("adding a term marks unsaved changes", ipc("addTerm", "People", "Aoife", 'coworker, misheard as "eefa"') == "ok" and status().get("dictionaryDirty") is True)
    check("bad terms are refused", ipc("addTerm", "People", "#nope", "") != "ok")
    shoot("app-dictionary")
    ipc("saveDictionary")
    after = until(lambda: (lambda t: t if "Aoife" in t else "")(open(os.path.join(config, "dictionary.txt")).read()))
    added = [l for l in after.split("\n") if l not in dict_before.split("\n")]
    check("saving writes exactly the new line", added == ['Aoife | coworker, misheard as "eefa"'], str(len(added)))
    check("every original line and comment is kept, in order", [l for l in after.split("\n") if l not in added] == dict_before.split("\n"))
    people = after.split("## People")[1].split("##")[0]
    check("the term lands in its section", "Aoife | coworker" in people)
    check("saved state shows clean", until(lambda: status().get("dictionaryDirty") is False))

    # Stats page and a live theme switch to a light theme.
    ipc("page", "stats")
    time.sleep(0.5)
    shoot("app-stats")
    loads = status().get("themeLoads", 0)
    switch_theme(state, "catppuccin-latte")
    latte_bg = tomllib.load(open(os.path.join(THEMES, "catppuccin-latte", "colors.toml"), "rb"))["background"].lower()
    check("follows a live theme switch to a light theme", until(lambda: status().get("bg", "").lower() == latte_bg, 60, 0.05), status().get("bg"))
    check("reloads the theme once per switch", status().get("themeLoads", 0) == loads + 1, f"{loads} -> {status().get('themeLoads')}")
    ipc("page", "style")
    time.sleep(0.8)
    shoot("app-style-catppuccin-latte")

    # The app's own log: no QML warnings or errors (a second Quickshell
    # instance always gets a harmless portal warning about its app ID).
    pid = int(ipc("pid") or 0)
    logf = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "quickshell", "by-pid", str(pid), "log.log")
    problems = [l for l in open(logf, errors="replace")
                if (" WARN" in l or "ERROR" in l or "TypeError" in l or "ReferenceError" in l) and "host portal" not in l] if os.path.exists(logf) else ["no log"]
    check("no warnings or errors in the app log", not problems, problems[0][:160] if problems else "")

    # Close: the process quits with its window.
    subprocess.run(["hyprctl", "dispatch", 'hl.dsp.window.close({ window = "class:^omavoice$" })'], capture_output=True)
    if os.path.exists(f"/proc/{pid}") and clients():
        subprocess.run(["hyprctl", "dispatch", "closewindow", "class:^omavoice$"], capture_output=True)
    gone = until(lambda: not os.path.exists(f"/proc/{pid}"), 60, 0.1)
    check("closing the window quits the app", gone)


if __name__ == "__main__":
    if subprocess.run(["qs", "-p", APP, "ipc", "call", "omavoice-app", "ping"], capture_output=True, text=True).stdout.strip() == "ok":
        sys.exit("close the omavoice app first; this test launches its own copy")
    if shots:
        os.makedirs(shots, exist_ok=True)
    work = tempfile.mkdtemp(prefix="omavoice-app.")
    with cg.ClipboardGuard() as guard:
        try:
            run(work)
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"FAIL  test crashed: {type(e).__name__}: {e}")
        finally:
            pid = ipc("pid")
            if pid.isdigit():
                subprocess.run(["kill", pid])
    shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if failed or getattr(guard, "failed", False) else 0)
