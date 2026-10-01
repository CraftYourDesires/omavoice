#!/bin/bash
# Build omavoice-clipboard into build/ (install.sh links it into ~/.local/bin).
# Needs gcc, wayland (libwayland-client, wayland-scanner) and wayland-protocols.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
out="$repo/build"
xml=$(pkg-config --variable=pkgdatadir wayland-protocols)/staging/ext-data-control/ext-data-control-v1.xml
[[ -f $xml ]] || { echo "ext-data-control-v1.xml not found (wayland-protocols 1.39 or newer)"; exit 1; }
mkdir -p "$out"
wayland-scanner client-header "$xml" "$out/ext-data-control-v1-client-protocol.h"
wayland-scanner private-code "$xml" "$out/ext-data-control-v1-protocol.c"
cc -std=c11 -O2 -Wall -Wextra -I"$out" "$repo/clipboard/omavoice-clipboard.c" "$out/ext-data-control-v1-protocol.c" \
  -o "$out/omavoice-clipboard.new" $(pkg-config --cflags --libs wayland-client)
chmod 755 "$out/omavoice-clipboard.new"
mv "$out/omavoice-clipboard.new" "$out/omavoice-clipboard"
echo "built $out/omavoice-clipboard"
