#!/usr/bin/env node
// Drives the overlay's signal model and state machine with fake microphone
// levels. No Qt, no microphone, no running Voxtype. Exit 0 when all pass.
import { readFileSync, readdirSync, existsSync } from "node:fs"
import vm from "node:vm"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(here, "../shell/omavoice.overlay/OverlayModel.js"), "utf8")
const M = {}
vm.runInNewContext(src.replace(/^\.pragma library.*$/m, ""), M)

let failed = 0
let passed = 0
function check(name, ok, detail = "") {
  if (ok) passed++
  else failed++
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  (" + detail + ")" : ""}`)
}

const DT = 1000 / 60
function run(st, seconds, peakAt) {
  const frames = []
  const n = Math.round(seconds * 1000 / DT)
  for (let i = 0; i < n; i++) {
    M.pushPeak(st, peakAt(i * DT / 1000))
    frames.push(M.tick(st, DT))
  }
  return frames
}
const dbToPeak = db => Math.pow(10, db / 20)
const max = (xs, f) => Math.max(...xs.map(f))
const mean = (xs, f) => xs.reduce((a, x) => a + f(x), 0) / xs.length

// ---- signal
{
  const st = M.createAnalyzer()
  const quiet = run(st, 2, () => dbToPeak(-62) * (1 + 0.1 * Math.random()))
  check("quiet room stays at rest", max(quiet.slice(30), f => f.level) < 0.05 && !quiet.at(-1).speaking,
    `max level ${max(quiet.slice(30), f => f.level).toFixed(3)}`)

  const loud = run(st, 0.2, () => dbToPeak(-14))
  const reach = loud.findIndex(f => f.level > 0.5)
  check("attack reacts within 100 ms", reach >= 0 && reach * DT <= 100, `${(reach * DT).toFixed(0)} ms`)
  check("speech gate opens", loud.at(-1).speaking && loud.at(-1).activity > 0.5)

  const after = run(st, 1.2, () => dbToPeak(-62))
  const fall = after.findIndex(f => f.level < 0.1)
  check("release settles within 600 ms", fall >= 0 && fall * DT <= 600, `${(fall * DT).toFixed(0)} ms`)
  check("gate closes after silence", !after.at(-1).speaking && after.at(-1).activity < 0.2)
}
{
  const st = M.createAnalyzer()
  run(st, 1, () => dbToPeak(-60))
  const soft = run(st, 1, () => dbToPeak(-30))
  const st2 = M.createAnalyzer()
  run(st2, 1, () => dbToPeak(-60))
  const hard = run(st2, 1, () => dbToPeak(-12))
  const a = mean(soft.slice(20), f => f.level), b = mean(hard.slice(20), f => f.level)
  check("louder speech draws bigger", b > a + 0.2, `soft ${a.toFixed(2)} loud ${b.toFixed(2)}`)
}
{
  // Syllables at 4.5 Hz: cadence should land near it.
  const st = M.createAnalyzer()
  run(st, 0.5, () => dbToPeak(-60))
  const f = run(st, 3, t => dbToPeak(-60) + 0.25 * Math.pow(Math.abs(Math.sin(Math.PI * t * 4.5)), 2))
  const hz = f.at(-1).cadenceHz
  check("cadence tracks syllable rate", hz > 3.2 && hz < 5.5, `${hz.toFixed(2)} Hz`)
  check("lobes show delayed history", f.some(x => Math.abs(x.amps[0] - x.amps[2]) > 0.15))
}
{
  // A steady hum should be absorbed into the noise floor.
  const st = M.createAnalyzer()
  const hum = run(st, 15, () => dbToPeak(-40))
  check("steady hum fades out", hum.at(-1).level < 0.1 && !hum.at(-1).speaking,
    `level ${hum.at(-1).level.toFixed(3)} floor ${hum.at(-1).floorDb.toFixed(1)} dB`)
}
{
  const st = M.createAnalyzer()
  for (const bad of [NaN, -1, 5, undefined, "x"]) M.pushPeak(st, bad)
  const f = M.tick(st, DT)
  check("garbage input stays finite", Number.isFinite(f.level) && f.level <= 1 && f.level >= 0)
}

// ---- state machine
{
  const T = M.PHASE_TIMING
  const np = M.nextPhase
  check("idle stays hidden", np("hidden", "idle", 0) === "hidden")
  check("recording opens", np("hidden", "recording", 0) === "recording")
  check("transcribing shows processing", np("recording", "transcribing", 0) === "processing")
  check("idle closes after processing", np("processing", "idle", 0) === "closing")
  check("cancel closes straight from recording", np("recording", "idle", 0) === "closing")
  check("closing finishes to hidden", np("closing", "idle", T.closeMs) === "hidden")
  check("mid-write empty read keeps phase", np("recording", "", 10) === "recording")
  check("daemon gone closes", np("recording", "missing", 0) === "closing")
  check("re-record while closing reopens", np("closing", "recording", 50) === "recording")
  check("stuck transcribing times out", np("processing", "transcribing", T.processingTimeoutMs) === "closing")
  check("late transcribing does not pop up", np("hidden", "transcribing", 0) === "hidden")
}
{
  // Full driver lifecycle with effects: mic only while recording, nothing after.
  const d = M.createDriver()
  const seen = []
  const fx = () => M.effectsOf(d.phase)
  M.setVoxState(d, "recording")
  check("driver opens on state change without a frame", d.phase === "recording" && fx().windowOpen && fx().monitorEnabled)
  for (let i = 0; i < 60; i++) seen.push(M.driverStep(d, DT, 0.2))
  check("appears within 250 ms", seen[15].appear > 0.95, `appear ${seen[15].appear.toFixed(2)}`)
  M.setVoxState(d, "transcribing")
  check("processing stops listening", d.phase === "processing" && !fx().monitorEnabled && fx().windowOpen)
  for (let i = 0; i < 30; i++) M.driverStep(d, DT, 0.9)
  check("peaks ignored outside recording", d.frame.level < 0.05, `level ${d.frame.level.toFixed(3)}`)
  M.setVoxState(d, "idle")
  let n = 0
  while (d.phase !== "hidden" && n < 120) { M.driverStep(d, DT, null); n++ }
  check("dismisses within 300 ms of idle", d.phase === "hidden" && n * DT <= 300, `${(n * DT).toFixed(0)} ms`)
  const e = fx()
  check("hidden releases window, mic and animation", !e.windowOpen && !e.monitorEnabled && !e.animating)
  check("opacity is zero when hidden", d.frame.appear === 0)
}
{
  const d = M.createDriver()
  M.setVoxState(d, "recording")
  let n = 0
  while (d.phase === "recording" && n < 100000) { M.driverStep(d, 250, 0); n++ }
  check("stale recording state gives up", d.phase !== "recording" && d.stale)
  for (let i = 0; i < 10; i++) M.driverStep(d, 100, 0)
  M.setVoxState(d, "recording")
  check("stale state stays hidden on re-read", d.phase === "hidden")
  M.setVoxState(d, "idle"); M.setVoxState(d, "recording")
  check("a real new recording clears stale", d.phase === "recording" && !d.stale)
}

// ---- theme
const themeFiles = {}
for (const dir of ["/usr/share/omarchy/themes", `${process.env.HOME}/.config/omarchy/themes`]) {
  if (!existsSync(dir)) continue
  for (const t of readdirSync(dir)) {
    const f = `${dir}/${t}/colors.toml`
    if (existsSync(f)) themeFiles[t] = f
  }
}
const paletteOf = t => M.paletteFrom(M.parseColorsToml(readFileSync(themeFiles[t], "utf8")))
const ROLES = ["core", "mid", "rim", "spark", "line", "halo", "edge", "background"]
{
  const latte = paletteOf("catppuccin-latte"), tokyo = paletteOf("tokyo-night")
  check("light theme detected", latte.dark === false)
  check("dark theme detected", tokyo.dark === true)
  check("mode falls back to lightness", M.paletteFrom({ background: "#fafafa", foreground: "#111111" }).dark === false)
  const empty = M.paletteFrom({})
  check("no theme file still gives a full palette", ROLES.every(r => /^#[0-9a-f]{6}$/i.test(empty[r])))
}
{
  const names = Object.keys(themeFiles)
  const bad = [], lowContrast = [], offHue = [], clashes = []
  for (const t of names) {
    const c = M.parseColorsToml(readFileSync(themeFiles[t], "utf8"))
    const p = M.paletteFrom(c)
    if (!ROLES.every(r => /^#[0-9a-f]{6}$/i.test(p[r]))) bad.push(t)
    const bgL = M.hexToOklch(p.background).L
    for (const r of ["core", "mid", "rim", "spark", "line", "halo"]) {
      const gap = Math.abs(M.hexToOklch(p[r]).L - bgL)
      if (gap < M.CONTRAST[r] - 0.01) lowContrast.push(`${t}.${r} ${gap.toFixed(2)}`)
    }
    if (p.source === "theme") {
      // Core and rim keep the hue of a color the theme actually defines
      // (a near-grey role has no meaningful hue).
      const own = Object.values(c).map(M.hexToOklch).filter(Boolean)
      for (const r of ["core", "rim"]) {
        const lch = M.hexToOklch(p[r])
        if (lch.C >= 0.05 && !own.some(x => x.C >= 0.02 && M.hueDist(x.h, lch.h) < 6)) offHue.push(`${t}.${r}`)
      }
      // When the theme offers two clearly different hues, core and rim use
      // different ones.
      const hs = M.candidatesOf(c).map(x => x.h)
      const varied = hs.some(a => hs.some(b => M.hueDist(a, b) > 40))
      const h = ["core", "rim"].map(r => M.hexToOklch(p[r]).h)
      if (varied && M.hueDist(h[0], h[1]) < 20) clashes.push(t)
    }
  }
  check(`every installed theme maps to valid colors (${names.length} themes)`, bad.length === 0, bad.join(" "))
  check("every role clears its contrast margin on every theme", lowContrast.length === 0, lowContrast.join(", "))
  check("core and rim use hues from the theme itself", offHue.length === 0, offHue.join(" "))
  check("core and rim use different hues when the theme has them", clashes.length === 0, clashes.join(" "))
}
{
  // Osaka Jade names a teal bright_magenta; roles go by hue, not name.
  const p = paletteOf("osaka-jade")
  check("roles follow hue, not key names", M.hueDist(M.hexToOklch(p.mid).h, M.hexToOklch("#d2689c").h) < 8,
    `mid ${p.mid}`)
  const acc = paletteOf("tokyo-night")
  check("the accent anchors the theme's identity", M.hueDist(M.hexToOklch(acc.rim).h, M.hexToOklch("#7aa2f7").h) < 6
    && M.hueDist(M.hexToOklch(acc.halo).h, M.hexToOklch("#7aa2f7").h) < 6, `rim ${acc.rim} halo ${acc.halo}`)
  const mono = M.paletteFrom({ background: "#000000", foreground: "#eeeeee", accent: "#8a8a8d" })
  check("monochrome themes stay monochrome", ["core", "mid", "rim", "halo"].every(r => M.hexToOklch(mono[r]).C < 0.03)
    && M.hexToOklch(mono.core).L > M.hexToOklch(mono.rim).L, `${mono.core} ${mono.rim}`)
  const dim = M.paletteFrom({ background: "#101010", foreground: "#cccccc", accent: "#202a44", blue: "#1a2238", red: "#301010" })
  const dimBg = M.hexToOklch("#101010").L
  check("dark accents are lifted clear of a dark background",
    M.hexToOklch(dim.rim).L - dimBg >= M.CONTRAST.rim - 0.01 && M.hexToOklch(dim.core).L - dimBg >= M.CONTRAST.core - 0.01)
}
{
  // Hot switching: instant while hidden, a short crossfade on screen.
  const a = paletteOf("tokyo-night"), b = paletteOf("catppuccin-latte")
  const d = M.createDriver()
  M.setPalette(d, a)
  M.setPalette(d, b)
  check("hidden theme change applies at once", d.palette === b && d.paletteT === 1)
  M.setPalette(d, a)
  M.setVoxState(d, "recording")
  for (let i = 0; i < 10; i++) M.driverStep(d, DT, 0.2)
  M.setPalette(d, b)
  const seen = []
  for (let i = 0; i < 40; i++) seen.push(M.driverStep(d, DT, 0.2).palette)
  const mid = seen[12]
  const bgL = x => M.hexToOklch(x.background).L
  check("visible theme change crossfades", mid !== a && mid !== b && bgL(mid) > bgL(a) && bgL(mid) < bgL(b),
    `mid background ${mid.background}`)
  const done = seen.findIndex(p => p === b)
  check("crossfade lands on the new theme in about 0.4 s", done > 0 && Math.abs(done * DT - M.THEME_BLEND_MS) < 40,
    `${(done * DT).toFixed(0)} ms`)
  const L = seen.map(bgL)
  check("crossfade is monotonic", L.every((v, i) => i === 0 || v >= L[i - 1] - 1e-9))
  check("audio keeps flowing during a theme change", seen.length === 40 && d.frame.level > 0.3)
  M.setPalette(d, a)
  M.driverStep(d, DT, 0.2)
  M.setVoxState(d, "idle")
  for (let i = 0; i < 40; i++) M.driverStep(d, DT, null)
  check("closing mid-crossfade finishes on the new theme", d.phase === "hidden" && d.palette === a && d.paletteT === 1)
  const c1 = M.paletteFrom(M.parseColorsToml(readFileSync(themeFiles["gruvbox"], "utf8")))
  const c2 = M.paletteFrom(M.parseColorsToml(readFileSync(themeFiles["gruvbox"], "utf8")))
  check("palette mapping is deterministic", JSON.stringify(c1) === JSON.stringify(c2))
}

// ---- fixture is deterministic
{
  const a = [], b = []
  for (let t = 0; t < M.FIXTURE_SECONDS; t += 0.05) { a.push(M.fixturePeak(t)); b.push(M.fixturePeak(t)) }
  check("fixture is deterministic", a.every((v, i) => v === b[i]))
}

// ---- overlay style setting
{
  const P = raw => M.parseSettings(raw)
  check("no style set means neon", P("name = \"Sam\"\ncleanup = true\n").style === "neon")
  check("overlay_style = \"trace\" picks trace", P("overlay_style = \"trace\"\n").style === "trace")
  check("a commented style line is ignored", P("# overlay_style = \"trace\"\n").style === "neon")
  check("an unknown style falls back to neon", P("overlay_style = \"sparkles\"\n").style === "neon")
  check("a trailing comment is allowed", P("overlay_style = \"trace\"  # cyberpunk\n").style === "trace")
  check("keys inside a [table] are ignored", P("[other]\noverlay_style = \"trace\"\noverlay = false\n").style === "neon" &&
    P("[other]\noverlay = false\n").enabled)
  const all = P("overlay = false\noverlay_position = \"bottom\"\noverlay_style = 'trace'\n")
  check("enabled, position and style parse together", !all.enabled && all.position === "bottom" && all.style === "trace")
}

// ---- trace (lie detector pen)
{
  const traceRun = () => {
    const d = M.createDriver()
    const out = []
    for (let i = 0; i < M.FIXTURE_SECONDS * 60; i++) {
      const t = i / 60
      M.setVoxState(d, M.fixtureVoxState(t))
      out.push(M.driverStep(d, DT, M.fixturePeak(t)))
    }
    return out
  }
  const frames = traceRun()
  const again = traceRun()
  const rec = frames.filter(f => f.phase === "recording" && f.appear > 0.99)
  // Silent for the whole half second of paper the checks look at.
  const quiet = rec.filter(f => {
    const i = frames.indexOf(f)
    return i > 36 && frames.slice(i - 36, i + 1).every(g => g.level < 0.03)
  })
  const loud = rec.filter(f => f.level > 0.6)
  const spread = f => Math.max(...f.trace.slice(1, 16).map(Math.abs))
  const jagged = f => f.trace.slice(1, 16).reduce((a, v, i, xs) => i ? a + Math.abs(v - xs[i - 1]) : a, 0)
  check("every frame carries 64 trace samples in -1..1", frames.every(f => f.trace.length === 64 && f.trace.every(v => v >= -1 && v <= 1)))
  check("silence draws a calm baseline", quiet.length > 10 && Math.max(...quiet.map(spread)) < 0.08,
    `max deflection ${Math.max(...quiet.map(spread)).toFixed(3)}`)
  check("loud speech swings the pen wide", loud.length > 10 && Math.max(...loud.map(spread)) > 0.6,
    `max deflection ${Math.max(...loud.map(spread)).toFixed(2)}`)
  check("louder is wilder: loud peaks are far more jagged than quiet",
    mean(loud, jagged) > 8 * Math.max(mean(quiet, jagged), 1e-3), `quiet ${mean(quiet, jagged).toFixed(3)} loud ${mean(loud, jagged).toFixed(2)}`)
  const soft = rec.filter(f => f.level > 0.15 && f.level < 0.35)
  check("soft speech sits between silence and loud", soft.length > 5 && mean(soft, jagged) > mean(quiet, jagged) && mean(soft, jagged) < mean(loud, jagged))
  // Paper scrolls: a committed sample moves one slot per step, unchanged.
  let scrolled = true
  for (let i = 1; i < frames.length; i++) {
    const a = frames[i - 1], b = frames[i]
    if (b.traceSeq === a.traceSeq + 1 && a.traceSeq > 0) scrolled = scrolled && b.trace[2] === a.trace[1] && b.trace[40] === a.trace[39]
    else if (b.traceSeq === a.traceSeq) scrolled = scrolled && b.trace[1] === a.trace[1] && b.traceShift >= a.traceShift
  }
  check("committed samples only scroll, they never redraw", scrolled)
  check("paper moves about 40 samples a second", Math.abs(frames[180].traceSeq - frames[120].traceSeq - 40) <= 1,
    `${frames[180].traceSeq - frames[120].traceSeq} in 1 s`)
  const proc = frames.filter(f => f.phase === "processing" && f.processing > 0.9)
  check("processing settles the pen", proc.length > 10 && Math.max(...proc.map(f => Math.abs(f.trace[0]))) < 0.1)
  check("trace is deterministic for a replay", frames.every((f, i) => f.trace.every((v, j) => v === again[i].trace[j])))
  const d = M.createDriver()
  M.setVoxState(d, "recording")
  for (let i = 0; i < 120; i++) M.driverStep(d, DT, 0.3)
  M.setVoxState(d, "idle")
  for (let i = 0; i < 40; i++) M.driverStep(d, DT, null)
  M.setVoxState(d, "recording")
  const first = M.driverStep(d, DT, 0.0016)
  check("a new recording starts from a flat trace", Math.max(...first.trace.map(Math.abs)) < 0.05 && first.traceSeq <= 1)
}

console.log(`\n${passed} passed, ${failed} failed`)
process.exit(failed ? 1 : 0)
