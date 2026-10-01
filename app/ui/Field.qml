import QtQuick

// Single line text input with a placeholder, in the Omarchy shell style.
Rectangle {
  id: root
  required property var theme
  property alias text: input.text
  property string placeholder: ""
  property bool invalid: false
  property alias input: input
  signal accepted()
  signal edited()
  signal committed()

  implicitWidth: 220
  implicitHeight: 30
  color: input.activeFocus ? root.theme.surfaceHover : root.theme.surface
  border.width: 1
  border.color: invalid ? root.theme.danger : (input.activeFocus ? Qt.alpha(root.theme.accent, 0.9) : root.theme.border)

  TextInput {
    id: input
    anchors.fill: parent
    anchors.leftMargin: 9
    anchors.rightMargin: 9
    verticalAlignment: TextInput.AlignVCenter
    color: root.theme.fg
    selectionColor: Qt.alpha(root.theme.accent, 0.4)
    selectedTextColor: root.theme.fg
    font.family: root.theme.font
    font.pixelSize: root.theme.size
    clip: true
    selectByMouse: true
    onAccepted: { root.accepted(); root.committed() }
    onTextEdited: root.edited()
    onActiveFocusChanged: if (!activeFocus) root.committed()
    Keys.onEscapePressed: focus = false
  }
  Text {
    anchors.fill: input
    verticalAlignment: Text.AlignVCenter
    visible: input.text === ""
    text: root.placeholder
    color: root.theme.faint
    font: input.font
    elide: Text.ElideRight
  }
}
