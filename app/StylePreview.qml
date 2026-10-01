import QtQuick
import "overlay"
import "overlay/OverlayModel.js" as Model

// A live preview of one overlay style: the real Visualizer.qml or
// TraceVisualizer.qml, driven by the same OverlayModel driver as the overlay
// and fed the deterministic fixture voice on a loop (quiet, speech, a loud
// phrase, transcribing). It follows the theme with the overlay's crossfade.
// The animation only runs while the preview is on screen.
Item {
  id: root
  required property var theme
  property string style: "neon"
  property bool running: visible
  property real zoom: 1.5

  implicitWidth: 288 * zoom
  implicitHeight: 80 * zoom

  property var driver: Model.createDriver()
  property var frame: Model.driverStep(driver, 0, null)
  property real clock: 0.2
  readonly property real loopSeconds: Model.FIXTURE_SECONDS + 0.5

  Connections {
    target: root.theme
    function onOverlayChanged() { Model.setPalette(root.driver, root.theme.overlay) }
  }
  Component.onCompleted: Model.setPalette(driver, theme.overlay)

  FrameAnimation {
    running: root.running
    property real acc: 0
    onTriggered: {
      acc += frameTime * 1000
      if (acc < 15.5) return
      var dt = Math.min(acc, 100)
      acc = 0
      root.clock += dt / 1000
      if (root.clock > root.loopSeconds) root.clock = 0
      Model.setVoxState(root.driver, Model.fixtureVoxState(root.clock))
      root.frame = Model.driverStep(root.driver, dt, Model.fixturePeak(root.clock))
    }
  }

  Loader {
    id: styleLoader
    anchors.centerIn: parent
    width: 288
    height: 80
    scale: root.zoom
    sourceComponent: root.style === "trace" ? traceComp : neonComp
  }

  Component {
    id: neonComp
    Visualizer {
      theme: root.frame.palette || root.theme.overlay
      time: root.frame.time
      flow: root.frame.flow
      level: root.frame.level
      activity: root.frame.activity
      onset: root.frame.transient
      processing: root.frame.processing
      amps: root.frame.amps
      opacity: root.frame.appear
    }
  }

  Component {
    id: traceComp
    TraceVisualizer {
      theme: root.frame.palette || root.theme.overlay
      time: root.frame.time
      level: root.frame.level
      activity: root.frame.activity
      onset: root.frame.transient
      processing: root.frame.processing
      trace: root.frame.trace || []
      traceShift: root.frame.traceShift || 0
      traceSeq: root.frame.traceSeq || 0
      opacity: root.frame.appear
    }
  }
}
