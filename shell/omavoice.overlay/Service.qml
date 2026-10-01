import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import "OverlayModel.js" as Model

// omavoice recording overlay, hosted inside omarchy-shell as a service.
//
// While idle this is one inotify watch on Voxtype's state file and nothing
// else: no window, no microphone stream, no animation timer. When Voxtype
// starts recording it opens a small click-through layer surface on the
// focused monitor, listens to the default PipeWire source's peak level (a
// separate monitor stream; Voxtype's own capture is untouched), and animates
// until Voxtype is idle again. Only peak levels are read; no audio is stored.
Item {
  id: root

  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string themeDir: stateHome + "/omarchy/current/theme"
  // Tests point this at a scratch folder, like dictation-cleanup's override.
  readonly property string configDir: Quickshell.env("OMAVOICE_CONFIG_DIR") || (home + "/.config/voxtype")

  property var driver: Model.createDriver()
  property string phase: "hidden"
  property var frame: Model.driverStep(Model.createDriver(), 0, null)
  readonly property var effects: Model.effectsOf(phase)

  // ~/.config/voxtype/omavoice.toml: overlay = false turns it off,
  // overlay_position = "bottom" moves it to the bottom edge, overlay_style
  // picks "neon" (Visualizer.qml), "trace" (TraceVisualizer.qml), or "scope"
  // and "clip" (WaveVisualizer.qml).
  property bool overlayEnabled: true
  property string position: "top"
  property string overlayStyle: "neon"
  property var themePalette: Model.paletteFrom({})
  property string themeName: ""
  property string themeRaw: ""
  property int themeLoads: 0
  property int themeRetries: 0
  property string screenName: ""

  // Test and preview hooks (IPC `omavoice simulate`). Never active while
  // Voxtype is really recording.
  property bool simulating: false
  property var simPeaks: []
  property var simStates: []
  property real simFps: 60
  property real simClock: 0
  property bool simFixture: false

  property real pendingPeak: -1
  property int peakUpdates: 0
  property int framesDrawn: 0
  property real frameAccum: 0
  property real fps: 0
  property int fpsFrames: 0
  property real fpsClock: 0

  readonly property var defaultSource: Pipewire.defaultAudioSource
  // Hardware capture nodes (not streams, not sinks, not virtual).
  readonly property var hardwareSources: {
    var out = []
    var nodes = Pipewire.nodes.values
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || n.isStream || n.isSink || !n.audio) continue
      var p = n.properties || {}
      if (p["media.class"] === "Audio/Source") out.push(n)
    }
    return out
  }
  // The node to meter. Voxtype records the default source. A virtual default
  // (EasyEffects' filtered mic) reports no peaks to PwNodePeakMonitor, so
  // meter the hardware mic behind it instead: the highest priority one, which
  // is the one EasyEffects and WirePlumber pick by default. Either way this
  // is a separate read-only stream; Voxtype's capture is untouched.
  readonly property var source: {
    var src = defaultSource
    if (!src) return null
    var props = src.properties || {}
    var virtual = props["node.virtual"] === true || props["node.virtual"] === "true"
      || String(props["media.class"] || "").indexOf("Virtual") !== -1
    if (!virtual) return src
    var best = null
    var bestPriority = -1e9
    for (var i = 0; i < hardwareSources.length; i++) {
      var pr = Number((hardwareSources[i].properties || {})["priority.session"] || 0)
      if (pr > bestPriority) { best = hardwareSources[i]; bestPriority = pr }
    }
    return best || src
  }
  readonly property bool listening: effects.monitorEnabled && !simulating && !!source

  function applyVoxState(raw) {
    var value = String(raw || "").trim()
    if (!overlayEnabled && value === "recording") value = "idle"
    Model.setVoxState(driver, value)
    syncPhase()
    // An empty read means we caught Voxtype mid-write; look again shortly.
    if (value === "") rereadTimer.restart()
  }

  function syncPhase() {
    var next = driver.phase
    if (next === phase) return
    if (phase === "hidden") prepareOpen()
    phase = next
    if (next === "hidden") {
      pendingPeak = -1
      frameAccum = 0
      if (simulating) stopSimulation()
    }
  }

  // A new colors.toml text: map it to overlay roles and hand it to the
  // driver, which crossfades if the overlay is on screen.
  function applyTheme(raw) {
    var text = String(raw || "")
    if (text.trim() === "") { themeRetry.restart(); return }
    themeRetries = 0
    if (text === themeRaw) return
    themeRaw = text
    themePalette = Model.paletteFrom(Model.parseColorsToml(text))
    Model.setPalette(driver, themePalette)
    if (!driver.frame || phase === "hidden") frame = Model.driverStep(driver, 0, null)
    themeLoads++
  }

  // Omarchy switches themes by deleting the theme directory and moving a new
  // one in its place, which silently ends a watch on the old colors.toml.
  // So re-point the watch at the path again every time, and let theme.name
  // (rewritten in place in the stable parent directory) be the trigger.
  function rearmTheme() {
    themeFile.path = ""
    themeFile.path = root.themeDir + "/colors.toml"
    themeFile.reload()
  }

  function prepareOpen() {
    rearmTheme()
    // focusedMonitor is event-driven and can still be null in a fresh shell,
    // so fall back to the monitor list's focused flag.
    var monitor = Hyprland.focusedMonitor
    if (!monitor) {
      var list = Hyprland.monitors.values
      for (var i = 0; i < list.length; i++) if (list[i].focused) monitor = list[i]
    }
    screenName = monitor ? String(monitor.name || "") : ""
    fps = 0
    fpsFrames = 0
    fpsClock = 0
  }

  function targetScreen() {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === screenName) return screens[i]
    }
    return screens.length ? screens[0] : null
  }

  function step(dtMs) {
    var peak = null
    if (simulating) {
      simClock += dtMs
      var t = simClock / 1000
      if (simFixture) {
        Model.setVoxState(driver, Model.fixtureVoxState(t))
        peak = Model.fixturePeak(t)
      } else {
        var idx = Math.floor(t * simFps)
        if (simPeaks.length) peak = simPeaks[Math.min(idx, simPeaks.length - 1)]
        for (var i = simStates.length - 1; i >= 0; i--) {
          if (t >= simStates[i][0]) { Model.setVoxState(driver, simStates[i][1]); break }
        }
      }
    } else if (pendingPeak >= 0) {
      peak = pendingPeak
      pendingPeak = -1
    }
    frame = Model.driverStep(driver, dtMs, peak)
    framesDrawn++
    fpsFrames++
    fpsClock += dtMs
    if (fpsClock >= 1000) {
      fps = fpsFrames * 1000 / fpsClock
      fpsFrames = 0
      fpsClock = 0
    }
    syncPhase()
  }

  function startSimulation(payload) {
    if (driver.voxState === "recording" || driver.voxState === "transcribing") return "busy: dictation in progress"
    var p = {}
    if (payload === "fixture") {
      p.fixture = true
    } else {
      try { p = JSON.parse(payload || "{}") } catch (e) { return "error: payload is not JSON" }
    }
    simFixture = p.fixture === true
    simPeaks = Array.isArray(p.peaks) ? p.peaks : []
    simStates = Array.isArray(p.states) ? p.states : [[0, "recording"]]
    simFps = Number(p.fps) > 0 ? Number(p.fps) : 60
    simClock = 0
    simulating = true
    Model.setVoxState(driver, simFixture ? Model.fixtureVoxState(0.2) : simStates[0][1])
    syncPhase()
    return "ok"
  }

  function stopSimulation() {
    if (!simulating) return "ok"
    simulating = false
    simFixture = false
    simPeaks = []
    simStates = []
    // Hand control back to the real Voxtype state.
    Model.setVoxState(driver, "idle")
    syncPhase()
    stateFile.reload()
    return "ok"
  }

  function statusJson() {
    return JSON.stringify({
      phase: phase,
      voxState: driver.voxState,
      stale: driver.stale,
      enabled: overlayEnabled,
      position: position,
      style: overlayStyle,
      simulating: simulating,
      windowOpen: windowLoader.active && !!windowLoader.item,
      listening: peakMonitor.enabled,
      animating: frameLoop.running,
      sourceReady: !!source,
      meteredSource: source ? String(source.name || "") : "",
      defaultSource: defaultSource ? String(defaultSource.name || "") : "",
      screen: screenName,
      fps: Math.round(fps * 10) / 10,
      framesDrawn: framesDrawn,
      peakUpdates: peakUpdates,
      level: Math.round(frame.level * 1000) / 1000,
      activity: Math.round(frame.activity * 1000) / 1000,
      speaking: !!frame.speaking,
      cadenceHz: Math.round(frame.cadenceHz * 100) / 100,
      appear: Math.round(frame.appear * 1000) / 1000,
      dark: themePalette.dark !== false,
      theme: {
        name: themeName,
        loads: themeLoads,
        source: themePalette.source,
        bgLum: Math.round(themePalette.bgLum * 1000) / 1000,
        core: themePalette.core,
        mid: themePalette.mid,
        rim: themePalette.rim,
        halo: themePalette.halo,
        shown: driver.palette ? driver.palette.core : "",
        blending: driver.paletteT < 1
      }
    })
  }

  FileView {
    id: stateFile
    path: root.runtimeDir + "/voxtype/state"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var value = text()
      // Real dictation always wins over a test simulation.
      if (root.simulating && /recording|transcribing/.test(value)) root.stopSimulation()
      else if (!root.simulating) root.applyVoxState(value)
    }
    onLoadFailed: if (!root.simulating) root.applyVoxState("missing")
  }

  Timer {
    id: rereadTimer
    interval: 40
    onTriggered: stateFile.reload()
  }

  // Belt and braces while visible: re-read the state once a second so a
  // missed change notification can never leave the overlay stuck on screen.
  Timer {
    interval: 1000
    repeat: true
    running: root.phase !== "hidden" && !root.simulating
    onTriggered: stateFile.reload()
  }

  FileView {
    id: settingsFile
    path: root.configDir + "/omavoice.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var s = Model.parseSettings(text())
      root.overlayEnabled = s.enabled
      root.position = s.position
      root.overlayStyle = s.style
    }
    onLoadFailed: {
      root.overlayEnabled = true
      root.position = "top"
      root.overlayStyle = "neon"
    }
  }

  // The current theme's colors, live. Both watches are inotify only; no
  // timers run while idle.
  FileView {
    id: themeFile
    path: root.themeDir + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: themeSettle.restart()
    onLoaded: root.applyTheme(text())
    // Mid-swap the directory can be briefly missing: try again shortly.
    onLoadFailed: themeRetry.restart()
  }

  FileView {
    id: themeNameFile
    path: root.stateHome + "/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.themeName = text().trim()
      themeSettle.restart()
    }
  }

  // Coalesce the burst of events a theme switch makes.
  Timer {
    id: themeSettle
    interval: 60
    onTriggered: root.rearmTheme()
  }

  Timer {
    id: themeRetry
    interval: 100
    onTriggered: {
      if (root.themeRetries >= 30) return
      root.themeRetries++
      root.rearmTheme()
    }
  }

  // Keeping the default source bound only tracks its metadata; audio flows
  // only while the peak monitor below is enabled.
  PwObjectTracker {
    objects: root.defaultSource ? [root.defaultSource].concat(root.hardwareSources) : root.hardwareSources
  }

  PwNodePeakMonitor {
    id: peakMonitor
    node: root.source
    enabled: root.listening
    onPeakChanged: {
      if (!enabled) return
      // Quickshell reports peaks on PipeWire's cubic volume scale (a quiet
      // room reads about 0.045, which looks like -27 dB). The model expects
      // linear amplitude, so cube it back (about -80 dB), or silence pins
      // the level near 1 and the pen swings whether you talk or not.
      root.pendingPeak = Math.max(root.pendingPeak, peak * peak * peak)
      root.peakUpdates++
    }
  }

  // Vsync-aligned frame loop, thinned to about 60 updates a second on
  // high refresh displays. Stopped entirely while hidden.
  FrameAnimation {
    id: frameLoop
    running: root.effects.animating
    onTriggered: {
      root.frameAccum += frameTime * 1000
      if (root.frameAccum < 15.5) return
      var dt = root.frameAccum
      root.frameAccum = 0
      root.step(dt)
    }
  }

  LazyLoader {
    id: windowLoader
    active: root.effects.windowOpen

    PanelWindow {
      id: window
      screen: root.targetScreen()
      anchors {
        top: root.position !== "bottom"
        bottom: root.position === "bottom"
      }
      margins {
        top: 10
        bottom: 56
      }
      implicitWidth: viz.implicitWidth
      implicitHeight: viz.implicitHeight
      color: "transparent"
      exclusionMode: ExclusionMode.Normal
      exclusiveZone: 0
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "omavoice-overlay"
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // Empty input region: clicks and scrolling pass straight through.
      mask: Region {}

      // Only the chosen style is instantiated.
      Loader {
        id: viz
        anchors.fill: parent
        sourceComponent: root.overlayStyle === "trace" ? traceStyle
          : (root.overlayStyle === "scope" || root.overlayStyle === "clip" ? waveStyle : neonStyle)
        opacity: root.frame.appear
        scale: 0.94 + 0.06 * root.frame.appear
      }

      Component {
        id: neonStyle
        Visualizer {
          theme: root.frame.palette || root.themePalette
          time: root.frame.time
          flow: root.frame.flow
          level: root.frame.level
          activity: root.frame.activity
          onset: root.frame.transient
          processing: root.frame.processing
          amps: root.frame.amps
        }
      }

      Component {
        id: traceStyle
        TraceVisualizer {
          theme: root.frame.palette || root.themePalette
          time: root.frame.time
          level: root.frame.level
          activity: root.frame.activity
          onset: root.frame.transient
          processing: root.frame.processing
          trace: root.frame.trace || []
          traceShift: root.frame.traceShift || 0
          traceSeq: root.frame.traceSeq || 0
        }
      }
      Component {
        id: waveStyle
        WaveVisualizer {
          theme: root.frame.palette || root.themePalette
          variant: root.overlayStyle === "clip" ? 2 : 0
          time: root.frame.time
          level: root.frame.level
          activity: root.frame.activity
          onset: root.frame.transient
          processing: root.frame.processing
          trace: root.frame.levels || []
          traceShift: root.frame.traceShift || 0
          traceSeq: root.frame.traceSeq || 0
        }
      }
    }
  }

  Component.onCompleted: Hyprland.refreshMonitors()

  IpcHandler {
    target: "omavoice"
    function status(): string { return root.statusJson() }
    // Drive the overlay with fake levels: "fixture", or JSON
    // {"peaks": [0..1, ...], "fps": 60, "states": [[0, "recording"], [2.5, "transcribing"], [3, "idle"]]}
    function simulate(payload: string): string { return root.startSimulation(payload) }
    function stopSimulation(): string { return root.stopSimulation() }
    function ping(): string { return "ok" }
  }
}
