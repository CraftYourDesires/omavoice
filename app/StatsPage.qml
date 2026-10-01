import QtQuick
import QtQuick.Layouts
import "ui"

// Word counts and speaking speed. Words are counted in the final text;
// words per minute divide them by how long you actually spoke (the
// recording time), so pauses while Voxtype transcribes don't count.
Flickable {
  id: root
  required property var theme
  required property var store
  contentHeight: col.implicitHeight + 48
  clip: true
  boundsBehavior: Flickable.StopAtBounds
  property bool confirmReset: false
  property int hoverDay: -1

  readonly property var s: store.stats
  function num(n) { return Number(n || 0).toLocaleString(Qt.locale(), "f", 0) }
  function wpm(x) { return x && x.wpm ? Math.round(x.wpm) : 0 }
  function talk(sec) {
    var m = Math.round((sec || 0) / 60)
    if (m < 1) return Math.round(sec || 0) + " s"
    if (m < 60) return m + " min"
    return Math.floor(m / 60) + " h " + (m % 60) + " min"
  }

  Timer { id: resetTimer; interval: 4000; onTriggered: root.confirmReset = false }

  ColumnLayout {
    id: col
    x: 32
    y: 28
    width: root.width - 64
    spacing: 18

    RowLayout {
      Layout.fillWidth: true
      Label { theme: root.theme; heading: true; text: "Stats" }
      Item { Layout.fillWidth: true }
      Btn {
        theme: root.theme
        danger: root.confirmReset
        text: root.confirmReset ? "Reset all word counts?" : "Reset stats"
        onClicked: {
          if (!root.confirmReset) { root.confirmReset = true; resetTimer.restart(); return }
          root.confirmReset = false
          root.store.resetStats()
        }
      }
    }

    GridLayout {
      Layout.fillWidth: true
      columns: root.width > 900 ? 4 : 2
      columnSpacing: 12
      rowSpacing: 12
      Repeater {
        model: [
          { title: "Today", key: "today" }, { title: "Last 7 days", key: "week" },
          { title: "Last 30 days", key: "month" }, { title: "All time", key: "all" }
        ]
        Rectangle {
          required property var modelData
          readonly property var x_: root.s ? root.s[modelData.key] : null
          Layout.fillWidth: true
          implicitHeight: tile.implicitHeight + 28
          color: root.theme.surface
          border.width: 1
          border.color: root.theme.border
          ColumnLayout {
            id: tile
            x: 16; y: 14
            width: parent.width - 32
            spacing: 4
            Label { theme: root.theme; small: true; dim: true; text: modelData.title.toUpperCase(); font.letterSpacing: 1 }
            RowLayout {
              spacing: 6
              Label { theme: root.theme; text: root.num(x_ ? x_.words : 0); font.pixelSize: 30; font.weight: Font.DemiBold }
              Label { theme: root.theme; dim: true; text: "words"; Layout.alignment: Qt.AlignBaseline }
            }
            RowLayout {
              spacing: 6
              Label { theme: root.theme; text: root.wpm(x_); font.pixelSize: 20; color: root.theme.accent; visible: !!(x_ && x_.wpm) }
              Label { theme: root.theme; dim: true; text: x_ && x_.wpm ? "words per minute" : "no timed dictations yet"; Layout.preferredHeight: 26; verticalAlignment: Text.AlignVCenter }
            }
            Label {
              theme: root.theme; small: true; dim: true
              text: (x_ ? x_.dictations : 0) + ((x_ && x_.dictations === 1) ? " dictation, " : " dictations, ") + root.talk(x_ ? x_.seconds : 0) + " talking"
            }
          }
        }
      }
    }

    // Words per day, last 14 days. One series, so no legend: the title names it.
    Rectangle {
      Layout.fillWidth: true
      implicitHeight: 250
      color: root.theme.surface
      border.width: 1
      border.color: root.theme.border

      Label { theme: root.theme; x: 16; y: 14; text: "Words per day, last 14 days" }

      Item {
        id: plot
        x: 16
        y: 48
        width: parent.width - 32
        height: parent.height - 48 - 40
        readonly property var days: root.s ? root.s.daily : []
        readonly property real peak: Math.max(1, Math.max.apply(null, days.map(function(d) { return d.words })))
        readonly property real slot: days.length ? width / days.length : width

        Rectangle { y: plot.height; width: plot.width; height: 1; color: root.theme.border }

        Repeater {
          model: plot.days
          Item {
            required property var modelData
            required property int index
            x: index * plot.slot
            width: plot.slot
            height: plot.height + 30
            readonly property real h: modelData.words ? Math.max(3, plot.height * modelData.words / plot.peak) : 0
            Rectangle {
              anchors.horizontalCenter: parent.horizontalCenter
              width: Math.min(28, plot.slot - 8)
              height: parent.h
              y: plot.height - height
              radius: 2
              color: root.hoverDay === index ? root.theme.accent : Qt.alpha(root.theme.accent, 0.7)
              // Square bottom, rounded top: the bar grows from the baseline.
              Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: Math.min(parent.height, 2); color: parent.color }
            }
            Label {
              theme: root.theme; small: true; dim: true
              anchors.horizontalCenter: parent.horizontalCenter
              y: plot.height + 8
              text: Qt.formatDate(new Date(modelData.date + "T12:00:00"), index === plot.days.length - 1 ? "'Today'" : "ddd d")
              visible: plot.slot > 40 || index % 2 === 1
            }
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.hoverDay = index
              onExited: if (root.hoverDay === index) root.hoverDay = -1
            }
          }
        }

        // Tooltip for the hovered day.
        Rectangle {
          visible: root.hoverDay >= 0 && root.hoverDay < plot.days.length
          readonly property var d: visible ? plot.days[root.hoverDay] : null
          x: Math.min(plot.width - width, Math.max(0, root.hoverDay * plot.slot + plot.slot / 2 - width / 2))
          y: 0
          width: tip.implicitWidth + 20
          height: tip.implicitHeight + 14
          color: root.theme.bg
          border.width: 1
          border.color: root.theme.border
          Label {
            id: tip
            theme: root.theme; small: true
            anchors.centerIn: parent
            wrapMode: Text.NoWrap
            text: parent.d ? Qt.formatDate(new Date(parent.d.date + "T12:00:00"), "dddd MMM d") + "\n" + root.num(parent.d.words) + " words · "
              + (parent.d.wpm ? Math.round(parent.d.wpm) + " wpm" : "no timed dictations") + " · " + parent.d.dictations + " dictations" : ""
          }
        }
      }
    }

    Label {
      theme: root.theme; small: true; dim: true; Layout.fillWidth: true
      text: "Words are counted in the final text you got, so removed filler does not count, and don't, e-mail or 3.5 are one word each. Words per minute divide them by the time you were recording, and only recordings over one second count. Stats have no text in them and stay when you clear history."
    }
  }
}
