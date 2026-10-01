#!/usr/bin/env python3
"""A real dictation through the whole installed pipeline, without speaking.

Plays tests/fixtures/check.wav (a known 9 second sentence) into a temporary
virtual microphone that is made the default source for the duration, and
runs a real `voxtype record start` / `stop`. Voxtype transcribes it, runs
dictation-cleanup, writes the result in file mode, and omavoice-output
pastes it with wtype + Shift+Insert into a throwaway foot window running cat.

Checks: the text lands in the window, matches the known sentence, is saved
to history once with its recording time, and the clipboard is put back.

It changes nothing permanently: the virtual source is removed and your
default source restored, the installed omavoice-output service is paused
and restarted, and a second copy of it keeps this test's history in a
scratch folder, so your own history and stats are untouched. Your clipboard
is saved and restored (tests/clipguard.py). Refuses to run while you dictate.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clipguard as cg  # noqa: E402

REPO = cg.REPO
failed = 0


def check(name, ok, detail=""):
    global failed
    failed += not ok
    print(("PASS" if ok else "FAIL") + "  " + name + (f"  ({detail})" if detail else ""))


def sh(*cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=kw.pop("timeout", 30), **kw)


def words(t):
    return re.findall(r"[a-z0-9']+", t.lower())


def wait_for(fn, timeout):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.1)
    return fn()


def run(work):
    sink_file = os.path.join(work, "received")
    data = os.path.join(work, "data")
    default_source = sh("pactl", "get-default-source").stdout.strip()
    modules = []
    focused = json.loads(sh("hyprctl", "activewindow", "-j").stdout or "{}").get("address")
    svc = foot = None
    try:
        sh("systemctl", "--user", "stop", "omavoice-output.service")
        env = dict(os.environ, OMAVOICE_DATA_DIR=data, OMAVOICE_NO_NOTIFY="1")
        svc = subprocess.Popen([os.path.join(REPO, "bin", "omavoice-output")], env=env, stderr=subprocess.DEVNULL)

        modules.append(sh("pactl", "load-module", "module-null-sink", "sink_name=omavoice_test_mic",
                          "sink_properties=device.description=omavoice-test-mic").stdout.strip())
        modules.append(sh("pactl", "load-module", "module-remap-source", "master=omavoice_test_mic.monitor",
                          "source_name=omavoice_test_source", "source_properties=device.description=omavoice-test-source").stdout.strip())
        sh("pactl", "set-default-source", "omavoice_test_source")
        time.sleep(0.5)

        foot = subprocess.Popen(["foot", "--app-id", "omavoice-paste-test", "sh", "-c", f"stty -echo -icanon min 1; exec cat > {sink_file}"],
                                stderr=subprocess.DEVNULL)
        check("a test terminal has focus", wait_for(lambda: json.loads(sh("hyprctl", "activewindow", "-j").stdout or "{}").get("class") == "omavoice-paste-test", 5))
        original = [("text/plain;charset=utf-8", b"synthetic clipboard before the real dictation"), ("text/html", b"<b>synthetic</b>"), (cg.HINT, b"secret")]
        cg.load(cg.pack(original))

        start = time.time()
        sh("voxtype", "record", "start")
        time.sleep(0.4)
        sh("pw-play", "--target", "omavoice_test_mic", os.path.join(REPO, "tests", "fixtures", "check.wav"), timeout=30)
        time.sleep(0.4)
        sh("voxtype", "record", "stop")
        stopped = time.time()
        got = wait_for(lambda: os.path.exists(sink_file) and os.path.getsize(sink_file) > 20 and open(sink_file).read(), 60)
        time.sleep(1.5)
        received = open(sink_file).read() if os.path.exists(sink_file) else ""
        want = words(open(os.path.join(REPO, "tests", "fixtures", "check.txt")).read())
        overlap = sum(w in set(words(received)) for w in want) / len(want)
        check("the dictation is pasted into the focused terminal", bool(got), f"{len(received)} bytes, {time.time() - stopped:.1f}s after stop")
        check("and matches the known sentence", overlap >= 0.85, f"{overlap:.0%} of its words")
        time.sleep(0.3)
        check("your clipboard (here a synthetic one) is put back", cg.digest(cg.unpack(cg.dump())) == cg.digest(original))
        hist = [json.loads(l) for l in open(os.path.join(data, "history.jsonl"))] if os.path.exists(os.path.join(data, "history.jsonl")) else []
        check("saved to history exactly once", len(hist) == 1 and hist[0]["text"].strip() == received.strip())
        secs = hist[0].get("seconds", 0) if hist else 0
        check("recording time measured (about 9.8 s of audio)", 8.5 < secs < 12, f"{secs} s, {hist[0].get('wpm') if hist else '?'} wpm")
        check("Voxtype's RAM files are gone", not os.path.exists(os.path.join(os.environ["XDG_RUNTIME_DIR"], "voxtype", "omavoice-output.txt")))
    finally:
        if sh("voxtype", "status").stdout.strip() not in ("idle", ""):
            sh("voxtype", "record", "cancel")
        if default_source:
            sh("pactl", "set-default-source", default_source)
        for m in reversed(modules):
            if m.isdigit():
                sh("pactl", "unload-module", m)
        if svc:
            svc.terminate()
            svc.wait(5)
        sh("systemctl", "--user", "start", "omavoice-output.service")
        if foot:
            foot.terminate()
            foot.wait(5)
        if focused:
            sh("hyprctl", "dispatch", f'hl.dsp.focus({{ window = "address:{focused}" }})')
    check("your default microphone is restored", sh("pactl", "get-default-source").stdout.strip() == default_source, default_source)
    check("the installed omavoice-output service is running again", sh("systemctl", "--user", "is-active", "omavoice-output.service").stdout.strip() == "active")


if __name__ == "__main__":
    if sh("voxtype", "status").stdout.strip() != "idle":
        sys.exit("Voxtype is busy; not starting a test dictation")
    work = tempfile.mkdtemp(prefix="omavoice-real.", dir=cg.RUNTIME)
    with cg.ClipboardGuard() as guard:
        try:
            run(work)
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"FAIL  test crashed: {type(e).__name__}")
    shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if failed or getattr(guard, "failed", False) else 0)
