import QtQuick

// Square, bordered button in the Omarchy shell style.
Rectangle {
  id: root
  required property var theme
  property string text: ""
  property bool primary: false
  property bool danger: false
  property bool compact: false
  signal clicked()

  implicitWidth: label.implicitWidth + (compact ? 16 : 24)
  implicitHeight: compact ? 26 : 32
  opacity: enabled ? 1 : 0.45
  readonly property color tone: danger ? theme.danger : (primary ? theme.accent : theme.fg)
  color: mouse.pressed ? Qt.alpha(tone, 0.22) : (mouse.containsMouse ? Qt.alpha(tone, primary || danger ? 0.16 : 0.08) : (primary ? Qt.alpha(tone, 0.1) : "transparent"))
  border.width: 1
  border.color: primary || danger || mouse.containsMouse ? Qt.alpha(tone, 0.8) : theme.border
  Behavior on color { ColorAnimation { duration: 90 } }

  Text {
    id: label
    anchors.centerIn: parent
    text: root.text
    color: root.primary || root.danger ? root.tone : root.theme.fg
    font.family: root.theme.font
    font.pixelSize: root.theme.size - (root.compact ? 1 : 0)
  }
  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.enabled
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
