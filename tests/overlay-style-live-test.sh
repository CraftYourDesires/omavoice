#!/bin/bash
# Live style switching test on the real desktop, without touching your
# settings or theme. Like overlay-theme-live-test.sh it starts a throwaway
# Quickshell instance running the real overlay plugin, here against a
# scratch omavoice.toml (OMAVOICE_CONFIG_DIR) and a scratch theme folder.
# Checks that overlay_style switches the look while hidden and while on
# screen, that the trace style runs at about 60 fps, follows a theme switch
# with a crossfade, and that editing other settings keeps the style. Each
# style is also captured from the compositor with grim.
#
# Usage: tests/overlay-style-live-test.sh [--shots DIR]   (default: no files kept)
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
themes=/usr/share/omarchy/themes
work=$(mktemp -d /tmp/omavoice-style-live.XXXXXX)
state=$work/state/omarchy/current
conf=$work/conf
cfg=$work/cfg
shots=""
[[ ${1:-} == --shots ]] && shots=${2:?directory}
qs_pid=""
cleanup() {
  [[ -n $qs_pid ]] && kill "$qs_pid" 2>/dev/null && wait "$qs_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

[[ $(cat "${XDG_RUNTIME_DIR:-/tmp}/voxtype/state" 2>/dev/null) == idle ]] ||
  { echo "Voxtype is busy; not starting a second overlay now"; exit 2; }

failed=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1 ($3)"; failed=1; fi; }
expected() {
  node -e '
    const fs = require("fs"), vm = require("vm"), M = { Math }
    vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8").replace(/^\.pragma library.*$/m, ""), M)
    console.log(M.paletteFrom(M.parseColorsToml(fs.readFileSync(process.argv[2], "utf8"))).core)' \
    "$repo/shell/omavoice.overlay/OverlayModel.js" "$1"
}
ipc() { quickshell -p "$cfg/shell.qml" ipc call omavoice "$@" 2>/dev/null; }
field() { ipc status | python3 -c "import json,sys; d=json.load(sys.stdin); print(eval('d' + ''.join('[%r]' % k for k in sys.argv[1].split('.'))))" "$1"; }
until_field() {
  for _ in $(seq "${3:-40}"); do [[ $(field "$1") == "$2" ]] && return 0; sleep 0.05; done
  return 1
}
switch_theme() {
  mkdir -p "$state/next-theme"
  cp "$themes/$1/colors.toml" "$state/next-theme/colors.toml"
  rm -rf "$state/theme"
  mv "$state/next-theme" "$state/theme"
  echo "$1" >"$state/theme.name"
}
# Change the style the way the omavoice app does (omavoice-store set).
set_style() { OMAVOICE_CONFIG_DIR=$conf "$repo/bin/omavoice-store" set overlay_style "$1" >/dev/null; }
# Our test layer: the one whose pid is the throwaway instance.
layer_geom() { hyprctl layers -j | python3 -c "
import json, sys
pid = int(sys.argv[1])
for m, v in json.load(sys.stdin).items():
    for lv in v['levels'].values():
        for l in lv:
            if l['namespace'] == 'omavoice-overlay' and l['pid'] == pid:
                print(f\"{l['x']},{l['y']} {l['w']}x{l['h']}\")" "$qs_pid"; }
shoot() { # name
  [[ -n $shots ]] || return 0
  local g
  g=$(layer_geom)
  [[ -n $g ]] && grim -g "$g" "$shots/$1.png" && echo "      captured $shots/$1.png"
}

mkdir -p "$state" "$cfg" "$conf"
[[ -n $shots ]] && mkdir -p "$shots"
switch_theme tokyo-night
sed -e 's|__NAME__|Test|' -e 's|__CLEANUP__|true|' "$repo/config/omavoice.toml" >"$conf/omavoice.toml"
ln -s "$repo/shell/omavoice.overlay" "$cfg/overlay"
cat >"$cfg/shell.qml" <<'EOF'
import QtQuick
import Quickshell
import "overlay"
ShellRoot { Service {} }
EOF
XDG_STATE_HOME=$work/state OMAVOICE_CONFIG_DIR=$conf quickshell -p "$cfg/shell.qml" >"$work/qs.log" 2>&1 &
qs_pid=$!
for _ in $(seq 100); do [[ $(ipc ping) == ok ]] && break; sleep 0.05; done
[[ $(ipc ping) == ok ]] || { echo "test instance did not start"; cat "$work/qs.log"; exit 1; }

echo "== hidden"
check "starts on neon (no overlay_style set)" '[[ $(field style) == neon ]]' "$(field style)"
set_style trace
until_field style trace
check "switches to trace from the settings file" '[[ $(field style) == trace ]]' "$(field style)"
set_style neon; sleep 0.05; set_style trace; sleep 0.05; set_style neon; sleep 0.05; set_style trace
until_field style trace
check "rapid switches settle on the last style" '[[ $(field style) == trace ]]' "$(field style)"
OMAVOICE_CONFIG_DIR=$conf "$repo/bin/omavoice-store" set overlay_position bottom >/dev/null
until_field position bottom
check "changing another setting keeps the style" '[[ $(field style) == trace && $(field position) == bottom ]]' "$(field style) $(field position)"
OMAVOICE_CONFIG_DIR=$conf "$repo/bin/omavoice-store" set overlay_position top >/dev/null
until_field position top

echo "== trace on screen"
check "simulation starts" '[[ $(ipc simulate fixture) == ok ]]' "refused"
sleep 1.4
check "trace overlay is mapped" '[[ -n $(layer_geom) ]]' "no layer"
fps=$(field fps)
check "trace animates at about 60 fps" 'python3 -c "import sys; sys.exit(0 if 45 <= $fps <= 65 else 1)"' "fps $fps"
sleep 0.2
shoot trace-tokyo-night
latte=$(expected $themes/catppuccin-latte/colors.toml)
switch_theme catppuccin-latte
blended=False
for _ in $(seq 20); do [[ $(field theme.blending) == True ]] && { blended=True; break; }; sleep 0.03; done
check "trace crossfades on a theme switch" '[[ $blended == True ]]' "never blending"
until_field theme.shown "$latte"
check "trace lands on the new theme" '[[ $(field theme.shown) == "$latte" ]]' "$(field theme.shown)"
sleep 0.4
shoot trace-catppuccin-latte
until_field phase hidden 200
check "dismissed after the fixture" '[[ $(field phase) == hidden && -z $(layer_geom) ]]' "$(field phase)"

echo "== switching while on screen"
switch_theme tokyo-night
ipc simulate fixture >/dev/null
sleep 1.2
set_style neon
until_field style neon
check "switches to neon while on screen" '[[ $(field style) == neon && $(field phase) != hidden ]]' "$(field style) $(field phase)"
sleep 0.5
check "neon keeps about 60 fps after the switch" 'python3 -c "import sys; sys.exit(0 if $(field fps) >= 45 else 1)"' "fps $(field fps)"
shoot neon-tokyo-night
until_field phase hidden 200
check "animation stops when hidden" '[[ $(field animating) == False ]]' "still animating"

problems=$(grep -E "WARN|ERROR|TypeError|ReferenceError" "$work/qs.log" | grep -v "host portal")
check "no warnings or errors from the overlay" '[[ -z $problems ]]' "$(head -3 <<<"$problems")"
exit $failed
