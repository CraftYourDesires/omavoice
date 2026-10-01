import QtQuick
import QtQuick.Layouts
import "ui"

// Searchable private history of finished dictations. Clicking an entry is
// the only way anything here reaches the clipboard.
Item {
  id: root
  required property var theme
  required property var store
  property string query: ""
  property string copiedId: ""
  property bool confirmClear: false
  property alias searchField: search

  readonly property var filtered: {
    var q = root.query.trim().toLowerCase()
    var all = root.store.history
    if (!q) return all
    var terms = q.split(/\s+/)
    return all.filter(function(e) {
      var hay = (e.text + " " + (e.app || "")).toLowerCase()
      for (var i = 0; i < terms.length; i++) if (hay.indexOf(terms[i]) === -1) return false
      return true
    })
  }

  function when(t) {
    var d = new Date(t * 1000), now = new Date()
    var hm = Qt.formatTime(d, "HH:mm")
    var day = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    if (d.getTime() >= day) return "Today " + hm
    if (d.getTime() >= day - 86400000) return "Yesterday " + hm
    if (d.getTime() >= day - 6 * 86400000) return Qt.formatDate(d, "ddd") + " " + hm
    return Qt.formatDate(d, d.getFullYear() === now.getFullYear() ? "MMM d" : "MMM d yyyy") + " " + hm
  }

  function copyEntry(id) {
    root.store.copy(id)
    root.copiedId = id
    copiedTimer.restart()
  }

  Timer { id: copiedTimer; interval: 1600; onTriggered: root.copiedId = "" }
  Timer { id: confirmTimer; interval: 4000; onTriggered: root.confirmClear = false }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 28
    anchors.leftMargin: 32
    anchors.rightMargin: 32
    spacing: 14

    RowLayout {
      Layout.fillWidth: true
      Label { theme: root.theme; heading: true; text: "History" }
      Item { Layout.fillWidth: true }
      Label {
        theme: root.theme; dim: true; small: true
        text: root.store.settings.history === false ? "Saving is off" : root.store.history.length + (root.store.history.length === 1 ? " dictation" : " dictations")
      }
    }
    Label {
      theme: root.theme; dim: true; Layout.fillWidth: true
      text: "Every finished dictation, kept only on this machine and readable only by you. Click one to copy it, for when the text went to the wrong window. Dictating never leaves text on your clipboard."
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: 10
      Field {
        id: search
        theme: root.theme
        Layout.fillWidth: true
        placeholder: "Search your dictations"
        onEdited: root.query = text
      }
      Segmented {
        theme: root.theme
        options: [
          { label: "Off", value: -1 }, { label: "7 days", value: 7 }, { label: "30 days", value: 30 },
          { label: "90 days", value: 90 }, { label: "1 year", value: 365 }, { label: "Forever", value: 0 }
        ]
        value: root.store.settings.history === false ? -1 : Number(root.store.settings.history_days)
        onPicked: function(v) {
          if (v === -1) { root.store.set("history", false); return }
          if (root.store.settings.history === false) root.store.set("history", true)
          root.store.set("history_days", v)
        }
      }
      Btn {
        theme: root.theme
        danger: root.confirmClear
        enabled: root.store.history.length > 0
        text: root.confirmClear ? "Clear all " + root.store.history.length + "?" : "Clear all"
        onClicked: {
          if (!root.confirmClear) { root.confirmClear = true; confirmTimer.restart(); return }
          root.confirmClear = false
          root.store.clearHistory()
        }
      }
    }

    ListView {
      id: list
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      spacing: 8
      model: root.filtered
      boundsBehavior: Flickable.StopAtBounds
      cacheBuffer: 800

      delegate: Rectangle {
        id: row
        required property var modelData
        required property int index
        readonly property bool copied: root.copiedId === modelData.id
        width: list.width
        height: Math.max(64, body.implicitHeight + 24)
        color: copied ? root.theme.selected : (hov.hovered ? root.theme.surfaceHover : root.theme.surface)
        border.width: 1
        border.color: copied ? Qt.alpha(root.theme.accent, 0.9) : (hov.hovered ? Qt.alpha(root.theme.fg, 0.3) : root.theme.border)
        Behavior on color { ColorAnimation { duration: 90 } }

        MouseArea {
          id: ma
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.copyEntry(row.modelData.id)
        }

        ColumnLayout {
          x: 14
          y: 12
          width: 150
          spacing: 3
          Label { theme: root.theme; small: true; text: root.when(row.modelData.t); color: row.copied ? root.theme.accent : root.theme.fg }
          Label {
            theme: root.theme; small: true; dim: true
            text: row.modelData.words + (row.modelData.words === 1 ? " word" : " words") + (row.modelData.wpm ? " · " + Math.round(row.modelData.wpm) + " wpm" : "")
          }
          Label { theme: root.theme; small: true; dim: true; visible: !!row.modelData.app; text: row.modelData.app || ""; elide: Text.ElideRight; Layout.maximumWidth: 150; wrapMode: Text.NoWrap }
        }

        Label {
          id: body
          theme: root.theme
          x: 180
          y: 12
          width: row.width - 180 - (hov.hovered || row.copied ? 200 : 16)
          text: row.modelData.text
          maximumLineCount: 5
          elide: Text.ElideRight
          lineHeight: 1.15
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8
          visible: hov.hovered || row.copied
          Label {
            theme: root.theme; small: true
            anchors.verticalCenter: parent.verticalCenter
            text: row.copied ? "Copied" : "Click to copy"
            color: row.copied ? root.theme.accent : root.theme.muted
          }
          Btn {
            theme: root.theme
            compact: true
            danger: true
            text: "Delete"
            onClicked: root.store.remove(row.modelData.id)
          }
        }
        // Stays hovered while the pointer is over the delete button too.
        HoverHandler { id: hov }
      }

      Label {
        anchors.centerIn: parent
        width: Math.min(parent.width - 40, 520)
        horizontalAlignment: Text.AlignHCenter
        theme: root.theme
        dim: true
        visible: list.count === 0 && root.store.historyLoaded
        text: root.store.history.length === 0
          ? (root.store.settings.history === false ? "History is off. Choose how long to keep dictations above to turn it on." : "Nothing yet. Your next dictation will show up here.")
          : "No dictation matches “" + root.query + "”."
      }
    }
  }
}
