import QtQuick
import "OverlayModel.js" as Model

// The "scope" and "clip" overlay styles (shaders/wave.frag): variant 0 is a
// synth oscilloscope, 2 a DAW clip waveform growing out from the center.
// Same panel and inputs as TraceVisualizer.qml, but drawn from the level
// history (frame.levels) instead of the pen trace.
Item {
  id: root

  property real margin: 12
  implicitWidth: 264 + margin * 2
  implicitHeight: 56 + margin * 2

  property real time: 0
  property real flow: 0
  property real level: 0
  property real activity: 0
  property real onset: 0
  property real processing: 0
  property var amps: [0, 0, 0, 0]
  // Pen deflections, newest (the live pen) first, from frame.trace.
  property var trace: []   // frame.levels here
  property int variant: 0
  property real traceShift: 0
  property real traceSeq: 0

  property var theme: Model.paletteFrom({})
  property real grain: 0.03

  function q(i) {
    var t = root.trace
    return Qt.vector4d(t[i] || 0, t[i + 1] || 0, t[i + 2] || 0, t[i + 3] || 0)
  }

  ShaderEffect {
    anchors.fill: parent
    blending: true

    property size size: Qt.size(width, height)
    property real time: root.time
    property real level: root.level
    property real activity: root.activity
    property real onset: root.onset
    property real processing: root.processing
    property real bgLum: root.theme.bgLum
    property real grain: root.grain
    property real margin: root.margin
    property real shift: root.traceShift
    property real seq: root.traceSeq
    property real variant: root.variant
    property vector4d h0: root.q(0)
    property vector4d h1: root.q(4)
    property vector4d h2: root.q(8)
    property vector4d h3: root.q(12)
    property vector4d h4: root.q(16)
    property vector4d h5: root.q(20)
    property vector4d h6: root.q(24)
    property vector4d h7: root.q(28)
    property vector4d h8: root.q(32)
    property vector4d h9: root.q(36)
    property vector4d h10: root.q(40)
    property vector4d h11: root.q(44)
    property vector4d h12: root.q(48)
    property vector4d h13: root.q(52)
    property vector4d h14: root.q(56)
    property vector4d h15: root.q(60)
    property color colBg: Qt.alpha(root.theme.background, root.theme.dark ? 0.92 : 0.95)
    property color colEdge: Qt.alpha(root.theme.edge, 0.85)
    property color colCore: root.theme.core
    property color colMid: root.theme.mid
    property color colRim: root.theme.rim
    property color colSpark: root.theme.spark
    property color colLine: root.theme.line
    property color colHalo: root.theme.halo

    fragmentShader: Qt.resolvedUrl("shaders/wave.frag.qsb")
  }
}
