#!/bin/bash
# Live theme hot-switch test on the real desktop, without touching your
# Omarchy theme. It starts a second, throwaway Quickshell instance that runs
# the real overlay plugin against a scratch XDG_STATE_HOME, then switches
# themes there exactly the way omarchy-theme-set does (delete the theme
# directory, move the next one in, rewrite theme.name). Checks that the
# palette follows while hidden, after rapid switches, while the overlay is on
# screen (crossfading without dropping frames), after an in-place edit, and
# after an older style symlink swap. Everything is removed afterwards.
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
themes=/usr/share/omarchy/themes
work=$(mktemp -d /tmp/omavoice-theme-live.XXXXXX)
state=$work/state/omarchy/current
cfg=$work/cfg
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

expected() { # colors.toml -> the core color the overlay should use
  node -e '
    const fs = require("fs"), vm = require("vm"), M = { Math }
    vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8").replace(/^\.pragma library.*$/m, ""), M)
    console.log(M.paletteFrom(M.parseColorsToml(fs.readFileSync(process.argv[2], "utf8"))).core)' \
    "$repo/shell/omavoice.overlay/OverlayModel.js" "$1"
}
ipc() { quickshell -p "$cfg/shell.qml" ipc call omavoice "$@" 2>/dev/null; }
field() { ipc status | python3 -c "import json,sys; d=json.load(sys.stdin); print(eval('d' + ''.join('[%r]' % k for k in sys.argv[1].split('.'))))" "$1"; }
until_field() { # key value [tries of 50 ms]
  for _ in $(seq "${3:-40}"); do [[ $(field "$1") == "$2" ]] && return 0; sleep 0.05; done
  return 1
}
# The same swap omarchy-theme-set performs.
switch_theme() {
  mkdir -p "$state/next-theme"
  cp "$themes/$1/colors.toml" "$state/next-theme/colors.toml"
  rm -rf "$state/theme"
  mv "$state/next-theme" "$state/theme"
  echo "$1" >"$state/theme.name"
}

mkdir -p "$state" "$cfg"
switch_theme tokyo-night
ln -s "$repo/shell/omavoice.overlay" "$cfg/overlay"
cat >"$cfg/shell.qml" <<'EOF'
import QtQuick
import Quickshell
import "overlay"
ShellRoot { Service {} }
EOF
XDG_STATE_HOME=$work/state quickshell -p "$cfg/shell.qml" >"$work/qs.log" 2>&1 &
qs_pid=$!
for _ in $(seq 100); do [[ $(ipc ping) == ok ]] && break; sleep 0.05; done
[[ $(ipc ping) == ok ]] || { echo "test instance did not start"; cat "$work/qs.log"; exit 1; }

tokyo=$(expected $themes/tokyo-night/colors.toml)
latte=$(expected $themes/catppuccin-latte/colors.toml)
gruvbox=$(expected $themes/gruvbox/colors.toml)
jade=$(expected $themes/osaka-jade/colors.toml)

echo "== hidden"
until_field theme.core "$tokyo"; check "starts on the current theme" '[[ $(field theme.core) == "$tokyo" ]]' "$(field theme.core) vs $tokyo"
switch_theme catppuccin-latte
until_field theme.core "$latte"
check "follows a theme switch while hidden" '[[ $(field theme.core) == "$latte" && $(field theme.name) == catppuccin-latte ]]' "$(field theme.core)"
check "a hidden switch applies at once" '[[ $(field theme.shown) == "$latte" && $(field theme.blending) == False ]]' "$(field theme.shown)"
switch_theme gruvbox; sleep 0.03; switch_theme osaka-jade; sleep 0.03; switch_theme tokyo-night
until_field theme.core "$tokyo"
check "rapid switches settle on the last theme" '[[ $(field theme.core) == "$tokyo" ]]' "$(field theme.core)"

echo "== visible"
check "simulation starts" '[[ $(ipc simulate fixture) == ok ]]' "refused"
sleep 1.2
switch_theme catppuccin-latte
blended=False
for _ in $(seq 20); do [[ $(field theme.blending) == True ]] && { blended=True; break; }; sleep 0.03; done
check "crossfades while on screen" '[[ $blended == True ]]' "never blending"
until_field theme.shown "$latte"
check "lands on the new theme while on screen" '[[ $(field theme.shown) == "$latte" && $(field theme.blending) == False ]]' "$(field theme.shown)"
check "stays visible through the switch" '[[ $(field phase) != hidden ]]' "$(field phase)"
fps=$(field fps)
check "keeps about 60 fps through the switch" 'python3 -c "import sys; sys.exit(0 if $fps >= 45 else 1)"' "fps $fps"
until_field phase hidden 200
check "dismisses after the fixture" '[[ $(field phase) == hidden ]]' "$(field phase)"

echo "== other ways a theme changes"
cp "$themes/gruvbox/colors.toml" "$state/theme/colors.toml"
until_field theme.core "$gruvbox"
check "an in-place edit after a swap is picked up" '[[ $(field theme.core) == "$gruvbox" ]]' "$(field theme.core)"
mkdir -p "$work/themes/osaka-jade"
cp "$themes/osaka-jade/colors.toml" "$work/themes/osaka-jade/"
rm -rf "$state/theme"
ln -nsf "$work/themes/osaka-jade" "$state/theme"
echo osaka-jade >"$state/theme.name"
until_field theme.core "$jade"
check "a symlink swap is picked up" '[[ $(field theme.core) == "$jade" ]]' "$(field theme.core)"

loads=$(field theme.loads)
sleep 1
check "no reloads while nothing changes" '[[ $(field theme.loads) == $loads ]]' "$loads -> $(field theme.loads)"
# Only the overlay's own messages; a second Quickshell instance always gets a
# harmless portal warning about its app ID.
problems=$(grep -E "WARN|ERROR|TypeError|ReferenceError" "$work/qs.log" | grep -v "host portal")
check "no warnings or errors from the overlay" '[[ -z $problems ]]' "$(head -3 <<<"$problems")"
exit $failed
