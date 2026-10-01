import QtQuick
import QtQuick.Controls.Basic as C
import QtQuick.Layouts
import "ui"
import "Dictionary.js" as D

// Editor for ~/.config/voxtype/dictionary.txt: names and jargon the cleanup
// pass spells exactly. Sections ("## Name"), comments and blank lines in the
// file are kept as they are; only the lines you change are rewritten.
Item {
  id: root
  required property var theme
  required property var store
  property var doc: D.parse("")
  property string saved: ""
  property string query: ""
  property bool raw: false
  property bool changedOnDisk: false
  property string problemText: ""
  readonly property bool dirty: D.serialize(doc) !== saved
  readonly property int count: D.entryCount(doc)

  function load() {
    root.saved = root.store.dictionaryText
    root.doc = D.parse(root.saved)
    root.changedOnDisk = false
  }
  function save() {
    if (!dirty) return
    root.saved = D.serialize(root.doc)
    root.store.saveDictionary(root.saved)
    root.changedOnDisk = false
  }
  function revert() { load() }
  function edit(next) { root.doc = next; root.problemText = "" }
  function addEntryAt(header, term, hint) { return D.addEntry(root.doc, header, term, hint) }
  function tryEntry(term, hint) {
    var p = D.problem(term, hint)
    root.problemText = p
    return p === ""
  }

  Connections {
    target: root.store
    function onDictionaryVersionChanged() {
      if (root.store.dictionaryText === root.saved) return
      if (root.dirty) root.changedOnDisk = true
      else root.load()
    }
  }
  Component.onCompleted: if (root.store.dictionaryLoaded) load()

  readonly property var rows: {
    var q = root.query.trim().toLowerCase()
    var out = []
    var secs = D.sections(root.doc)
    for (var i = 0; i < secs.length; i++) {
      var s = secs[i]
      var entries = q ? s.entries.filter(function(e) { return (e.term + " " + e.hint).toLowerCase().indexOf(q) !== -1 }) : s.entries
      if (q && entries.length === 0) continue
      out.push({ kind: "section", name: s.name || "Unsorted", header: s.header, count: s.entries.length })
      for (var j = 0; j < entries.length; j++) out.push({ kind: "entry", line: entries[j].line, term: entries[j].term, hint: entries[j].hint, header: s.header })
      if (!q) out.push({ kind: "add", header: s.header })
    }
    return out
  }

  Shortcut { sequence: "Ctrl+S"; enabled: root.visible; onActivated: root.save() }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 28
    anchors.leftMargin: 32
    anchors.rightMargin: 32
    spacing: 14

    RowLayout {
      Layout.fillWidth: true
      Label { theme: root.theme; heading: true; text: "Dictionary" }
      Item { Layout.fillWidth: true }
      Label { theme: root.theme; dim: true; small: true; text: root.count + (root.count === 1 ? " term" : " terms") }
    }
    Label {
      theme: root.theme; dim: true; Layout.fillWidth: true
      text: "Names, products and jargon the cleanup spells exactly. Add a hint after the term to help, for example how it gets misheard: Aoife | coworker, misheard as \"eefa\". Comments and layout in the file stay as they are."
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: 10
      Field {
        theme: root.theme
        Layout.fillWidth: true
        placeholder: "Filter terms and hints"
        visible: !root.raw
        onEdited: root.query = text
      }
      Item { Layout.fillWidth: true; visible: root.raw }
      Segmented {
        theme: root.theme
        options: [{ label: "Entries", value: false }, { label: "Raw file", value: true }]
        value: root.raw
        onPicked: function(v) { root.raw = v }
      }
    }

    // Someone else saved the file while you had unsaved edits.
    Rectangle {
      Layout.fillWidth: true
      visible: root.changedOnDisk
      implicitHeight: 40
      color: Qt.alpha(root.theme.warm, 0.12)
      border.width: 1
      border.color: Qt.alpha(root.theme.warm, 0.7)
      RowLayout {
        anchors.fill: parent
        anchors.margins: 6
        anchors.leftMargin: 12
        Label { theme: root.theme; text: "The file changed on disk while you were editing."; Layout.fillWidth: true }
        Btn { theme: root.theme; compact: true; text: "Load theirs"; onClicked: root.load() }
        Btn { theme: root.theme; compact: true; text: "Keep mine"; onClicked: root.changedOnDisk = false }
      }
    }

    ListView {
      id: list
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: !root.raw
      clip: true
      model: root.rows
      spacing: 4
      boundsBehavior: Flickable.StopAtBounds
      cacheBuffer: 1200
      reuseItems: false

      delegate: Loader {
        id: rowLoader
        required property var modelData
        width: list.width
        sourceComponent: modelData.kind === "section" ? sectionRow : (modelData.kind === "entry" ? entryRow : addRow)
      }

      footer: RowLayout {
        width: list.width
        visible: root.query === ""
        spacing: 8
        Item { implicitHeight: 52; implicitWidth: 1 }
        Field { id: newSection; theme: root.theme; Layout.preferredWidth: 260; placeholder: "New section name"; onAccepted: addSectionBtn.clicked() }
        Btn {
          id: addSectionBtn
          theme: root.theme
          text: "Add section"
          enabled: newSection.text.trim() !== ""
          onClicked: {
            root.edit(D.addSection(root.doc, newSection.text))
            newSection.text = ""
            list.positionViewAtEnd()
          }
        }
        Item { Layout.fillWidth: true }
      }
    }

    Component {
      id: sectionRow
      Item {
        id: sr
        readonly property var e: parent ? parent.modelData : ({})
        implicitHeight: 42
        Label {
          theme: root.theme
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 6
          text: sr.e.name || ""
          font.weight: Font.DemiBold
          color: root.theme.accent
        }
        Label {
          theme: root.theme; dim: true; small: true
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 8
          text: sr.e.count === undefined ? "" : sr.e.count
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.theme.border }
      }
    }

    Component {
      id: entryRow
      RowLayout {
        id: er
        readonly property var e: parent ? parent.modelData : ({ term: "", hint: "", line: -1 })
        readonly property bool dup: D.duplicates(root.doc, e.term, e.line).length > 0
        spacing: 8
        function commit() {
          if (term.text.trim() === e.term && hint.text.trim() === e.hint) return
          if (!root.tryEntry(term.text, hint.text)) { term.text = e.term; hint.text = e.hint; return }
          root.edit(D.setEntry(root.doc, e.line, term.text, hint.text))
        }
        Field { id: term; theme: root.theme; Layout.preferredWidth: Math.max(180, list.width * 0.3); text: er.e.term; invalid: er.dup; onCommitted: er.commit() }
        Field { id: hint; theme: root.theme; Layout.fillWidth: true; text: er.e.hint; placeholder: "hint (optional)"; onCommitted: er.commit() }
        Label { theme: root.theme; small: true; visible: er.dup; text: "duplicate"; color: root.theme.danger }
        Btn { theme: root.theme; compact: true; text: "Remove"; onClicked: root.edit(D.removeEntry(root.doc, er.e.line)) }
      }
    }

    Component {
      id: addRow
      RowLayout {
        id: ar
        readonly property var e: parent ? parent.modelData : ({ header: -1 })
        spacing: 8
        function add() {
          if (!root.tryEntry(nt.text, nh.text)) return
          root.edit(D.addEntry(root.doc, ar.e.header, nt.text, nh.text))
        }
        Field { id: nt; theme: root.theme; Layout.preferredWidth: Math.max(180, list.width * 0.3); placeholder: "Add a term"; onAccepted: ar.add() }
        Field { id: nh; theme: root.theme; Layout.fillWidth: true; placeholder: "hint (optional)"; onAccepted: ar.add() }
        Btn { theme: root.theme; compact: true; text: "Add"; primary: nt.text.trim() !== ""; enabled: nt.text.trim() !== ""; onClicked: ar.add() }
      }
    }

    C.ScrollView {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: root.raw
      background: Rectangle { color: root.theme.surface; border.width: 1; border.color: root.theme.border }
      C.TextArea {
        id: rawText
        text: D.serialize(root.doc)
        color: root.theme.fg
        selectionColor: Qt.alpha(root.theme.accent, 0.4)
        font.family: root.theme.font
        font.pixelSize: root.theme.size
        wrapMode: TextEdit.NoWrap
        selectByMouse: true
        background: null
        onTextChanged: if (activeFocus && text !== D.serialize(root.doc)) root.edit(D.parse(text))
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: 10
      Label {
        theme: root.theme; small: true; Layout.fillWidth: true
        text: root.problemText !== "" ? root.problemText
          : (root.dirty ? "Unsaved changes. Ctrl+S saves." : "Saved in " + root.store.configDir.replace(root.store.home, "~") + "/dictionary.txt")
        color: root.problemText !== "" ? root.theme.danger : (root.dirty ? root.theme.warm : root.theme.muted)
      }
      Btn { theme: root.theme; text: "Revert"; enabled: root.dirty; onClicked: root.revert() }
      Btn { theme: root.theme; text: "Save"; primary: true; enabled: root.dirty; onClicked: root.save() }
    }
  }
}
