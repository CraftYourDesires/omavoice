#!/usr/bin/env python3
"""omavoice-trace on a synthetic Voxtype log in a scratch folder: stages and
timings parsed, armed count honored, private permissions, context never
copied, expiry, clear. Never touches your running setup."""
import json
import os
import stat
import sys
import tempfile
import time

REPO = os.path.join(os.path.dirname(os.path.realpath(__file__)), "..")
tmp = tempfile.mkdtemp(prefix="omavoice-trace-test.")
os.environ["OMAVOICE_TRACE_DIR"] = os.path.join(tmp, "trace")
os.environ["OMAVOICE_DAEMON_LOG"] = os.path.join(tmp, "daemon.log")
sys.path.insert(0, os.path.join(REPO, "lib"))
import omavoice_trace as trace  # noqa: E402

failed = 0


def check(name, ok, detail=""):
    global failed
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""))


E = "\x1b[2m"
LOG = f"""{E}2026-10-01T01:52:50.000000Z\x1b[0m \x1b[32m INFO\x1b[0m Chunk 1 completed: "so um I wanted to"
{E}2026-10-01T01:52:57.949117Z\x1b[0m DEBUG Received SIGUSR2 (stop recording)
2026-10-01T01:52:57.949136Z  INFO Eager recording stopped (6.8s)
2026-10-01T01:52:58.349000Z DEBUG Tail transcription: "send it to mark sorry to mike"
2026-10-01T01:52:58.350000Z  INFO Transcribed: "so um I wanted to send it to mark sorry to mike"
2026-10-01T01:52:58.360000Z DEBUG Post-processing input: "so um I wanted to send it to Mark sorry to Mike \\"now\\"", context: Some("SECRET-CONTEXT")
2026-10-01T01:52:58.600000Z DEBUG Post-processed result: "I wanted to send it to Mike \\"now\\"."
2026-10-01T01:52:58.601000Z  INFO wrote transcription to "/run/user/1000/voxtype/omavoice-output.txt"
"""
open(os.environ["OMAVOICE_DAEMON_LOG"], "w").write(LOG)

check("not armed: nothing saved", trace.capture(time.time()) is False and trace.load() == [])
trace.start(2)
mode = stat.S_IMODE(os.stat(os.environ["OMAVOICE_TRACE_DIR"]).st_mode)
check("trace folder is private (0700)", mode == 0o700, oct(mode))
stop_epoch = trace._ts("2026-10-01T01:52:57.949117")
check("armed: saves a record", trace.capture(stop_epoch + 0.75, 90.0, "pasted"))
r = trace.load()[0]
check("raw stage is the speech model text", r["raw"] == "so um I wanted to send it to mark sorry to mike", r["raw"])
check("input stage keeps escaped quotes", r["input"] == 'so um I wanted to send it to Mark sorry to Mike "now"', r["input"])
check("final stage", r["final"] == 'I wanted to send it to Mike "now".', r["final"])
check("chunks captured", r["chunks"] == ["so um I wanted to"], r["chunks"])
check("screen context is never copied", "SECRET-CONTEXT" not in json.dumps(r))
ms = r["ms_after_release"]
check("timings after release", ms.get("tail") == 400 and ms.get("cleanup_end") == 651 and abs(ms.get("pasted", 0) - 751) <= 1, ms)
f = trace._records()[0]
check("record file is private (0600)", stat.S_IMODE(os.stat(f).st_mode) == 0o600)
check("armed count goes down", trace.remaining() == 1)
trace.capture(time.time())
check("stops after N dictations", trace.remaining() == 0 and len(trace.load()) == 2 and trace.capture(time.time()) is False)
rem, add = trace.changed_words(r["input"], r["final"])
check("word changes ignore case and punctuation", (rem, add) == (5, 0), (rem, add))
check("word diff marks removals", "[-so um-]" in trace.word_diff(r["input"], r["final"]))
old = time.time() - trace.EXPIRE_SECONDS - 10
os.utime(f, (old, old))
trace.purge_expired()
check("records expire after 24 hours", not os.path.exists(f))
trace.clear()
check("clear deletes everything", trace.load() == [] and trace.remaining() == 0)
open(os.environ["OMAVOICE_DAEMON_LOG"], "w").write("")
trace.start(1)
trace.capture(time.time(), None, "only pasted")
r = trace.load()[0]
check("missing stages are marked, not guessed", r.get("raw_missing") and r.get("input_missing") and r["final_from"] == "pasted text")
trace.clear()
sys.exit(1 if failed else 0)
