#!/bin/bash
# Renders the real overlay shader offscreen on the GPU (no window is mapped)
# from the deterministic level fixture, and checks the pixels react to the
# signal: invisible when hidden, a quiet line at rest, bigger shapes for
# louder speech, a distinct processing state, and fully gone at the end.
#
# Usage: tests/overlay-render-test.sh [--preview]
#   --preview also writes /tmp/omavoice-animation-preview.png and .mp4
# Needs g++, pkg-config, qt6-declarative, ffmpeg and python-numpy.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/omavoice-render.XXXXXX)
trap 'rm -rf "$work"' EXIT
export QML_XHR_ALLOW_FILE_READ=1

g++ -std=c++17 -O1 -fPIC "$repo/tests/overlay/render.cpp" -o "$work/render" \
  $(pkg-config --cflags --libs Qt6Quick Qt6Gui Qt6Qml)

themes=/usr/share/omarchy/themes
current="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/current/theme/colors.toml"
[[ -f $current ]] || current=$themes/tokyo-night/colors.toml
frames=576   # 9.6 s at 60 fps, the whole fixture
switch_at=300 # mid-phrase, while the voice is loud

render() { # name colors scale backdrop [switchColors]
  local extra=()
  [[ -n ${5:-} ]] && extra=(switchColors="$5" switchAt=$switch_at)
  "$work/render" "$repo/tests/overlay/Harness.qml" "$work/$1" "$frames" \
    fps=60 colors="$2" scale="$3" backdrop="$4" "${extra[@]}" >"$work/$1.jsonl" 2>"$work/$1.err" ||
    { cat "$work/$1.err"; exit 1; }
  grep -q 'graphics api' "$work/$1.err"
}

# Palettes as the overlay computes them, for the pixel checks.
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
for t in "${!colors[@]}"; do render "$t" "${colors[$t]}" 1 0 & done
render switch "${colors[tokyo]}" 1 0 "${colors[latte]}" &
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
    # OKLCH hue in degrees, for comparing color identity regardless of
    # lightness or how much shadow shares the pixel.
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

# Regions of the 288x80 frame. The pill spans x 12..276, y 12..68.
FLAT = (slice(17, 22), slice(70, 110))     # inside the pill, clear of the waveform and the round ends
HALO = (slice(8, 11), slice(90, 198))      # just above the pill's top edge
WAVE = (slice(26, 54), slice(40, 248))     # where the waveform draws

loaded = {}
for theme in ("current", "tokyo", "gruvbox", "latte"):
    meta, frames = load(theme)
    loaded[theme] = (meta, frames)
    p = pal[theme]
    alpha = frames[..., 3]
    base = frames[30]
    energy = np.abs(frames[..., :3] - base[..., :3]).sum(-1).mean((1, 2))
    lvl = np.array([m["level"] for m in meta])
    rec = [i for i, m in enumerate(meta) if m["phase"] == "recording" and m["appear"] > 0.99]
    quiet = [i for i in rec if meta[i]["level"] < 0.03]
    loud = [i for i in rec if meta[i]["level"] > 0.6]
    proc = [i for i, m in enumerate(meta) if m["phase"] == "processing" and m["processing"] > 0.9]

    check(f"{theme}: hidden frames are fully transparent", alpha[0].max() == 0 and alpha[-1].max() == 0)
    check(f"{theme}: pill is drawn while recording", alpha[30].mean() > 0.4, f"coverage {alpha[30].mean():.2f}")
    check(f"{theme}: speech changes the picture", energy[loud].mean() > 4 * max(energy[quiet].mean(), 1e-3),
          f"quiet {energy[quiet].mean():.4f} loud {energy[loud].mean():.4f}")
    r = np.corrcoef(lvl[rec], energy[rec])[0, 1]
    check(f"{theme}: picture tracks the level", r > 0.6, f"r={r:.2f}")
    check(f"{theme}: processing state is visible and calm",
          len(proc) > 10 and 0 < energy[proc].mean() < energy[loud].mean(),
          f"processing {energy[proc].mean():.4f}")
    check(f"{theme}: no NaN or garbage", np.isfinite(frames).all())

    # Colors come from this theme: the pill background matches the theme
    # background better than any other theme's.
    bg = unpremul(frames[quiet[5]][FLAT]).reshape(-1, 3).mean(0)
    dists = {t: float(np.abs(bg - hexrgb(pal[t]["background"])).sum()) for t in pal}
    check(f"{theme}: pill background is the theme background", min(dists, key=dists.get) == theme and dists[theme] < 0.12,
          f"distance {dists[theme]:.3f}")
    # And the waveform carries this theme's identity: the rim role (the
    # accent, or the theme's cool hue) covers a real share of the lit
    # pixels, more than any clearly different rim hue from another theme.
    wave_px = unpremul(frames[loud[::4]][:, WAVE[0], WAVE[1]]).reshape(-1, 3)
    diff = np.abs(wave_px - bg).sum(-1)
    chroma = wave_px.max(-1) - wave_px.min(-1)
    lit = wave_px[(diff > 0.08) & (chroma > 0.04)]
    lit_h = np.array([hue(px) for px in lit[:: max(1, len(lit) // 2000)]])
    def share(t):
        rh = hue(hexrgb(pal[t]["rim"]))
        return float(np.mean([hue_gap(h, rh) < 20 for h in lit_h]))
    own_rim = hue(hexrgb(pal[theme]["rim"]))
    others = [t for t in pal if hue_gap(hue(hexrgb(pal[t]["rim"])), own_rim) > 40]
    sh = {t: share(t) for t in [theme] + others}
    check(f"{theme}: waveform carries the theme's rim hue", sh[theme] > 0.1 and all(sh[theme] > sh[t] for t in others),
          " ".join(f"{t}={v:.2f}" for t, v in sh.items()))
    # Contrast: the lit waveform stands clear of the pill background.
    contrast = abs(float(luma(lit.mean(0))) - float(luma(bg)))
    check(f"{theme}: waveform contrast against the pill", contrast > 0.2, f"luma gap {contrast:.2f}")

    # Neon halo: a glow just outside the border, in the halo color, brighter
    # while speaking than in silence.
    halo_q = frames[quiet[5]][HALO]
    halo_l = frames[loud][:, HALO[0], HALO[1]].mean(0)
    hq, hl = halo_q[..., 3].mean(), halo_l[..., 3].mean()
    check(f"{theme}: neon halo outside the border", hq > 0.04, f"alpha {hq:.3f}")
    check(f"{theme}: halo brightens with the voice", hl > hq * 1.15, f"quiet {hq:.3f} loud {hl:.3f}")
    halo_col = unpremul(halo_l).reshape(-1, 3).mean(0)
    hd = hue_gap(hue(halo_col), hue(hexrgb(p["halo"])))
    check(f"{theme}: halo is the theme's halo hue", hd < 25, f"hue off by {hd:.0f} deg")

    # Grain: fine, bounded, moving noise over flat areas, no banding.
    # Grain changes 24 times a second, so compare frames 3 apart at 60 fps.
    a, b = frames[quiet[5]][FLAT][..., :3], frames[quiet[8]][FLAT][..., :3]
    spatial = float(a.std(axis=(0, 1)).mean())
    temporal = float(np.abs(a - b).mean())
    check(f"{theme}: film grain is present and subtle", 0.002 < spatial < 0.03 and 0.002 < temporal < 0.04,
          f"spatial {spatial:.4f} temporal {temporal:.4f}")

# Hot switch from a dark theme to a light one in the middle of speech.
meta, frames = load("switch")
tokyo_frames = loaded["tokyo"][1]
latte_bg, tokyo_bg = hexrgb(pal["latte"]["background"]), hexrgb(pal["tokyo"]["background"])
bgs = np.array([unpremul(f[FLAT]).reshape(-1, 3).mean(0) for f in frames])
before = np.abs(bgs[switch_at - 2] - tokyo_bg).sum()
settled = next(i for i in range(switch_at + 30, len(meta)) if meta[i]["appear"] > 0.99 and meta[i]["level"] < 0.05)
after = np.abs(bgs[settled] - latte_bg).sum()
check("switch: before the switch it matches the first theme", before < 0.12, f"{before:.3f}")
check("switch: after the switch it matches the second theme", after < 0.12, f"{after:.3f}")
check("switch: frames before the switch are identical to a plain render",
      np.abs(frames[:switch_at] - tokyo_frames[:switch_at]).max() < 1e-6)
blend = [i for i, m in enumerate(meta) if m["blending"]]
step = np.abs(np.diff(bgs[switch_at - 1:switch_at + 40], axis=0)).sum(-1).max()
check("switch: crossfades over about 0.4 s", 20 <= len(blend) <= 30, f"{len(blend)} frames")
check("switch: no jump between frames", step < 0.25, f"largest step {step:.3f}")
check("switch: stays on screen and keeps reacting",
      frames[switch_at:switch_at + 40, ..., 3].mean() > 0.4 and meta[switch_at + 20]["level"] > 0.05)

sys.exit(1 if failed else 0)
PYEOF

if [[ ${1:-} == --preview ]]; then
  for t in current tokyo gruvbox latte; do render "hq-$t" "${colors[$t]}" 2 1 & done
  render hq-switch "${colors[current]}" 2 1 "${colors[latte]}" &
  wait
  # Still: rest, soft speech, onset burst, loud speech, processing, one
  # column per theme: the current one, Tokyo Night, Gruvbox, Catppuccin Latte.
  picks=(40 120 330 410 500)
  cols=()
  for t in current tokyo gruvbox latte; do
    args=(); for f in "${picks[@]}"; do args+=(-i "$work/hq-$t/frame_$(printf %05d "$f").png"); done
    ffmpeg -v error -y "${args[@]}" -filter_complex "vstack=inputs=${#picks[@]}" "$work/col-$t.png"
    cols+=(-i "$work/col-$t.png")
  done
  ffmpeg -v error -y "${cols[@]}" -filter_complex hstack=inputs=4 /tmp/omavoice-animation-preview.png
  # Video: the current theme, Tokyo Night and Catppuccin Latte stacked, then
  # the current theme hot switching to Latte mid-speech.
  ffmpeg -v error -y -framerate 60 -i "$work/hq-current/frame_%05d.png" -framerate 60 -i "$work/hq-tokyo/frame_%05d.png" \
    -framerate 60 -i "$work/hq-latte/frame_%05d.png" -framerate 60 -i "$work/hq-switch/frame_%05d.png" \
    -filter_complex "[0][1][2][3]vstack=inputs=4,pad=ceil(iw/2)*2:ceil(ih/2)*2" \
    -c:v libx264 -pix_fmt yuv420p -crf 14 -movflags +faststart /tmp/omavoice-animation-preview.mp4
  echo "wrote /tmp/omavoice-animation-preview.png and /tmp/omavoice-animation-preview.mp4"
fi
exit $checks
