import QtQuick
import "../../shell/omavoice.overlay"
import "../../shell/omavoice.overlay/OverlayModel.js" as Model

// Drives the real Visualizer.qml through the same OverlayModel driver the
// live overlay uses, with the deterministic fixture instead of a microphone.
// renderArgs: fps, colors (path to an Omarchy colors.toml), backdrop (0/1),
// scale (device pixel ratio to render at), and optionally switchColors plus
// switchAt (a frame number) to swap the theme mid-animation the same way the
// live overlay does when Omarchy changes theme, and style (neon, the default,
// or trace) to pick the overlay style.
Item {
  id: root
  readonly property real fps: Number(renderArgs.fps || 60)
  property var driver: Model.createDriver()
  property var themePalette: Model.paletteFrom(Model.parseColorsToml(readFile(renderArgs.colors || "")))
  property var shownPalette: themePalette
  readonly property int switchAt: renderArgs.switchColors ? Number(renderArgs.switchAt || 0) : -1
  readonly property string style: renderArgs.style === "trace" ? "trace" : "neon"
  Component.onCompleted: Model.setPalette(driver, themePalette)

  readonly property real pixelRatio: Number(renderArgs.scale || 1)
  width: viz.implicitWidth * pixelRatio
  height: viz.implicitHeight * pixelRatio

  function readFile(path) {
    if (!path) return ""
    var xhr = new XMLHttpRequest()
    xhr.open("GET", "file://" + path, false)
    xhr.send()
    return xhr.responseText || ""
  }

  // A plain backdrop for previews, taken from the theme so the pill reads the
  // way it will over a window. Render tests leave it off.
  Rectangle {
    anchors.fill: parent
    visible: renderArgs.backdrop === "1"
    gradient: Gradient {
      GradientStop { position: 0; color: Qt.darker(root.shownPalette.background || "#101315", root.shownPalette.dark ? 1.6 : 1.04) }
      GradientStop { position: 1; color: Qt.lighter(root.shownPalette.background || "#101315", root.shownPalette.dark ? 1.35 : 0.97) }
    }
  }

  Visualizer {
    id: viz
    width: implicitWidth
    height: implicitHeight
    scale: root.pixelRatio
    transformOrigin: Item.TopLeft
    theme: root.shownPalette
    opacity: 1
    visible: root.style === "neon"
  }

  TraceVisualizer {
    id: tviz
    width: implicitWidth
    height: implicitHeight
    scale: root.pixelRatio
    transformOrigin: Item.TopLeft
    theme: root.shownPalette
    opacity: viz.opacity
    visible: root.style === "trace"
    time: viz.time
    level: viz.level
    activity: viz.activity
    onset: viz.onset
    processing: viz.processing
  }

  function step(i) {
    if (i === switchAt) Model.setPalette(driver, Model.paletteFrom(Model.parseColorsToml(readFile(renderArgs.switchColors))))
    var t = i / fps
    Model.setVoxState(driver, Model.fixtureVoxState(t))
    var f = Model.driverStep(driver, 1000 / fps, Model.fixturePeak(t))
    viz.time = f.time
    viz.flow = f.flow
    viz.level = f.level
    viz.activity = f.activity
    viz.onset = f.transient
    viz.processing = f.processing
    viz.amps = f.amps
    viz.opacity = f.appear
    tviz.trace = f.trace
    tviz.traceShift = f.traceShift
    tviz.traceSeq = f.traceSeq
    shownPalette = f.palette
    return JSON.stringify({
      i: i, t: Math.round(t * 1000) / 1000, phase: f.phase, level: f.level, activity: f.activity,
      transient: f.transient, processing: f.processing, appear: f.appear, speaking: f.speaking,
      cadenceHz: f.cadenceHz, core: f.palette.core, halo: f.palette.halo, blending: driver.paletteT < 1,
      pen: f.trace[0], peak: Math.max.apply(null, f.trace.map(Math.abs))
    })
  }
}
