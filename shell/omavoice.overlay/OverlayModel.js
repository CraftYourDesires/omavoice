.pragma library
// Signal model and state machine for the omavoice recording overlay.
//
// Pure functions with no Qt dependencies, so the same file drives the live
// overlay (Service.qml), the offscreen preview renderer and the Node tests.
// Input is the microphone peak level only (0..1 linear, as reported by
// Quickshell's PwNodePeakMonitor). No audio samples ever reach this code.

var DEFAULTS = {
  floorDb: -58,        // starting noise floor estimate
  minFloorDb: -80,
  maxFloorDb: -28,
  floorRiseDbPerSec: 2.5, // the floor creeps up so a steady hum stops counting
  gateDb: 5,           // speech must clear the floor by this much
  spanDb: 42,          // dB above the gate that maps to full level before the ceiling has adapted
  // Loudness ceiling: follows your recent loud syllables (fast up, slow down)
  // so your normal voice lands mid-scale on any mic, and only speaking louder
  // than that reaches the top.
  ceilingAttackMs: 80,
  ceilingDecayDbPerSec: 2.5,
  ceilingMinSpanDb: 22,
  headroomDb: 9,
  curve: 1.5,          // >1 spreads quiet and normal speech further apart
  attackMs: 20,
  releaseMs: 110,
  slowMs: 420,
  speechThreshold: 0.1,
  holdMs: 320,         // speech gate hangover, bridges gaps between words
  activityUpMs: 90,
  activityDownMs: 520,
  intensityMs: 1400,
  onsetDelta: 0.12,    // rise from the last dip that counts as a new syllable
  onsetRefractoryMs: 110,
  cadenceWindowMs: 2400,
  lobeDelayMs: 105,    // each lobe pair away from the center shows the level this much earlier
  historyMs: 900
}

function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v) }

function smooth(current, target, dtMs, tauMs) {
  if (tauMs <= 0) return target
  return current + (target - current) * (1 - Math.exp(-dtMs / tauMs))
}

function createAnalyzer(options) {
  var o = {}
  for (var k in DEFAULTS) o[k] = DEFAULTS[k]
  if (options) for (var j in options) o[j] = options[j]
  return {
    opts: o,
    t: 0,
    pendingPeak: 0,
    hasPeak: false,
    floorDb: o.floorDb,
    ceilDb: o.floorDb + o.gateDb + o.spanDb - o.headroomDb,
    target: 0,
    env: 0,
    slow: 0,
    transient: 0,
    armed: true,
    valley: 0,
    crest: 0,
    holdUntil: -1,
    speaking: false,
    activity: 0,
    intensity: 0,
    onsets: [],
    lastOnset: -1e9,
    cadenceHz: 0,
    flow: 0,
    history: [],        // [{t, env}] newest last
    amps: [0, 0, 0, 0]
  }
}

// Record a raw peak reading. Readings between two frames are max-held so a
// short plosive between frames is not lost.
function pushPeak(st, peak) {
  var p = Number(peak)
  if (!isFinite(p) || p < 0) p = 0
  if (p > 1) p = 1
  st.pendingPeak = st.hasPeak ? Math.max(st.pendingPeak, p) : p
  st.hasPeak = true
}

function levelAt(st, t) {
  var h = st.history
  if (h.length === 0) return 0
  if (t >= h[h.length - 1].t) return h[h.length - 1].env
  if (t <= h[0].t) return h[0].env
  for (var i = h.length - 1; i > 0; i--) {
    var a = h[i - 1], b = h[i]
    if (t >= a.t) {
      var f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
      return a.env + (b.env - a.env) * f
    }
  }
  return h[0].env
}

// Advance the model by dtMs and return the values the renderer needs.
function tick(st, dtMs) {
  var o = st.opts
  var dt = clamp(Number(dtMs) || 0, 0, 250)
  st.t += dt

  var peak = st.hasPeak ? st.pendingPeak : 0
  st.hasPeak = false
  st.pendingPeak = 0
  var db = 20 * Math.log(Math.max(peak, 1e-5)) / Math.LN10

  // Noise floor: follow quiet moments quickly, creep up slowly otherwise.
  if (db < st.floorDb) st.floorDb = smooth(st.floorDb, db, dt, 180)
  else st.floorDb += o.floorRiseDbPerSec * dt / 1000
  st.floorDb = clamp(st.floorDb, o.minFloorDb, o.maxFloorDb)

  var gate = st.floorDb + o.gateDb
  if (db > st.ceilDb) st.ceilDb = smooth(st.ceilDb, db, dt, o.ceilingAttackMs)
  else st.ceilDb -= o.ceilingDecayDbPerSec * dt / 1000
  st.ceilDb = Math.max(st.ceilDb, gate + o.ceilingMinSpanDb)
  var raw = clamp((db - gate) / (st.ceilDb + o.headroomDb - gate), 0, 1)
  st.target = Math.pow(raw, o.curve)

  st.env = smooth(st.env, st.target, dt, st.target > st.env ? o.attackMs : o.releaseMs)
  st.slow = smooth(st.slow, st.env, dt, o.slowMs)
  st.transient = clamp(st.env - st.slow, 0, 1)

  if (st.target >= o.speechThreshold) st.holdUntil = st.t + o.holdMs
  st.speaking = st.t < st.holdUntil
  st.activity = smooth(st.activity, st.speaking ? 1 : 0, dt, st.speaking ? o.activityUpMs : o.activityDownMs)
  if (st.speaking) st.intensity = smooth(st.intensity, st.env, dt, o.intensityMs)
  else st.intensity = smooth(st.intensity, 0, dt, o.intensityMs * 2)

  // Cadence: syllable nuclei per second over a sliding window. A hysteresis
  // peak picker: a rise of onsetDelta from the last dip is an onset, and it
  // re-arms once the level falls onsetDelta below the crest that followed.
  if (st.armed) {
    st.valley = Math.min(st.valley, st.target)
    if (st.target - st.valley >= o.onsetDelta && st.target >= o.speechThreshold
        && st.t - st.lastOnset >= o.onsetRefractoryMs) {
      st.onsets.push(st.t)
      st.lastOnset = st.t
      st.armed = false
      st.crest = st.target
    }
  } else {
    st.crest = Math.max(st.crest, st.target)
    if (st.crest - st.target >= o.onsetDelta) {
      st.armed = true
      st.valley = st.target
    }
  }
  while (st.onsets.length && st.onsets[0] < st.t - o.cadenceWindowMs) st.onsets.shift()
  st.cadenceHz = smooth(st.cadenceHz, st.onsets.length / (o.cadenceWindowMs / 1000), dt, 600)

  // Flow speed follows how fast and how loud the speaker is.
  st.flow += dt / 1000 * (0.35 + 0.18 * st.cadenceHz + 0.9 * st.activity * (0.4 + st.intensity))

  st.history.push({ t: st.t, env: st.env })
  while (st.history.length > 2 && st.history[1].t < st.t - o.historyMs) st.history.shift()
  for (var k = 0; k < 4; k++) st.amps[k] = levelAt(st, st.t - k * o.lobeDelayMs)

  return frameOf(st)
}

function frameOf(st) {
  return {
    level: st.env,
    target: st.target,
    transient: st.transient,
    speaking: st.speaking,
    activity: st.activity,
    intensity: st.intensity,
    cadenceHz: st.cadenceHz,
    floorDb: st.floorDb,
    ceilDb: st.ceilDb,
    flow: st.flow,
    amps: st.amps.slice(0)
  }
}

// ---------------------------------------------------------------- state

// Overlay phases: hidden, recording, processing, closing.
// voxState is Voxtype's state file content: idle, recording, transcribing,
// "" (mid-write, ignore) or "missing" (daemon gone).
var PHASE_TIMING = {
  closeMs: 240,
  processingTimeoutMs: 90000,
  // Voxtype caps a recording at max_duration_secs (600 here). Well past that
  // the state file is stale (daemon killed mid-recording), so stop showing.
  recordingTimeoutMs: 660000
}

function normalizeVoxState(raw) {
  var s = String(raw === undefined || raw === null ? "" : raw).trim().toLowerCase()
  if (s === "") return ""
  if (s === "recording" || s === "transcribing" || s === "idle") return s
  if (s === "missing" || s === "stopped") return "missing"
  return "idle"
}

function nextPhase(phase, voxState, msInPhase, timing) {
  var tm = timing || PHASE_TIMING
  var v = normalizeVoxState(voxState)
  if (v === "") v = "keep"
  if (v === "recording") return "recording"
  if (v === "transcribing") {
    if (phase === "processing" && msInPhase >= tm.processingTimeoutMs) return "closing"
    if (phase === "closing") return msInPhase >= tm.closeMs ? "hidden" : "closing"
    if (phase === "hidden") return "hidden"
    return "processing"
  }
  if (v === "keep") {
    if (phase === "processing" && msInPhase >= tm.processingTimeoutMs) return "closing"
    if (phase === "closing" && msInPhase >= tm.closeMs) return "hidden"
    return phase
  }
  // idle or missing
  if (phase === "recording" || phase === "processing") return "closing"
  if (phase === "closing") return msInPhase >= tm.closeMs ? "hidden" : "closing"
  return "hidden"
}

// Everything the host should be doing in a phase. The mic is only listened
// to while recording; nothing runs once hidden.
function effectsOf(phase) {
  return {
    windowOpen: phase !== "hidden",
    monitorEnabled: phase === "recording",
    animating: phase !== "hidden"
  }
}

// ---------------------------------------------------------------- settings

var STYLES = ["neon", "trace", "scope", "clip"]

// The overlay's keys from ~/.config/voxtype/omavoice.toml. Commented lines
// and keys inside [tables] are ignored; anything unknown falls back.
function parseSettings(raw) {
  var text = String(raw || "")
  var top = text.split(/^\s*\[/m)[0]
  var out = { enabled: true, position: "top", style: "neon" }
  if (/^\s*overlay\s*=\s*false\b/m.test(top)) out.enabled = false
  var m = top.match(/^\s*overlay_position\s*=\s*["']?(top|bottom)["']?\s*(#.*)?$/m)
  if (m) out.position = m[1]
  var s = top.match(/^\s*overlay_style\s*=\s*["']([a-z]+)["']\s*(#.*)?$/m)
  if (s && STYLES.indexOf(s[1]) !== -1) out.style = s[1]
  return out
}

// ---------------------------------------------------------------- trace
//
// The "trace" style draws a lie detector pen: paper scrolls left, the pen
// sits at the right edge and swings with the voice. Each committed sample is
// the pen's deflection (-1..1) at that moment. values[0] is the live pen and
// moves every frame; values[1..] are committed and only scroll. Samples are
// seeded by their sequence number, so a replay draws the same trace.

var TRACE = {
  samples: 64,
  stepMs: 1000 / 40,   // paper speed: 40 samples a second, about 1.5 s on screen
  swingHz: 5.2,        // how fast the pen swings while transcribing
  tremor: 0.035        // calm baseline wobble in silence
}

function traceHash(n) {
  var x = Math.sin(n * 91.3458 + 47.853) * 43758.5453
  return x - Math.floor(x)
}

function createTrace() {
  var values = []
  for (var i = 0; i < TRACE.samples; i++) values.push(0)
  // levels: the voice level per paper step, newest (live) first. The center
  // out styles draw this history instead of the pen.
  return { values: values, levels: values.slice(0), seq: 0, acc: 0, phase: 0 }
}

// Pen deflection for sample `seq` from the current voice frame. The pen
// zigzags with a random reach on every sample and its height is the voice
// level right then, so every syllable draws its own burst: soft words stay
// low, stressed ones jump, and pauses go flat.
function traceValue(tr, seq, frame, processing, phase) {
  var lvl = clamp(frame.level || 0, 0, 1)
  var r1 = traceHash(seq), r2 = traceHash(seq * 1.618 + 3.1), r3 = traceHash(seq * 0.731 + 11.7)
  var calm = TRACE.tremor * (r1 - 0.5) * 2 * (1 - 0.6 * processing)
  var sign = seq % 2 === 0 ? 1 : -1
  // Now and then the pen holds its side for a sample, so the bursts are not
  // a perfectly regular comb.
  if (r3 < 0.18) sign = -sign
  var reach = 0.35 + 0.65 * r2
  var kick = (frame.transient || 0) > 0.05 && r1 > 0.6 ? clamp(frame.transient * 1.2, 0, 0.2) : 0
  var v = calm + sign * clamp(lvl * reach * 0.9 + kick, 0, 1) * (1 - processing)
  // While transcribing the pen settles into a slow, small sine.
  v += processing * 0.07 * Math.sin(phase)
  return clamp(v, -1, 1)
}

function stepTrace(tr, dtMs, frame, processing) {
  tr.acc += dtMs
  var rate = TRACE.swingHz * 0.25
  while (tr.acc >= TRACE.stepMs) {
    tr.acc -= TRACE.stepMs
    tr.seq++
    tr.phase += 2 * Math.PI * rate * TRACE.stepMs / 1000 * (0.75 + 0.5 * traceHash(tr.seq + 0.5))
    tr.values.pop()
    tr.values.splice(1, 0, traceValue(tr, tr.seq, frame, processing, tr.phase))
    tr.levels.pop()
    tr.levels.splice(1, 0, (frame.level || 0) * (1 - processing))
  }
  tr.levels[0] = (frame.level || 0) * (1 - processing)
  // The live pen heads toward the value it will commit next.
  var next = traceValue(tr, tr.seq + 1, frame, processing, tr.phase + 2 * Math.PI * rate * TRACE.stepMs / 1000)
  tr.values[0] = tr.values[1] + (next - tr.values[1]) * (tr.acc / TRACE.stepMs)
  return { values: tr.values.slice(0), levels: tr.levels.slice(0), shift: tr.acc / TRACE.stepMs, seq: tr.seq }
}

// ---------------------------------------------------------------- driver

// The per-frame host logic, shared by the live overlay and the preview
// renderer so both draw exactly the same thing from the same inputs.
function createDriver(options) {
  return {
    options: options || null,
    phase: "hidden",
    msInPhase: 0,
    voxState: "idle",
    stale: false,
    time: 0,
    appear: 0,
    processing: 0,
    analyzer: createAnalyzer(options),
    trace: createTrace(),
    palette: null,
    paletteFrom: null,
    paletteTo: null,
    paletteT: 1,
    frame: null
  }
}

// Feed Voxtype's state and re-evaluate the phase right away (no frame
// needed, so a hidden overlay wakes up on the state change itself).
// Returns true when the phase changed.
function setVoxState(drv, raw) {
  var v = normalizeVoxState(raw)
  if (v !== "" && v !== drv.voxState) {
    drv.voxState = v
    drv.stale = false
  }
  return advancePhase(drv, 0)
}

function advancePhase(drv, dt) {
  drv.msInPhase += dt
  if (drv.phase === "recording" && drv.msInPhase >= PHASE_TIMING.recordingTimeoutMs) drv.stale = true
  var np = nextPhase(drv.phase, drv.stale ? "idle" : drv.voxState, drv.msInPhase)
  if (np === drv.phase) return false
  if (drv.phase === "hidden" && np !== "hidden") {
    drv.analyzer = createAnalyzer(drv.options)
    drv.trace = createTrace()
    drv.appear = 0
    drv.processing = 0
  }
  drv.phase = np
  drv.msInPhase = 0
  return true
}

// One animation frame. `peak` is the latest microphone peak, or null when
// no reading arrived; it is ignored outside the recording phase.
function driverStep(drv, dtMs, peak) {
  var dt = clamp(Number(dtMs) || 0, 0, 250)
  advancePhase(drv, dt)
  if (drv.phase === "recording" && peak !== null && peak !== undefined) pushPeak(drv.analyzer, peak)
  var frame = tick(drv.analyzer, dt)
  var shown = drv.phase === "recording" || drv.phase === "processing"
  drv.appear = smooth(drv.appear, shown ? 1 : 0, dt, shown ? 55 : 65)
  if (drv.phase === "hidden") {
    drv.appear = 0
    if (drv.paletteT < 1) { drv.paletteT = 1; drv.palette = drv.paletteTo }
  }
  drv.processing = smooth(drv.processing, drv.phase === "processing" ? 1 : 0, dt, 160)
  var tr = stepTrace(drv.trace, dt, frame, drv.processing)
  frame.trace = tr.values
  frame.levels = tr.levels
  frame.traceShift = tr.shift
  frame.traceSeq = tr.seq
  drv.time += dt / 1000
  stepPalette(drv, dt)
  frame.palette = drv.palette
  frame.phase = drv.phase
  frame.appear = drv.appear
  frame.processing = drv.processing
  frame.time = drv.time
  drv.frame = frame
  return frame
}

// ---------------------------------------------------------------- theme
//
// Every color the overlay draws comes from the current Omarchy theme's
// colors.toml. Roles are picked by perceived hue and chroma (OKLCH), not by
// key name, because themes reuse names loosely (Osaka Jade's bright_magenta
// is teal). Each role is then nudged in lightness until it clears the
// background by a fixed perceptual margin, keeping its hue, so the overlay
// stays legible on any palette, light or dark.

function parseColorsToml(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6}|light|dark)["']?/)
    if (m) out[m[1]] = m[2]
  }
  return out
}

function hexToRgb(hex) {
  var h = String(hex || "").replace("#", "")
  if (!/^[0-9A-Fa-f]{6}$/.test(h)) return null
  return [parseInt(h.slice(0, 2), 16) / 255, parseInt(h.slice(2, 4), 16) / 255, parseInt(h.slice(4, 6), 16) / 255]
}

function rgbToHex(rgb) {
  var out = "#"
  for (var i = 0; i < 3; i++) {
    var v = Math.round(clamp(rgb[i], 0, 1) * 255)
    out += (v < 16 ? "0" : "") + v.toString(16)
  }
  return out
}

function toLinear(c) { return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4) }
function toGamma(c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055 }

// sRGB 0..1 to OKLab [L, a, b] (Bjorn Ottosson's matrices).
function rgbToOklab(rgb) {
  var r = toLinear(rgb[0]), g = toLinear(rgb[1]), b = toLinear(rgb[2])
  var l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  var m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  var s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
  ]
}

// OKLab to linear-free sRGB 0..1, unclamped (may be out of gamut).
function oklabToRgb(lab) {
  var l = Math.pow(lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2], 3)
  var m = Math.pow(lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2], 3)
  var s = Math.pow(lab[0] - 0.0894841775 * lab[1] - 1.291485548 * lab[2], 3)
  return [
    toGamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    toGamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    toGamma(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s)
  ]
}

function hexToOklch(hex) {
  var rgb = hexToRgb(hex)
  if (!rgb) return null
  var lab = rgbToOklab(rgb)
  var h = Math.atan2(lab[2], lab[1]) * 180 / Math.PI
  return { L: lab[0], C: Math.sqrt(lab[1] * lab[1] + lab[2] * lab[2]), h: h < 0 ? h + 360 : h }
}

function inGamut(rgb) {
  var e = 1e-4
  return rgb[0] >= -e && rgb[0] <= 1 + e && rgb[1] >= -e && rgb[1] <= 1 + e && rgb[2] >= -e && rgb[2] <= 1 + e
}

// OKLCH to hex, keeping L and h and lowering chroma until it fits sRGB.
function oklchToHex(L, C, h) {
  var rad = h * Math.PI / 180
  var lo = 0, hi = Math.max(C, 0)
  var rgb = oklabToRgb([L, hi * Math.cos(rad), hi * Math.sin(rad)])
  if (inGamut(rgb)) return rgbToHex(rgb)
  for (var i = 0; i < 18; i++) {
    var mid = (lo + hi) / 2
    if (inGamut(oklabToRgb([L, mid * Math.cos(rad), mid * Math.sin(rad)]))) lo = mid
    else hi = mid
  }
  return rgbToHex(oklabToRgb([L, lo * Math.cos(rad), lo * Math.sin(rad)]))
}

function hueDist(a, b) {
  var d = Math.abs(a - b) % 360
  return d > 180 ? 360 - d : d
}

function mixHex(a, b, f) {
  var x = hexToRgb(a), y = hexToRgb(b)
  if (!x || !y) return a
  var la = rgbToOklab(x), lb = rgbToOklab(y)
  return rgbToHex(oklabToRgb([la[0] + (lb[0] - la[0]) * f, la[1] + (lb[1] - la[1]) * f, la[2] + (lb[2] - la[2]) * f]))
}

// Reference hues in OKLCH degrees: the waveform's warm orange core, its pink
// middle and its cobalt rim.
var ROLE_HUES = { warm: 55, mid: 350, cool: 255 }
var PALETTE_KEYS = ["accent", "red", "orange", "yellow", "green", "cyan", "blue", "magenta",
  "bright_red", "bright_yellow", "bright_green", "bright_cyan", "bright_blue", "bright_magenta",
  "color1", "color2", "color3", "color4", "color5", "color6",
  "color9", "color10", "color11", "color12", "color13", "color14"]
// Minimum OKLab lightness distance from the background, per role.
var CONTRAST = { core: 0.34, mid: 0.3, rim: 0.28, spark: 0.45, line: 0.42, halo: 0.36 }

function candidatesOf(c) {
  var out = []
  var seen = {}
  for (var i = 0; i < PALETTE_KEYS.length; i++) {
    var hex = c[PALETTE_KEYS[i]]
    if (!hex || seen[String(hex).toLowerCase()]) continue
    var lch = hexToOklch(hex)
    if (!lch || lch.C < 0.045) continue
    seen[String(hex).toLowerCase()] = true
    lch.hex = String(hex).toLowerCase()
    lch.key = PALETTE_KEYS[i]
    out.push(lch)
  }
  return out
}

// Best candidate near a target hue, weighted by chroma, skipping hues too
// close to roles already taken.
function pickNear(cands, hue, width, taken) {
  var best = null, bestScore = 0
  for (var i = 0; i < cands.length; i++) {
    var c = cands[i]
    var clash = false
    for (var j = 0; j < taken.length; j++) if (taken[j] && hueDist(c.h, taken[j].h) < 28) clash = true
    if (clash) continue
    var d = hueDist(c.h, hue) / width
    var score = Math.min(c.C, 0.2) * Math.exp(-d * d)
    if (score > bestScore) { best = c; bestScore = score }
  }
  return bestScore > 0.004 ? best : null
}

// Keep hue and chroma, move lightness away from the background by `delta`.
function fitRole(lch, bgL, light, delta, extraL) {
  var L = clamp(lch.L, 0.22, 0.95) + (extraL || 0)
  if (light) L = Math.min(L, bgL - delta)
  else L = Math.max(L, bgL + delta)
  L = clamp(L, 0.22, 0.95)
  return oklchToHex(L, lch.C, lch.h)
}

function median(xs) {
  if (!xs.length) return 0
  var s = xs.slice(0).sort(function(a, b) { return a - b })
  return s[Math.floor(s.length / 2)]
}

// Map an Omarchy colors.toml onto the overlay's roles.
function paletteFrom(colors) {
  var c = colors || {}
  var bg = hexToRgb(c.background) ? c.background : (hexToRgb(c.color0) ? c.color0 : "#15171b")
  var bgLch = hexToOklch(bg)
  var light = c.mode === "light" || c.mode === "dark" ? c.mode === "light" : bgLch.L > 0.6
  var fg = hexToRgb(c.foreground) ? c.foreground : (hexToRgb(c.color7) ? c.color7 : (light ? "#202020" : "#d8d8d8"))
  var cands = candidatesOf(c)
  var chroma = median(cands.map(function(x) { return x.C }))
  var accent = hexToOklch(c.accent || c.color4 || "") || null
  // A near-grey accent still tints the halo, but only a clearly colored one
  // anchors the waveform.
  var accentChromatic = accent && accent.C >= 0.035
  var accentAnchors = accent && accent.C >= 0.07

  // The accent is the theme's identity, so it anchors whichever end of the
  // warm to cool range it sits closer to.
  var core = null, rim = null
  if (accentAnchors) {
    if (hueDist(accent.h, ROLE_HUES.warm) < hueDist(accent.h, ROLE_HUES.cool) - 20) core = accent
    else rim = accent
  }
  if (!rim) rim = pickNear(cands, ROLE_HUES.cool, 70, [core])
  if (!core) core = pickNear(cands, ROLE_HUES.warm, 55, [rim])
  // A theme without warm (or without cool) hues keeps its own character:
  // take its most colorful remaining hue instead of inventing one.
  if (!core) core = pickNear(cands, rim ? rim.h : 0, 1e9, [rim])
  if (!rim) rim = pickNear(cands, core ? core.h : 0, 1e9, [core])
  // Still missing a role (a theme with one hue, or none): stay inside the
  // theme rather than inventing a color it does not have. The rim falls
  // back to the accent, however grey, and the core to the foreground.
  var fgLch = hexToOklch(fg)
  if (!rim) rim = accent && !(core && accent.h === core.h && accent.C === core.C) ? accent : fgLch
  if (!core) core = fgLch
  var mid = pickNear(cands, ROLE_HUES.mid, 50, [core, rim])
  if (!mid) {
    // Halfway from core to rim, the long way round through magenta.
    var ch = core.h, rh = rim.h
    var cw = ((ch - rh) % 360 + 360) % 360
    mid = { L: (core.L + rim.L) / 2, C: (core.C + rim.C) / 2, h: (rh + cw / 2) % 360 }
  }
  var halo = accentChromatic ? accent : rim
  var mono = cands.length === 0
  // Monochrome themes get depth from lightness instead: bright core, dimmer
  // rim.
  var step = mono ? (light ? 0.14 : -0.1) : 0

  return {
    dark: !light,
    bgLum: bgLch.L,
    background: bg,
    edge: mixHex(bg, fg, light ? 0.22 : 0.16),
    core: fitRole(core, bgLch.L, light, CONTRAST.core),
    mid: fitRole(mid, bgLch.L, light, CONTRAST.mid, step),
    rim: fitRole(rim, bgLch.L, light, CONTRAST.rim, step * 2),
    // Electric spark: the rim hue pushed toward white on dark themes and
    // toward ink on light ones.
    spark: fitRole({ L: rim.L, C: rim.C * 0.75, h: rim.h }, bgLch.L, light, CONTRAST.spark, light ? -0.1 : 0.2),
    line: fitRole(fgLch, bgLch.L, light, CONTRAST.line),
    halo: fitRole({ L: halo.L, C: mono ? halo.C : Math.max(halo.C * 1.15, 0.05), h: halo.h }, bgLch.L, light, CONTRAST.halo),
    accent: c.accent || fg,
    source: mono ? "monochrome" : "theme"
  }
}

var PALETTE_COLOR_ROLES = ["background", "edge", "core", "mid", "rim", "spark", "line", "halo"]

// Blend two palettes in OKLab. Used to crossfade when the theme changes
// while the overlay is on screen.
function mixPalette(a, b, t) {
  if (!a) return b
  if (!b) return a
  if (t >= 1) return b
  if (t <= 0) return a
  var out = {}
  for (var k in b) out[k] = b[k]
  for (var i = 0; i < PALETTE_COLOR_ROLES.length; i++) {
    var r = PALETTE_COLOR_ROLES[i]
    out[r] = mixHex(a[r], b[r], t)
  }
  out.bgLum = a.bgLum + (b.bgLum - a.bgLum) * t
  out.dark = t < 0.5 ? a.dark : b.dark
  return out
}

var THEME_BLEND_MS = 420

// Hand the driver a new palette. While hidden it switches at once; on
// screen it crossfades over THEME_BLEND_MS, driven by driverStep.
function setPalette(drv, pal) {
  if (!pal) return
  if (!drv.palette || drv.phase === "hidden") {
    drv.palette = pal
    drv.paletteFrom = pal
    drv.paletteTo = pal
    drv.paletteT = 1
    return
  }
  drv.paletteFrom = drv.palette
  drv.paletteTo = pal
  drv.paletteT = 0
}

function stepPalette(drv, dt) {
  if (drv.paletteT >= 1 || !drv.paletteTo) return
  drv.paletteT = Math.min(1, drv.paletteT + dt / THEME_BLEND_MS)
  var e = drv.paletteT * drv.paletteT * (3 - 2 * drv.paletteT)
  drv.palette = drv.paletteT >= 1 ? drv.paletteTo : mixPalette(drv.paletteFrom, drv.paletteTo, e)
}

// ---------------------------------------------------------------- fixture

// Deterministic synthetic microphone peaks for tests and previews: a quiet
// room, then two spoken phrases at about 4.5 syllables per second, a pause,
// and a louder emphatic phrase. Seeded, so every run is identical.
function fixturePeak(tSec) {
  function hash(n) {
    var x = Math.sin(n * 127.1 + 311.7) * 43758.5453
    return x - Math.floor(x)
  }
  var noise = 0.0016 + 0.0009 * hash(Math.floor(tSec * 90))
  var phrases = [
    { start: 0.8, end: 2.6, rate: 4.6, gain: 0.16 },
    { start: 3.0, end: 4.4, rate: 4.2, gain: 0.22 },
    { start: 5.3, end: 7.2, rate: 5.0, gain: 0.42 }
  ]
  var v = noise
  for (var i = 0; i < phrases.length; i++) {
    var p = phrases[i]
    if (tSec < p.start || tSec > p.end) continue
    var local = tSec - p.start
    var syll = Math.floor(local * p.rate)
    var phase = local * p.rate - syll
    var shape = Math.pow(Math.sin(Math.PI * phase), 1.6)
    var stress = 0.45 + 0.55 * hash(syll + i * 17)
    var fade = Math.min(1, local / 0.12, (p.end - tSec) / 0.2)
    v = Math.max(v, p.gain * stress * shape * fade + noise)
  }
  return v
}

// Voxtype state for the preview timeline.
function fixtureVoxState(tSec) {
  if (tSec < 0.15) return "idle"
  if (tSec < 7.6) return "recording"
  if (tSec < 8.9) return "transcribing"
  return "idle"
}

var FIXTURE_SECONDS = 9.6
