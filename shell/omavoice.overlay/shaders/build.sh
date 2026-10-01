#!/bin/bash
# Rebuild the committed shader bakes. Only needed after editing a .frag;
# the .qsb files in the repo work on machines without qt6-shadertools.
# With glslang installed, every GLSL bake is also compiled as a check: Qt
# uses the GLSL 120 one on compatibility-profile OpenGL, and a bake that
# fails there draws nothing without any error message.
set -euo pipefail
cd "$(dirname "$0")"
qsb=$(command -v qsb || echo /usr/lib/qt6/bin/qsb)
[[ -x $qsb ]] || { echo "qsb not found (install qt6-shadertools)"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for f in voice trace wave solid; do
  "$qsb" --glsl "100 es,120,150" --hlsl 50 --msl 12 -o $f.frag.qsb $f.frag
  if command -v glslangValidator >/dev/null; then
    for v in 120 150; do
      "$qsb" -x glsl,$v -o "$tmp/$f.$v.frag" $f.frag.qsb
      glslangValidator -S frag "$tmp/$f.$v.frag" >"$tmp/log" || { echo "$f.frag: GLSL $v bake does not compile:"; cat "$tmp/log"; exit 1; }
    done
  fi
  echo "built $(pwd)/$f.frag.qsb"
done
