import QtQuick
import Quickshell
import Quickshell.Io

// The app's data: history, word stats, settings and the dictionary.
//
// Reads are live file watches (inotify, nothing polls): history.jsonl and
// stats.json in ~/.local/share/omavoice, omavoice.toml and dictionary.txt in
// ~/.config/voxtype. Every change goes through bin/omavoice-store, the same
// code the output service uses, except dictionary saves, which this app
// writes itself (atomically). OMAVOICE_DATA_DIR and OMAVOICE_CONFIG_DIR
// point it at scratch folders for tests and screenshots.
Item {
  id: root
  visible: false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string dataDir: Quickshell.env("OMAVOICE_DATA_DIR") || (home + "/.local/share/omavoice")
  readonly property string configDir: Quickshell.env("OMAVOICE_CONFIG_DIR") || (home + "/.config/voxtype")
  // app/ is the Quickshell config folder; the CLI sits next to it in bin/.
  readonly property string tool: String(Quickshell.shellDir).replace(/^file:\/\//, "").replace(/\/$/, "") + "/../bin/omavoice-store"

  // Newest first.
  property var history: []
  property bool historyLoaded: false
  property var stats: null
  property var settings: ({ overlay: true, overlay_position: "top", overlay_style: "neon", history: true, history_days: 30, notify_unpasted: true })
  property string dictionaryText: ""
  property bool dictionaryLoaded: false
  property int dictionaryVersion: 0
  property string lastError: ""

  signal toast(string message)

  // ---------------------------------------------------------------- commands

  Component {
    id: procComponent
    Process {
      id: proc
      property var done: null
      property int code: -1
      property bool exited: false
      property bool streamed: false
      function finish() {
        if (!exited || !streamed) return
        if (done) done(code, out.text)
        proc.destroy()
      }
      stdout: StdioCollector {
        id: out
        onStreamFinished: { proc.streamed = true; proc.finish() }
      }
      onExited: function(exitCode) { proc.code = exitCode; proc.exited = true; proc.finish() }
    }
  }

  function run(args, done) {
    var env = {}
    env.OMAVOICE_DATA_DIR = root.dataDir
    env.OMAVOICE_CONFIG_DIR = root.configDir
    var p = procComponent.createObject(root, { command: [root.tool].concat(args), environment: env, done: done || null })
    p.running = true
  }

  function copy(id) {
    run(["copy", id], function(code) {
      if (code === 0) root.toast("Copied to clipboard")
      else root.toast("Could not copy")
    })
  }
  function remove(id) { run(["delete", id], function(code) { if (code === 0) root.toast("Deleted") }) }
  function clearHistory() { run(["clear"], function(code) { if (code === 0) root.toast("History cleared") }) }
  function resetStats() { run(["reset-stats"], function(code) { if (code === 0) root.toast("Stats reset") }) }
  function set(key, value) {
    var before = root.settings[key]
    var s = {}
    for (var k in root.settings) s[k] = root.settings[k]
    s[key] = value
    root.settings = s   // optimistic; the file watch confirms
    run(["set", key, String(value)], function(code) {
      if (code !== 0) {
        root.toast("Could not save " + key)
        loadSettings()
      }
    })
  }
  function loadStats() { run(["stats", "--json"], function(code, text) { if (code === 0) try { root.stats = JSON.parse(text) } catch (e) {} }) }
  function loadSettings() { run(["get"], function(code, text) { if (code === 0) try { root.settings = JSON.parse(text) } catch (e) {} }) }

  function saveDictionary(text) {
    dictFile.setText(text)
  }

  // ---------------------------------------------------------------- watches

  FileView {
    id: historyFile
    path: root.dataDir + "/history.jsonl"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var out = []
      var lines = text().split("\n")
      for (var i = lines.length - 1; i >= 0; i--) {
        if (!lines[i]) continue
        try {
          var e = JSON.parse(lines[i])
          if (e && e.id && typeof e.text === "string") out.push(e)
        } catch (err) {}
      }
      root.history = out
      root.historyLoaded = true
    }
    onLoadFailed: { root.history = []; root.historyLoaded = true }
  }

  FileView {
    path: root.dataDir + "/stats.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadStats()
    onLoadFailed: root.loadStats()
  }

  FileView {
    path: root.configDir + "/omavoice.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadSettings()
    onLoadFailed: root.loadSettings()
  }

  FileView {
    id: dictFile
    path: root.configDir + "/dictionary.txt"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.dictionaryText = text()
      root.dictionaryLoaded = true
      root.dictionaryVersion++
    }
    onLoadFailed: {
      root.dictionaryText = ""
      root.dictionaryLoaded = true
      root.dictionaryVersion++
    }
    onSaved: root.toast("Dictionary saved")
    onSaveFailed: function(error) { root.toast("Could not save the dictionary") }
  }

  // Stats roll over at midnight even when nothing is dictated.
  Timer {
    interval: 60000
    repeat: true
    running: true
    property string day: new Date().toDateString()
    onTriggered: {
      var d = new Date().toDateString()
      if (d !== day) { day = d; root.loadStats() }
    }
  }
}
