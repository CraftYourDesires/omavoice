#!/usr/bin/env python3
"""Regression tests for bin/dictation-cleanup against the local Ollama model.

Runs every case in cleanup-cases.json through the script's real main(), with
the focused window and screen text faked per case, the fictional
tests/dictionary.txt, and the repo's app styles. Checks are plain rules:
every must_include string appears (case-sensitive), and no must_exclude
phrase appears as a whole word or phrase (case-insensitive).

Usage: tests/run-cleanup-tests.py [case_id ...]   (needs Ollama running)
Exit code 0 when every selected case passes.
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def load_cleanup(runtime):
    loader = importlib.machinery.SourceFileLoader("dictation_cleanup", os.path.join(REPO, "bin", "dictation-cleanup"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    module.DICT_PATH = os.path.join(HERE, "dictionary.txt")
    module.STYLES_PATH = os.path.join(REPO, "config", "app-styles.toml")
    module.RUNTIME = runtime
    module.GPU_BUSY_FLAG = os.path.join(runtime, "gpu-busy")
    module.LAST_OUTPUT = os.path.join(runtime, "last-output")
    module.settings = lambda: {"name": "Sam", "cleanup": True}
    return module


def run_case(module, case):
    cls, _, title = case.get("window", "").partition("|")
    module.focused_window = lambda: (cls, title)
    module.screen_context = lambda _cls, _skip: list(case.get("context", []))
    os.environ.pop("VOXTYPE_CONTEXT", None)
    out = io.StringIO()
    sys.stdin = io.StringIO(case["raw"])
    with contextlib.redirect_stdout(out):
        module.main()
    return out.getvalue().strip()


def failures(case, output):
    problems = [f"missing {s!r}" for s in case.get("must_include", []) if s not in output]
    for phrase in case.get("must_exclude", []):
        if re.search(rf"(?<!\w){re.escape(phrase.strip())}(?!\w)", output, re.IGNORECASE):
            problems.append(f"contains {phrase.strip()!r}")
    return problems


def main():
    cases = json.load(open(os.path.join(HERE, "cleanup-cases.json")))
    wanted = set(sys.argv[1:])
    if wanted:
        cases = [c for c in cases if c["id"] in wanted]
    with tempfile.TemporaryDirectory() as runtime:
        module = load_cleanup(runtime)
        passed = 0
        for case in cases:
            start = time.monotonic()
            output = run_case(module, case)
            problems = failures(case, output)
            took = time.monotonic() - start
            if problems:
                print(f"FAIL {case['id']} ({took:.2f}s): {'; '.join(problems)}\n     output: {output[:300]!r}")
            else:
                passed += 1
                print(f"pass {case['id']} ({took:.2f}s)")
    print(f"\n{passed}/{len(cases)} passed")
    return 0 if passed == len(cases) else 1


if __name__ == "__main__":
    sys.exit(main())
