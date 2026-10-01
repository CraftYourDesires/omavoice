import QtQuick
import Quickshell
import Quickshell.Io
import "overlay/OverlayModel.js" as Model

// The app's colors and font, from the current Omarchy theme, live.
//
// Same approach as the overlay (shell/omavoice.overlay/Service.qml): read
// the runtime colors.toml, and because Omarchy switches themes by replacing
// the whole theme folder, re-point the watch every time theme.name is
// rewritten. Colors crossfade when the theme changes. The overlay palette
// (for the style previews) comes from the same mapping the overlay uses, so
// the previews match what you will see while dictating.
Item {
  id: root
  visible: false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string themeDir: stateHome + "/omarchy/current/theme"

  property string name: ""
  property int loads: 0
  property var colors: ({})
  property var overlay: Model.paletteFrom({})
  readonly property bool dark: overlay.dark !== false

  // UI roles. Accent-like colors come from the overlay mapping, which keeps
  // them readable against the background on light and dark themes.
  property color bg: overlay.background
  property color fg: pick("foreground", dark ? "#d8d8d8" : "#202020")
  property color accent: overlay.halo
  property color warm: overlay.core
  property color muted: Qt.tint(fg, Qt.alpha(bg, 0.45))
  property color faint: Qt.tint(fg, Qt.alpha(bg, 0.68))
  property color surface: Qt.tint(bg, Qt.alpha(fg, dark ? 0.045 : 0.035))
  property color surfaceHover: Qt.tint(bg, Qt.alpha(fg, dark ? 0.085 : 0.07))
  property color border: Qt.tint(bg, Qt.alpha(fg, dark ? 0.16 : 0.2))
  property color selected: Qt.tint(bg, Qt.alpha(accent, dark ? 0.16 : 0.13))
  property color danger: Model.hexToRgb(colors.red || colors.color1 || "") ? fitted(colors.red || colors.color1) : (dark ? "#e06c75" : "#b3261e")

  Behavior on bg { ColorAnimation { duration: 320 } }
  Behavior on fg { ColorAnimation { duration: 320 } }
  Behavior on accent { ColorAnimation { duration: 320 } }
  Behavior on warm { ColorAnimation { duration: 320 } }

  property string font: "JetBrainsMono Nerd Font"
  readonly property int size: 13

  function pick(key, fallback) {
    var v = root.colors[key]
    return Model.hexToRgb(v) ? v : fallback
  }

  // A theme color nudged until it reads clearly on the background.
  function fitted(hex) {
    var lch = Model.hexToOklch(hex)
    if (!lch) return fg
    return Model.fitRole(lch, root.overlay.bgLum, !root.dark, 0.3)
  }

  function apply(text) {
    var t = String(text || "")
    if (t.trim() === "") { retry.restart(); return }
    var c = Model.parseColorsToml(t)
    root.colors = c
    root.overlay = Model.paletteFrom(c)
    root.loads++
  }

  function rearm() {
    colorsFile.path = ""
    colorsFile.path = root.themeDir + "/colors.toml"
    colorsFile.reload()
  }

  FileView {
    id: colorsFile
    path: root.themeDir + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: settle.restart()
    onLoaded: root.apply(text())
    onLoadFailed: retry.restart()
  }

  FileView {
    path: root.stateHome + "/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.name = text().trim()
      settle.restart()
    }
  }

  Timer { id: settle; interval: 60; onTriggered: root.rearm() }
  Timer {
    id: retry
    interval: 120
    property int tries: 0
    onTriggered: if (++tries < 30) root.rearm()
  }

  // The Omarchy font, so the app matches the bar and terminals.
  Process {
    command: ["omarchy", "font", "current"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        var f = text.trim()
        if (f) root.font = f
      }
    }
  }
}
