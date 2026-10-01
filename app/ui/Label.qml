import QtQuick

Text {
  required property var theme
  property bool dim: false
  property bool small: false
  property bool heading: false
  color: dim ? theme.muted : theme.fg
  font.family: theme.font
  font.pixelSize: heading ? theme.size + 5 : (small ? theme.size - 2 : theme.size)
  font.weight: heading ? Font.DemiBold : Font.Normal
  wrapMode: Text.WordWrap
}
