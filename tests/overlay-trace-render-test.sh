#!/bin/bash
# Renders the real "trace" overlay style (TraceVisualizer.qml and
# shaders/trace.frag) offscreen from the deterministic level fixture, and
# checks the pixels: invisible when hidden, a calm flat line in silence, a
# taller and wilder trace for louder speech, a distinct processing state,
# colors from the theme, and a hot theme switch in the middle of speech.
#
# Usage: tests/overlay-trace-render-test.sh [--preview]
#   --preview also writes /tmp/omavoice-styles-preview.png and .mp4: both
#   styles side by side in four themes, plus a live theme switch.
# Needs g++, pkg-config, qt6-declarative, ffmpeg and python-numpy.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/omavoice-trace.XXXXXX)
trap 'rm -rf "$work"' EXIT
export QML_XHR_ALLOW_FILE_READ=1

g++ -std=c++17 -O1 -fPIC "$repo/tests/overlay/render.cpp" -o "$work/render" \
  $(pkg-config --cflags --libs Qt6Quick Qt6Gui Qt6Qml)

themes=/usr/share/omarchy/themes
current="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/current/theme/colors.toml"
[[ -f $current ]] || current=$themes/tokyo-night/colors.toml
frames=576
switch_at=300

render() { # name colors scale backdrop style [switchColors]
  local extra=()
  [[ -n ${6:-} ]] && extra=(switchColors="$6" switchAt=$switch_at)
  "$work/render" "$repo/tests/overlay/Harness.qml" "$work/$1" "$frames" \
    fps=60 colors="$2" scale="$3" backdrop="$4" style="$5" "${extra[@]}" >"$work/$1.jsonl" 2>"$work/$1.err" ||
    { cat "$work/$1.err"; exit 1; }
  grep -q 'graphics api' "$work/$1.err"
}

palettes() {
  node -e '
    const fs = require("fs"), vm = require("vm"), M = { Math }
    vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8").replace(/^\.pragma library.*$/m, ""), M)
    const out = {}
    for (const [name, file] of Object.entries(JSON.parse(process.argv[2])))
      out[name] = M.paletteFrom(M.parseColorsToml(fs.readFileSync(file, "utf8")))
    console.log(JSON.stringify(out))' "$repo/shell/omavoice.overlay/OverlayModel.js" "$1"
}

declare -A colors=(
  [current]=$current
  [tokyo]=$themes/tokyo-night/colors.toml
  [gruvbox]=$themes/gruvbox/colors.toml
  [latte]=$themes/catppuccin-latte/colors.toml
)
for t in "${!colors[@]}"; do render "$t" "${colors[$t]}" 1 0 trace & done
render switch "${colors[tokyo]}" 1 0 trace "${colors[latte]}" &
render neon-tokyo "${colors[tokyo]}" 1 0 neon &
wait
map=$(for t in "${!colors[@]}"; do printf '"%s":"%s",' "$t" "${colors[$t]}"; done)
palettes "{${map%,}}" >"$work/palettes.json"

checks=0
python3 - "$work" "$switch_at" <<'PYEOF' || checks=$?
import json, subprocess, sys
import numpy as np
work, switch_at = sys.argv[1], int(sys.argv[2])
pal = json.load(open(f"{work}/palettes.json"))
failed = 0
def check(name, ok, detail=""):
    global failed
    failed += not ok
    print(("PASS" if ok else "FAIL") + "  " + name + (f"  ({detail})" if detail else ""))

def load(name):
    meta = [json.loads(l) for l in open(f"{work}/{name}.jsonl")]
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", f"{work}/{name}/frame_%05d.png",
                          "-f", "rawvideo", "-pix_fmt", "rgba", "-"], capture_output=True, check=True).stdout
    return meta, np.frombuffer(raw, np.uint8).reshape(len(meta), 80, 288, 4).astype(np.float32) / 255

def hexrgb(h): return np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)], np.float32) / 255
def unpremul(px): return px[..., :3] / np.maximum(px[..., 3:4], 1e-3)
def luma(rgb): return rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)
def hue(rgb):
    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    lms = np.cbrt(lin @ np.array([[0.4122214708, 0.2119034982, 0.0883024619],
                                  [0.5363325363, 0.6806995451, 0.2817188376],
                                  [0.0514459929, 0.1073969566, 0.6299787005]], np.float32))
    a = lms @ np.array([1.9779984951, -2.428592205, 0.4505937099], np.float32)
    b = lms @ np.array([0.0259040371, 0.7827717662, -0.808675766], np.float32)
    return float(np.degrees(np.arctan2(b, a)) % 360)
def hue_gap(x, y):
    d = abs(x - y) % 360
    return min(d, 360 - d)

# Panel spans x 12..276, y 12..68; the plot runs x 20..254 around y 40.
PLOT = (slice(15, 66), slice(40, 250))
CORNER = (slice(16, 20), slice(40, 60))     # top strip of the plot, above most of the trace

def ink_rows(frame, bg):
    """Rows (y) where the trace's bright ink is, across the plot."""
    # Only the crisp core line: the ASCII glow around it is much fainter.
    px = unpremul(frame[PLOT])
    lit = np.abs(px - bg).sum(-1) > 0.6
    ys = np.nonzero(lit.sum(1) >= 2)[0]
    return (ys.max() - ys.min()) if len(ys) else 0

for theme in ("current", "tokyo", "gruvbox", "latte"):
    meta, frames = load(theme)
    p = pal[theme]
    alpha = frames[..., 3]
    lvl = np.array([m["level"] for m in meta])
    rec = [i for i, m in enumerate(meta) if m["phase"] == "recording" and m["appear"] > 0.99]
    quiet = [i for i in rec if all(meta[j]["level"] < 0.03 for j in range(max(0, i - 40), i + 1))]
    loud = [i for i in rec if meta[i]["level"] > 0.6]
    proc = [i for i, m in enumerate(meta) if m["phase"] == "processing" and m["processing"] > 0.9]
    bg = hexrgb(p["background"])
    base = frames[quiet[3]]
    energy = np.abs(frames[:, PLOT[0], PLOT[1], :3] - base[PLOT][..., :3]).sum(-1).mean((1, 2))

    check(f"{theme}: hidden frames are fully transparent", alpha[0].max() == 0 and alpha[-1].max() == 0)
    check(f"{theme}: panel is drawn while recording", alpha[quiet[3]][PLOT].mean() > 0.85, f"coverage {alpha[quiet[3]][PLOT].mean():.2f}")
    qh = np.mean([ink_rows(frames[i], bg) for i in quiet])
    lh = np.mean([ink_rows(frames[i], bg) for i in loud])
    check(f"{theme}: silence draws a calm, flat line (core plus glow)", qh <= 12, f"ink spans {qh:.1f} px of 50")
    check(f"{theme}: loud speech draws tall peaks", lh > 30 and lh > 3 * max(qh, 1), f"ink spans {lh:.1f} px")
    r = np.corrcoef(lvl[rec], energy[rec])[0, 1]
    check(f"{theme}: picture tracks the level", r > 0.5, f"r={r:.2f}")
    check(f"{theme}: processing state is visible and calmer than speech",
          len(proc) > 10 and 0 < energy[proc].mean() < energy[loud].mean(), f"processing {energy[proc].mean():.4f} loud {energy[loud].mean():.4f}")
    check(f"{theme}: no NaN or garbage", np.isfinite(frames).all())
    # Panel background comes from this theme.
    pbg = unpremul(frames[quiet[3]][CORNER]).reshape(-1, 3).mean(0)
    dists = {t: float(np.abs(pbg - hexrgb(pal[t]["background"])).sum()) for t in pal}
    check(f"{theme}: panel background is the theme background", min(dists, key=dists.get) == theme and dists[theme] < 0.2,
          f"distance {dists[theme]:.3f}")
    # The trace ink carries the theme's rim hue.
    px = unpremul(frames[loud[::4]][:, PLOT[0], PLOT[1]]).reshape(-1, 3)
    lit = px[(np.abs(px - pbg).sum(-1) > 0.25) & ((px.max(-1) - px.min(-1)) > 0.06)]
    lit_h = np.array([hue(x) for x in lit[:: max(1, len(lit) // 1500)]])
    own = hue(hexrgb(p["rim"]))
    share = float(np.mean([hue_gap(h, own) < 25 for h in lit_h])) if len(lit_h) else 0
    others = [t for t in pal if hue_gap(hue(hexrgb(pal[t]["rim"])), own) > 40]
    oshare = {t: float(np.mean([hue_gap(h, hue(hexrgb(pal[t]["rim"]))) < 25 for h in lit_h])) for t in others}
    check(f"{theme}: trace carries the theme's rim hue", share > 0.15 and all(share > v for v in oshare.values()),
          f"own {share:.2f} " + " ".join(f"{t}={v:.2f}" for t, v in oshare.items()))
    contrast = abs(float(luma(lit.mean(0))) - float(luma(pbg))) if len(lit) else 0
    check(f"{theme}: trace contrast against the panel", contrast > 0.18, f"luma gap {contrast:.2f}")

# Style switching: same inputs, different style, different picture.
_, neon = load("neon-tokyo")
_, trace = load("tokyo")
check("styles: neon and trace draw different pictures from the same voice", np.abs(neon[400] - trace[400]).mean() > 0.03)

meta, frames = load("switch")
tokyo_frames = load("tokyo")[1]
latte_bg, tokyo_bg = hexrgb(pal["latte"]["background"]), hexrgb(pal["tokyo"]["background"])
bgs = np.array([unpremul(f[CORNER]).reshape(-1, 3).mean(0) for f in frames])
settled = next(i for i in range(switch_at + 30, len(meta)) if meta[i]["appear"] > 0.99 and meta[i]["level"] < 0.05)
check("switch: before the switch it matches the dark theme", np.abs(bgs[switch_at - 2] - tokyo_bg).sum() < 0.2)
check("switch: after the switch it matches the light theme", np.abs(bgs[settled] - latte_bg).sum() < 0.2, f"{np.abs(bgs[settled] - latte_bg).sum():.3f}")
check("switch: frames before the switch are identical to a plain render", np.abs(frames[:switch_at] - tokyo_frames[:switch_at]).max() < 1e-6)
step = np.abs(np.diff(luma(bgs[switch_at - 1:switch_at + 40]))).max()
check("switch: crossfades without a jump", step < 0.12, f"largest step {step:.3f}")
sys.exit(1 if failed else 0)
PYEOF

if [[ ${1:-} == --preview ]]; then
  for t in current tokyo gruvbox latte; do
    render "hq-trace-$t" "${colors[$t]}" 2 1 trace &
    render "hq-neon-$t" "${colors[$t]}" 2 1 neon &
  done
  render hq-switch "${colors[current]}" 2 1 trace "${colors[latte]}" &
  wait
  # Still: neon and trace side by side for rest, soft speech, loud speech
  # and processing, in the current theme; then loud speech in all four.
  rows=()
  for f in 40 150 410 500; do
    ffmpeg -v error -y -i "$work/hq-neon-current/frame_$(printf %05d $f).png" -i "$work/hq-trace-current/frame_$(printf %05d $f).png" \
      -filter_complex hstack=inputs=2 "$work/row-$f.png"
    rows+=(-i "$work/row-$f.png")
  done
  for t in tokyo gruvbox latte; do
    ffmpeg -v error -y -i "$work/hq-neon-$t/frame_00410.png" -i "$work/hq-trace-$t/frame_00410.png" \
      -filter_complex hstack=inputs=2 "$work/row-$t.png"
    rows+=(-i "$work/row-$t.png")
  done
  ffmpeg -v error -y "${rows[@]}" -filter_complex "vstack=inputs=$((${#rows[@]} / 2))" /tmp/omavoice-styles-preview.png
  # Video: neon | trace in the current theme, Tokyo Night and Latte, then the
  # trace style hot switching from the current theme to Latte mid-speech.
  in=()
  for t in current tokyo latte; do in+=(-framerate 60 -i "$work/hq-neon-$t/frame_%05d.png" -framerate 60 -i "$work/hq-trace-$t/frame_%05d.png"); done
  ffmpeg -v error -y "${in[@]}" -framerate 60 -i "$work/hq-switch/frame_%05d.png" -framerate 60 -i "$work/hq-trace-gruvbox/frame_%05d.png" \
    -filter_complex "[0][1]hstack[r0];[2][3]hstack[r1];[4][5]hstack[r2];[6][7]hstack[r3];[r0][r1][r2][r3]vstack=inputs=4,pad=ceil(iw/2)*2:ceil(ih/2)*2" \
    -c:v libx264 -pix_fmt yuv420p -crf 14 -movflags +faststart /tmp/omavoice-styles-preview.mp4
  echo "wrote /tmp/omavoice-styles-preview.png and /tmp/omavoice-styles-preview.mp4"
fi
exit $checks
