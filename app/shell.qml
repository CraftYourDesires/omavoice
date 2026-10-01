//@ pragma AppId omavoice
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "ui"

// omavoice: a small Omarchy app for the dictation setup. Overlay style with
// live previews, the private history, the dictionary and word stats. Runs
// as its own Quickshell instance (bin/omavoice starts it) and quits when the
// window closes.
ShellRoot {
  id: app

  property string page: "style"
  readonly property var pages: [
    { id: "style", title: "Style", key: "1" },
    { id: "history", title: "History", key: "2" },
    { id: "dictionary", title: "Dictionary", key: "3" },
    { id: "stats", title: "Stats", key: "4" }
  ]
  property string toastText: ""
  property int pid: 0

  Theme { id: appTheme }
  Store {
    id: appStore
    onToast: function(message) { app.toastText = message; toastTimer.restart() }
  }
  Timer { id: toastTimer; interval: 1800; onTriggered: app.toastText = "" }

  FileView {
    path: "/proc/self/stat"
    onLoaded: app.pid = Number(text().split(" ")[0])
  }

  FloatingWindow {
    id: win
    title: "omavoice"
    color: appTheme.bg
    implicitWidth: 1080
    implicitHeight: 720
    minimumSize: Qt.size(780, 540)
    onVisibleChanged: if (!visible) Qt.quit()

    Item {
      id: content
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        if (event.modifiers & Qt.ControlModifier) {
          var n = event.key - Qt.Key_1
          if (n >= 0 && n < app.pages.length) { app.page = app.pages[n].id; event.accepted = true }
          else if (event.key === Qt.Key_F && app.page === "history") { historyPage.searchField.input.forceActiveFocus(); event.accepted = true }
          else if (event.key === Qt.Key_Q || event.key === Qt.Key_W) { Qt.quit(); event.accepted = true }
        }
      }

      // Sidebar
      Rectangle {
        id: side
        width: 212
        height: parent.height
        color: appTheme.surface
        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: appTheme.border }

        ColumnLayout {
          x: 20
          y: 24
          width: parent.width - 40
          spacing: 4

          RowLayout {
            spacing: 10
            Layout.bottomMargin: 22
            // A small live mark in the chosen style's colors.
            Rectangle {
              width: 12; height: 12
              color: "transparent"
              border.width: 2
              border.color: appTheme.accent
              rotation: appStore.settings.overlay_style === "trace" ? 45 : 0
              radius: appStore.settings.overlay_style === "trace" ? 0 : 6
              Behavior on rotation { NumberAnimation { duration: 200 } }
            }
            Label { theme: appTheme; text: "omavoice"; font.pixelSize: appTheme.size + 4; font.weight: Font.DemiBold }
          }

          Repeater {
            model: app.pages
            Rectangle {
              required property var modelData
              readonly property bool on: app.page === modelData.id
              Layout.fillWidth: true
              implicitHeight: 36
              color: on ? appTheme.selected : (nav.containsMouse ? appTheme.surfaceHover : "transparent")
              Rectangle { width: 2; height: parent.height; color: appTheme.accent; visible: parent.on }
              Label {
                theme: appTheme
                anchors.verticalCenter: parent.verticalCenter
                x: 14
                text: modelData.title
                color: parent.on ? appTheme.accent : appTheme.fg
              }
              Label {
                theme: appTheme; small: true; dim: true
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                anchors.rightMargin: 10
                text: modelData.id === "history" ? appStore.history.length
                  : modelData.id === "dictionary" ? (dictionaryPage.count || "")
                  : modelData.id === "stats" && appStore.stats ? appStore.stats.today.words + " today" : ""
              }
              MouseArea {
                id: nav
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: app.page = modelData.id
              }
            }
          }
        }

        Label {
          theme: appTheme; small: true; dim: true
          x: 20
          width: parent.width - 40
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 20
          text: "Overlay: " + (appStore.settings.overlay === false ? "off" : (appStore.settings.overlay_style === "trace" ? "Trace" : "Neon") + ", " + (appStore.settings.overlay_position || "top"))
            + "\nHistory: " + (appStore.settings.history === false ? "off" : (Number(appStore.settings.history_days) === 0 ? "kept forever" : appStore.settings.history_days + " days"))
            + "\nTheme: " + (appTheme.name || "unknown")
        }
      }

      Item {
        x: side.width
        width: parent.width - side.width
        height: parent.height

        StylePage { anchors.fill: parent; theme: appTheme; store: appStore; visible: app.page === "style"; active: visible && win.visible }
        HistoryPage { id: historyPage; anchors.fill: parent; theme: appTheme; store: appStore; visible: app.page === "history" }
        DictionaryPage { id: dictionaryPage; anchors.fill: parent; theme: appTheme; store: appStore; visible: app.page === "dictionary" }
        StatsPage { anchors.fill: parent; theme: appTheme; store: appStore; visible: app.page === "stats" }
      }

      // Toast
      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: side.width / 2
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 24
        width: toastLabel.implicitWidth + 32
        height: 36
        color: appTheme.bg
        border.width: 1
        border.color: appTheme.accent
        opacity: app.toastText ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 150 } }
        Label { id: toastLabel; theme: appTheme; anchors.centerIn: parent; text: app.toastText; color: appTheme.accent }
      }
    }
  }

  // For the launcher (focus an open window) and the UI tests. The actions
  // call the same functions the buttons do. status() carries counts and
  // settings only, never dictation text.
  IpcHandler {
    target: "omavoice-app"
    function ping(): string { return "ok" }
    function pid(): string { return String(app.pid) }
    function page(name: string): string {
      for (var i = 0; i < app.pages.length; i++) if (app.pages[i].id === name) { app.page = name; return "ok" }
      return "unknown page"
    }
    function search(query: string): string {
      historyPage.searchField.text = query
      historyPage.query = query
      return String(historyPage.filtered.length)
    }
    function copyResult(index: int): string {
      var e = historyPage.filtered[index]
      if (!e) return "none"
      historyPage.copyEntry(e.id)
      return "ok"
    }
    function deleteResult(index: int): string {
      var e = historyPage.filtered[index]
      if (!e) return "none"
      appStore.remove(e.id)
      return "ok"
    }
    function pickStyle(style: string): string { appStore.set("overlay_style", style); return "ok" }
    function setting(key: string, value: string): string {
      appStore.set(key, value === "true" ? true : (value === "false" ? false : (/^[0-9]+$/.test(value) ? Number(value) : value)))
      return "ok"
    }
    function addTerm(section: string, term: string, hint: string): string {
      var D = dictionaryPage
      if (!D.tryEntry(term, hint)) return D.problemText
      var rows = D.rows
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].kind === "section" && rows[i].name === section) {
          dictionaryPage.edit(dictionaryPage.addEntryAt(rows[i].header, term, hint))
          return "ok"
        }
      }
      return "no such section"
    }
    function saveDictionary(): string { dictionaryPage.save(); return "ok" }
    function status(): string {
      return JSON.stringify({
        page: app.page,
        visible: win.visible,
        width: win.width,
        height: win.height,
        font: appTheme.font,
        theme: appTheme.name,
        themeLoads: appTheme.loads,
        bg: String(appTheme.bg),
        accent: String(appTheme.accent),
        style: appStore.settings.overlay_style,
        position: appStore.settings.overlay_position,
        historyOn: appStore.settings.history !== false,
        historyDays: appStore.settings.history_days,
        historyCount: appStore.history.length,
        filtered: historyPage.filtered.length,
        copied: historyPage.copiedId !== "",
        dictionaryTerms: dictionaryPage.count,
        dictionaryDirty: dictionaryPage.dirty,
        todayWords: appStore.stats ? appStore.stats.today.words : -1,
        weekWords: appStore.stats ? appStore.stats.week.words : -1,
        toast: app.toastText
      })
    }
  }
}
