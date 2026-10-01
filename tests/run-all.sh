#!/bin/bash
# Run every omavoice test and print a one line result per suite.
#
# Usage: tests/run-all.sh [--offline]
#   --offline  only the suites that need no Ollama, desktop session or audio
#
# The live suites need a running Omarchy session (Hyprland, omarchy-shell,
# Voxtype idle). They save and restore your clipboard, use scratch folders
# for history, settings and themes, and never change your own theme. The real
# dictation suite switches the default microphone to a temporary virtual one
# for about 15 seconds and restores it.
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
offline=false
[[ ${1:-} == --offline ]] && offline=true
logs=$(mktemp -d /tmp/omavoice-tests.XXXXXX)
failed=()

suite() { # name command...
  local name=$1
  shift
  local start=$SECONDS
  if "$@" >"$logs/$name.log" 2>&1; then
    printf 'PASS  %-24s %3ds  %s\n' "$name" $((SECONDS - start)) "$(grep -ciE '^(pass|ok) ' "$logs/$name.log") checks"
  else
    printf 'FAIL  %-24s %3ds  see %s\n' "$name" $((SECONDS - start)) "$logs/$name.log"
    grep -E '^FAIL' "$logs/$name.log" | head -5 | sed 's/^/      /'
    failed+=("$name")
  fi
}

suite store python3 tests/store-test.py
suite dictionary node tests/dictionary-test.mjs
suite overlay-model node tests/overlay-model-test.mjs
suite overlay-render tests/overlay-render-test.sh
suite overlay-trace-render tests/overlay-trace-render-test.sh
if ! $offline; then
  suite cleanup python3 tests/run-cleanup-tests.py
  suite live-replay python3 tests/live-replay.py
  suite clipboard python3 tests/clipboard-test.py
  suite output python3 tests/output-test.py --with-window
  suite overlay-live-smoke tests/overlay-live-smoke.sh
  suite overlay-theme-live tests/overlay-theme-live-test.sh
  suite overlay-style-live tests/overlay-style-live-test.sh
  suite app-ui python3 tests/app-ui-test.py
  suite real-dictation python3 tests/real-dictation-test.py
fi

if ((${#failed[@]})); then
  echo "Failed: ${failed[*]} (logs in $logs)"
  exit 1
fi
rm -rf "$logs"
echo "All suites passed."
