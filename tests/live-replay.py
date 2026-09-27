#!/usr/bin/env python3
"""Replay a recorded dictation through dictation-live and time the finish.

live-replay-chunks.json holds Voxtype's real 20s eager chunk transcripts of
three minutes of public domain speech (LibriVox, The Art of War, chapter 1),
the last entry being the tail after the final chunk. This script writes them
into a fake Voxtype debug log one by one, the way the daemon does while you
talk, then hands the stitched transcript to dictation-cleanup and measures how
long the final cleanup takes, with and without the live helper.

Nothing touches the running Voxtype: everything happens in a temporary
XDG_RUNTIME_DIR and config dir. Needs Ollama running.
Usage: tests/live-replay.py [app-style window, e.g. "chromium|Inbox - Gmail"]
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
BIN = os.path.join(REPO, "bin")


def voxtype_transcript(chunks, tail):
    """Stitch chunks exactly like Voxtype 1.0.1 (dictation-live has the port)."""
    loader = importlib.machinery.SourceFileLoader("live", os.path.join(BIN, "dictation-live"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    live = importlib.util.module_from_spec(spec)
    loader.exec_module(live)
    combined = chunks[0]
    for text in chunks[1:] + [tail]:
        new = live.deduplicate_boundary(combined, text)
        if new:
            combined += " " + new
    return combined


def run(mode, window, chunks, tail, transcript):
    with tempfile.TemporaryDirectory() as tmp:
        runtime, config = os.path.join(tmp, "run"), os.path.join(tmp, "config")
        os.makedirs(os.path.join(runtime, "voxtype"))
        os.makedirs(config)
        shutil.copy(os.path.join(HERE, "dictionary.txt"), config)
        shutil.copy(os.path.join(REPO, "config", "app-styles.toml"), config)
        with open(os.path.join(config, "omavoice.toml"), "w") as f:
            f.write('name = "Sam"\ncleanup = true\n')
        env = dict(os.environ, XDG_RUNTIME_DIR=runtime, OMAVOICE_CONFIG_DIR=config,
                   DICTATION_NO_CONTEXT="1", DICTATION_WINDOW=window, PYTHONDONTWRITEBYTECODE="1")
        state = os.path.join(runtime, "voxtype", "state")
        log = os.path.join(runtime, "voxtype-daemon.log")
        open(state, "w").write("recording")
        open(log, "w").close()
        helper = None
        if mode == "live":
            helper = subprocess.Popen([os.path.join(BIN, "dictation-live")], env=env)
            time.sleep(1.5)
        for i, text in enumerate(chunks):
            with open(log, "a") as f:
                f.write(f"2026-01-01T00:00:{i:02d}.000000Z DEBUG Chunk {i} completed: {json.dumps(text, ensure_ascii=False)}\n")
            time.sleep(2)  # real chunks arrive every 19.5s; cleaning one takes well under 2s
        open(state, "w").write("transcribing")
        start = time.monotonic()
        out = subprocess.run([os.path.join(BIN, "dictation-cleanup")], input=transcript, env=env,
                             capture_output=True, text=True).stdout
        took = time.monotonic() - start
        open(state, "w").write("idle")
        if helper:
            helper.wait(timeout=20)
        return took, out


def main():
    window = sys.argv[1] if len(sys.argv) > 1 else "|"
    texts = json.load(open(os.path.join(HERE, "live-replay-chunks.json")))
    chunks, tail = texts[:-1], texts[-1]
    transcript = voxtype_transcript(chunks, tail)
    words = len(transcript.split())
    results = {}
    for mode in ("full", "live"):
        took, out = run(mode, window, chunks, tail, transcript)
        results[mode] = out
        print(f"{mode:4}: {took:.2f}s from release to cleaned text, {words} words in, {len(out.split())} out")
    kept = len(results["live"].split()) / words
    print(f"\nlive output keeps {kept:.0%} of the words")
    print(results["live"])
    return 0 if kept > 0.9 else 1


if __name__ == "__main__":
    sys.exit(main())
