#!/bin/bash
# Live smoke test of the overlay inside the running omarchy-shell.
#  1. Fixture simulation: the overlay opens on the focused monitor, animates
#     near 60 fps, and fully cleans up afterwards.
#  2. Real Voxtype: `voxtype record start`, then `voxtype record cancel`.
#     Cancel discards the audio, so nothing is transcribed or pasted. The
#     overlay must follow the real state and read live mic peaks.
# Refuses to run while a dictation is in progress.
set -uo pipefail
ipc() { omarchy-shell omavoice "$@"; }
field() { ipc status | python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
layer() { hyprctl layers -j | python3 -c "
import json, sys
d = json.load(sys.stdin)
hits = [(m, l) for m, v in d.items() for lv in v['levels'].values() for l in lv if l['namespace'] == 'omavoice-overlay']
print(' '.join(f\"{m}:{l['x']},{l['y']}:{l['w']}x{l['h']}\" for m, l in hits))"; }
failed=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1 ($3)"; failed=1; fi; }
qs_streams() { pw-dump 2>/dev/null | python3 -c "
import json, sys
n = 0
for o in json.load(sys.stdin):
    p = (o.get('info') or {}).get('props') or {}
    # PwNodePeakMonitor's tap: node.name quickshell, application.name
    # Quickshell Peak Detect, stream.monitor true (read-only).
    if o.get('type', '').endswith('Node') and p.get('media.class') == 'Stream/Input/Audio' and p.get('node.name') == 'quickshell':
        n += 1
print(n)"; }
state() { cat "${XDG_RUNTIME_DIR:-/tmp}/voxtype/state" 2>/dev/null; }

[[ $(ipc ping 2>/dev/null) == ok ]] || { echo "omavoice.overlay is not loaded in omarchy-shell"; exit 1; }
[[ $(state) == idle ]] || { echo "Voxtype is busy ($(state)); not touching it"; exit 2; }

echo "== fixture simulation"
check "simulation starts" '[[ $(ipc simulate fixture) == ok ]]' "refused"
sleep 1.5
l=$(layer)
check "layer surface is mapped" '[[ -n $l ]]' "none"
focused=$(hyprctl monitors -j | python3 -c "import json,sys; print([m['name'] for m in json.load(sys.stdin) if m['focused']][0])")
check "on the focused monitor ($focused)" '[[ $l == $focused:* ]]' "$l"
sleep 1.5
fps=$(field fps)
check "animates at about 60 fps" 'python3 -c "import sys; sys.exit(0 if 45 <= $fps <= 65 else 1)"' "fps $fps"
check "mic is not opened for a simulation" '[[ $(field listening) == False ]]' "listening"
for _ in $(seq 40); do [[ $(field phase) == hidden ]] && break; sleep 0.25; done
check "dismissed after the fixture" '[[ $(field phase) == hidden && -z $(layer) ]]' "$(field phase) $(layer)"
check "animation stopped when hidden" '[[ $(field animating) == False ]]' "still animating"

echo "== real Voxtype start and cancel"
[[ $(state) == idle ]] || { echo "Voxtype became busy; skipping the real check"; exit $failed; }
trap '[[ $(state) != idle ]] && voxtype record cancel' EXIT
before=$(field peakUpdates)
voxtype record start
sleep 1.5
check "follows Voxtype into recording" '[[ $(field phase) == recording && -n $(layer) ]]' "$(field phase)"
check "listens to the default source" '[[ $(field listening) == True ]]' "not listening"
after=$(field peakUpdates)
check "one monitor stream while recording" '(( $(qs_streams) >= 1 ))' "none"
check "receives live peak levels" '(( after > before + 10 ))' "$before -> $after"
voxtype record cancel
for _ in $(seq 20); do [[ $(field phase) == hidden ]] && break; sleep 0.1; done
check "dismissed promptly after cancel" '[[ $(field phase) == hidden && -z $(layer) ]]' "$(field phase)"
check "mic monitor released" '[[ $(field listening) == False ]]' "still listening"
check "no quickshell capture stream left in PipeWire" '(( $(qs_streams) == 0 ))' "$(qs_streams) left"
exit $failed
