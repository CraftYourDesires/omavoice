#!/usr/bin/env python3
"""omavoice-output end to end: Voxtype's file-mode output to the focused app.

Runs the real bin/omavoice-output against a scratch runtime folder and
replays exactly what Voxtype 1.0.1 does in file mode: the state file goes
recording -> transcribing -> idle, the transcript is written through a temp
file and renamed, then the .done sidecar the same way. A stand-in for the
focused app reads the clipboard on "paste". Checks that each dictation is
pasted once, saved to history once with its recording time, the RAM files are
removed, the clipboard comes back, and the log has no dictation text.

--with-window adds a real paste: a throwaway foot window running cat gets the
text through wtype and Shift+Insert, exactly like a dictation into a terminal.
Your clipboard is saved and restored around everything (tests/clipguard.py).
"""
import json
import os
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


def atomic(path, text):
    tmp = os.path.join(os.path.dirname(path), f".{os.path.basename(path)}.{os.getpid()}.tmp")
    with open(tmp, "w") as f:
        f.write(text)
    os.rename(tmp, path)


class Voxtype:
    """Writes the runtime files the way Voxtype's daemon does in file mode."""
    def __init__(self, runtime):
        self.dir = runtime
        self.out = os.path.join(runtime, "omavoice-output.txt")
        self.state = os.path.join(runtime, "state")

    def set_state(self, s):
        with open(self.state, "w") as f:
            f.write(s)

    def dictate(self, text, seconds, status="ok"):
        self.set_state("recording")
        time.sleep(seconds)
        self.set_state("transcribing")
        time.sleep(0.15)
        if status == "ok":
            atomic(self.out, text + "\n")
        atomic(self.out + ".done", json.dumps({"status": status, "chars": len(text) if status == "ok" else 0}) + "\n")
        self.set_state("idle")


def wait_for(fn, timeout=6.0):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.05)
    return fn()


def history(data):
    p = os.path.join(data, "history.jsonl")
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []


def run(work, with_window):
    runtime, data, config = (os.path.join(work, d) for d in ("voxtype", "data", "config"))
    for d in (runtime, config):
        os.makedirs(d)
    with open(os.path.join(config, "config.toml"), "w") as f:
        f.write('[output]\nmode = "file"\npaste_keys = "shift+insert"\n')
    got = os.path.join(work, "pasted")
    reader = f"wl-paste --no-newline --type text/plain >> {got}; printf '\\n<END>\\n' >> {got}"
    env = dict(os.environ, OMAVOICE_OUTPUT_FILE=os.path.join(runtime, "omavoice-output.txt"), OMAVOICE_DATA_DIR=data,
               OMAVOICE_CONFIG_DIR=config, OMAVOICE_CLIPBOARD_BIN=cg.HELPER, OMAVOICE_PASTE_CMD=reader, OMAVOICE_NO_NOTIFY="1")
    vt = Voxtype(runtime)
    vt.set_state("idle")

    # A dictation that finished while the service was down, a minute ago.
    atomic(vt.out, "Synthetic stale dictation from before the service started.\n")
    atomic(vt.out + ".done", '{"status":"ok","chars":58}\n')
    old = time.time() - 60
    os.utime(vt.out + ".done", (old, old))

    original = [("text/plain;charset=utf-8", b"synthetic clipboard before dictating"), ("text/html", b"<i>synthetic</i>"),
                ("application/x-omavoice-test", os.urandom(4096)), (cg.HINT, b"secret")]
    cg.load(cg.pack(original))
    log = open(os.path.join(work, "service.log"), "w")
    svc = subprocess.Popen([os.path.join(REPO, "bin", "omavoice-output")], env=env, stderr=log, stdout=log)
    try:
        time.sleep(0.8)
        h = history(data)
        check("a stale dictation found at startup is saved to history", len(h) == 1 and h[0]["text"].startswith("Synthetic stale"))
        check("but not pasted into whatever has focus now", not os.path.exists(got))
        check("and its RAM files are removed", not os.path.exists(vt.out) and not os.path.exists(vt.out + ".done"))

        first = "First synthetic dictation.\nIt has two lines, café and all."
        vt.dictate(first, 1.6)
        pasted = wait_for(lambda: os.path.exists(got) and "<END>" in open(got).read())
        check("dictation reaches the focused app", pasted and open(got).read() == first + "\n<END>\n")
        h = wait_for(lambda: len(history(data)) == 2 and history(data))
        e = h[-1] if h else {}
        check("saved to history once, exactly as pasted", len(h) == 2 and e.get("text") == first)
        check("recording time is measured from Voxtype's state", abs(e.get("seconds", 0) - 1.6) < 0.25, f"{e.get('seconds')} s")
        check("words per minute from words and recording time", e.get("words") == 10 and abs(e.get("wpm", 0) - 10 / e.get("seconds", 1) * 60) < 0.2,
              f"{e.get('words')} words, {e.get('wpm')} wpm")
        check("transcript and sidecar removed from RAM", wait_for(lambda: not os.path.exists(vt.out) and not os.path.exists(vt.out + ".done"), 2))
        time.sleep(0.3)
        check("your clipboard is back after the paste", cg.digest(cg.unpack(cg.dump())) == cg.digest(original))

        second = "Second synthetic dictation, a short one."
        vt.dictate(second, 1.2)
        wait_for(lambda: open(got).read().count("<END>") == 2)
        h = wait_for(lambda: len(history(data)) == 3 and history(data))
        check("each dictation is pasted once", open(got).read() == first + "\n<END>\n" + second + "\n<END>\n")
        check("and stored once, no duplicates or partial chunks", [x["text"] for x in history(data)][1:] == [first, second])

        vt.dictate("", 0.6, status="empty")
        vt.dictate("", 0.6, status="error")
        time.sleep(0.8)
        check("empty and failed transcriptions paste and store nothing", len(history(data)) == 3 and open(got).read().count("<END>") == 2)

        subprocess.run([os.path.join(REPO, "bin", "omavoice-store"), "set", "history", "false"], env=env, check=True, stdout=subprocess.DEVNULL)
        before = json.load(open(os.path.join(data, "stats.json")))
        third = "Third synthetic dictation while history is off."
        vt.dictate(third, 1.0)
        wait_for(lambda: open(got).read().count("<END>") == 3)
        time.sleep(0.3)
        after = json.load(open(os.path.join(data, "stats.json")))
        today = max(after["days"])
        check("with history off it still pastes", open(got).read().count("<END>") == 3)
        check("stores no text", len(history(data)) == 3)
        check("but counts the words", after["days"][today]["words"] == before["days"].get(today, {}).get("words", 0) + 7)
        subprocess.run([os.path.join(REPO, "bin", "omavoice-store"), "set", "history", "true"], env=env, check=True, stdout=subprocess.DEVNULL)

        # Restart the service between Voxtype writes: the next one still lands.
        svc.terminate()
        svc.wait(5)
        svc = subprocess.Popen([os.path.join(REPO, "bin", "omavoice-output")], env=env, stderr=log, stdout=log)
        time.sleep(0.6)
        fourth = "Fourth synthetic dictation after a service restart."
        vt.dictate(fourth, 1.0)
        check("works after a service restart", wait_for(lambda: open(got).read().count("<END>") == 4) and history(data)[-1]["text"] == fourth)

        svc.terminate()
        svc.wait(5)
        if with_window:
            real_paste(work, env, vt, data)
    finally:
        if svc.poll() is None:
            svc.terminate()
            svc.wait(5)
        log.close()
    # Words that only occur in the dictated texts, never in log messages.
    words = {"Synthetic", "synthetic", "café", "First", "Second", "Third", "Fourth", "stale", "restart", "lines", "short"}
    text = open(os.path.join(work, "service.log")).read()
    leaked = sorted(w for w in words if w in text)
    check("the service log has no dictation text", not leaked, f"{len(text.splitlines())} log lines" + (f", found {leaked}" if leaked else ""))
    check("history file is owner only", oct(os.stat(os.path.join(data, "history.jsonl")).st_mode & 0o777) == "0o600")


def real_paste(work, env, vt, data):
    """A real Shift+Insert through wtype into a foot window running cat."""
    sink = os.path.join(work, "foot-received")
    env = dict(env)
    env.pop("OMAVOICE_PASTE_CMD")
    focused = json.loads(subprocess.run(["hyprctl", "activewindow", "-j"], capture_output=True, text=True).stdout or "{}").get("address")
    foot = subprocess.Popen(["foot", "--app-id", "omavoice-paste-test", "sh", "-c", f"stty -echo -icanon min 1; exec cat > {sink}"])
    try:
        ok = wait_for(lambda: json.loads(subprocess.run(["hyprctl", "activewindow", "-j"], capture_output=True, text=True).stdout or "{}")
                      .get("class") == "omavoice-paste-test", 5)
        check("real paste: a test terminal has focus", ok)
        time.sleep(0.4)
        svc = subprocess.Popen([os.path.join(REPO, "bin", "omavoice-output")], env=env, stderr=subprocess.DEVNULL)
        time.sleep(0.6)
        original = [("text/plain;charset=utf-8", b"synthetic clipboard before the real paste"), (cg.HINT, b"secret")]
        cg.load(cg.pack(original))
        text = "Real paste into a terminal.\nSecond line."
        vt.dictate(text, 0.8)
        got = wait_for(lambda: os.path.exists(sink) and open(sink).read().count("\n") >= 1 and "Second line" in open(sink).read(), 6)
        time.sleep(0.4)
        received = open(sink).read() if os.path.exists(sink) else ""
        check("real paste: wtype + Shift+Insert delivers the text to the terminal", received.startswith("Real paste into a terminal.\nSecond line"),
              f"{len(received)} bytes")
        time.sleep(0.3)
        check("real paste: clipboard restored afterwards", cg.digest(cg.unpack(cg.dump())) == cg.digest(original))
        check("real paste: stored in history once", [x["text"] for x in history(data)].count(text) == 1)
        svc.terminate()
        svc.wait(5)
    finally:
        foot.terminate()
        foot.wait(5)
        if focused:
            subprocess.run(["hyprctl", "dispatch", f'hl.dsp.focus({{ window = "address:{focused}" }})'], capture_output=True)


if __name__ == "__main__":
    work = tempfile.mkdtemp(prefix="omavoice-output.", dir=cg.RUNTIME)
    with cg.ClipboardGuard() as guard:
        try:
            run(work, "--with-window" in sys.argv)
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"FAIL  test crashed: {type(e).__name__}")
    if os.environ.get("KEEP_LOG"):
        print(open(os.path.join(work, "service.log")).read())
    shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if failed or getattr(guard, "failed", False) else 0)
