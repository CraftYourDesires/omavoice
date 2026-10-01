import QtQuick
import "OverlayModel.js" as Model

// The overlay artwork: one ShaderEffect, driven entirely by properties.
// It has no Quickshell or shell imports, so the offscreen preview renderer
// loads this exact file. The host feeds it a frame from OverlayModel.tick().
Item {
  id: root

  // Pill geometry. The shader leaves `margin` around the pill for its shadow.
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

  // Theme palette from OverlayModel.paletteFrom(), built from the current
  // Omarchy colors.toml. There are no hardcoded colors here; before a theme
  // is read this is the neutral palette paletteFrom() makes from nothing.
  property var theme: Model.paletteFrom({})
  property real grain: 0.03

  ShaderEffect {
    id: effect
    anchors.fill: parent
    blending: true

    property size size: Qt.size(width, height)
    property real time: root.time
    property real flow: root.flow
    property real level: root.level
    property real activity: root.activity
    property real onset: root.onset
    property real processing: root.processing
    property real bgLum: root.theme.bgLum
    property real grain: root.grain
    property real margin: root.margin
    property vector4d amps: Qt.vector4d(root.amps[0] || 0, root.amps[1] || 0, root.amps[2] || 0, root.amps[3] || 0)
    property color colBg: Qt.alpha(root.theme.background, root.theme.dark ? 0.9 : 0.94)
    property color colEdge: Qt.alpha(root.theme.edge, 0.85)
    property color colCore: root.theme.core
    property color colMid: root.theme.mid
    property color colRim: root.theme.rim
    property color colSpark: root.theme.spark
    property color colLine: root.theme.line
    property color colHalo: root.theme.halo

    fragmentShader: Qt.resolvedUrl("shaders/voice.frag.qsb")
  }
}
