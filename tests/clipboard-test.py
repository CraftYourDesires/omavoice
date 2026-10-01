#!/usr/bin/env python3
"""Clipboard non-clobber test for omavoice-clipboard, on the live session.

Each case sets a synthetic clipboard, pastes a synthetic dictation with a
stand-in for the focused app (a command that reads the clipboard the way an
app does on Shift+Insert), and checks that:
  - the app received exactly the dictation text
  - the previous clipboard came back with every type, byte for byte
  - clipboard history watchers were told to skip the dictation offer
Your own clipboard is saved first and restored at the end (tests/clipguard.py).
No clipboard or dictation content is printed.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clipguard as cg  # noqa: E402

failed = 0


def check(name, ok, detail=""):
    global failed
    failed += not ok
    print(("PASS" if ok else "FAIL") + "  " + name + (f"  ({detail})" if detail else ""))


def paste(text, reader, extra=()):
    r = subprocess.run([cg.HELPER, "paste", *extra, "--paste-cmd", reader], input=text.encode(),
                       capture_output=True, timeout=20)
    return r.returncode, json.loads(r.stdout.decode().strip().splitlines()[-1])


def run():
    work = tempfile.mkdtemp(prefix="omavoice-clip.", dir=cg.RUNTIME)
    got = os.path.join(work, "got")
    seen_types = os.path.join(work, "types")
    reader = f"{cg.HELPER} types > {seen_types}; wl-paste --no-newline --type text/plain > {got}"
    dictation = "Synthetic dictation for the omavoice clipboard test.\nSecond line, with unicode: café ✓"

    cases = {
        "text, html and binary": [("text/plain;charset=utf-8", b"synthetic original text"), ("text/plain", b"synthetic original text"),
                                  ("text/html", b"<b>synthetic original</b>"), ("application/x-omavoice-test", os.urandom(300_000)),
                                  (cg.HINT, b"secret")],
        "image only": [("image/png", b"\x89PNG\r\n\x1a\n" + os.urandom(50_000)), (cg.HINT, b"secret")],
        "large (6 MB)": [("application/octet-stream", os.urandom(6_000_000)), ("text/plain", b"synthetic"), (cg.HINT, b"secret")],
    }
    for name, items in cases.items():
        cg.load(cg.pack(items))
        before = cg.unpack(cg.dump())
        for p in (got, seen_types):
            if os.path.exists(p):
                os.remove(p)
        code, res = paste(dictation, reader)
        received = open(got, "rb").read() if os.path.exists(got) else b""
        offered = open(seen_types).read().split() if os.path.exists(seen_types) else []
        time.sleep(0.1)
        after = cg.unpack(cg.dump())
        check(f"{name}: app received exactly the dictation", received == dictation.encode(), f"{len(received)} bytes")
        check(f"{name}: dictation offer tells history watchers to skip it", cg.HINT in offered and "text/plain" in offered)
        check(f"{name}: paste was seen being read", code == 0 and res["read_by_app"] and res["reads"] >= 1, f"{res['reads']} reads")
        check(f"{name}: previous clipboard restored with all {len(items)} types, byte for byte",
              res["restored"] and cg.digest(after) == cg.digest(before) == cg.digest(items),
              f"types {len(after)}, snapshot {res['snapshot_ms']} ms")

    # An empty clipboard stays empty, instead of keeping the dictation.
    cg.load(cg.pack([]))
    code, res = paste(dictation, reader)
    check("empty clipboard: app received the dictation", open(got, "rb").read() == dictation.encode())
    check("empty clipboard: left empty afterwards", cg.types() == [] and not res["had_clipboard"], f"types {cg.types()}")

    # No app takes the paste (no text box focused): restored after the wait.
    items = [("text/plain", b"synthetic keep me"), (cg.HINT, b"secret")]
    cg.load(cg.pack(items))
    t = time.monotonic()
    code, res = paste(dictation, "true", ("--wait-ms", "700"))
    took = time.monotonic() - t
    check("nobody reads: reported as not read", not res["read_by_app"])
    check("nobody reads: clipboard restored after the wait", res["restored"] and cg.digest(cg.unpack(cg.dump())) == cg.digest(items),
          f"{took:.2f}s")

    # Something else copies while the paste is in flight: its copy wins.
    newer = [("text/plain", b"synthetic newer copy"), (cg.HINT, b"secret")]
    newer_file = os.path.join(work, "newer")
    open(newer_file, "wb").write(cg.pack(newer))
    cg.load(cg.pack(items))
    code, res = paste(dictation, f"wl-paste -n -t text/plain >/dev/null; {cg.HELPER} load < {newer_file} >/dev/null")
    time.sleep(0.1)
    check("newer copy during paste: not overwritten by the restore",
          res["clipboard_changed"] and not res["restored"] and cg.digest(cg.unpack(cg.dump())) == cg.digest(newer))

    # The reader is fast, so the helper returns well before its 2 s timeout.
    cg.load(cg.pack(items))
    t = time.monotonic()
    code, res = paste(dictation, reader)
    took = time.monotonic() - t
    check("restore follows the app's read, not a fixed long delay", took < 1.2, f"{took:.2f}s end to end")

    # Real key names map to wtype arguments (no keystroke sent: bad keys fail early).
    r = subprocess.run([cg.HELPER, "paste", "--keys", "hyper+q"], input=b"x", capture_output=True, timeout=10)
    check("unknown modifier in paste keys is rejected before touching the clipboard", r.returncode == 2 and b"bad-keys" in r.stdout)

    for p in os.listdir(work):
        os.remove(os.path.join(work, p))
    os.rmdir(work)


if __name__ == "__main__":
    with cg.ClipboardGuard() as guard:
        try:
            run()
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"FAIL  test crashed: {type(e).__name__}")
    sys.exit(1 if failed or getattr(guard, "failed", False) else 0)
