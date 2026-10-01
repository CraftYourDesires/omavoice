import QtQuick

// A row of mutually exclusive choices: [{label, value}].
Row {
  id: root
  required property var theme
  property var options: []
  property var value
  signal picked(var value)
  spacing: -1

  Repeater {
    model: root.options
    Rectangle {
      required property var modelData
      readonly property bool on: root.value === modelData.value
      width: lbl.implicitWidth + 22
      height: 28
      color: on ? root.theme.selected : (ma.containsMouse ? root.theme.surfaceHover : "transparent")
      border.width: 1
      border.color: on ? Qt.alpha(root.theme.accent, 0.85) : root.theme.border
      z: on ? 1 : 0
      Text {
        id: lbl
        anchors.centerIn: parent
        text: modelData.label
        color: on ? root.theme.accent : root.theme.fg
        font.family: root.theme.font
        font.pixelSize: root.theme.size - 1
      }
      MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.picked(modelData.value)
      }
    }
  }
}
