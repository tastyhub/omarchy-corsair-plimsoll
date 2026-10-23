import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything the widget knows about the PSU, with no drawing.
//
// Two helper processes feed it (see psu-read.py for why they are processes):
//   slow  total power and temperatures every few seconds, always running; this is
//         what the bar readout and the 12 hour history come from
//   fast  every rail once a second, only while the panel is open
// Each prints one JSON object per line; the lines are parsed as untrusted data.
Item {
  id: root

  // ---- set by the host
  property bool panelOpen: false
  property int slowIntervalSec: 5

  // ---- what the helpers reported
  property var info: null
  property var sample: null          // latest full sample (panel open)
  property real barWatts: -1         // latest total, from either helper
  property real barVrm: -1
  property bool present: false
  property bool seen: false          // has the helper said anything yet

  // ---- derived
  property var history: []           // short ring for the chart, oldest first
  property var stats: null           // 12 h { min, max, avg }
  property real energyWh: 0

  readonly property real rated: info && info.ratedW > 0 ? info.ratedW : 1200
  readonly property real loadPercent: barWatts >= 0 ? Model.loadPercent(barWatts, rated) : -1

  readonly property string scriptPath: Qt.resolvedUrl("psu-read.py").toString().replace(/^file:\/\//, "")

  // 12 hour buckets of total output, kept in memory and saved under XDG state
  // (never inside the plugin directory: the shell reloads a plugin when a file there changes).
  property var _buckets: []
  property bool _historyLoaded: false
  property bool _dirty: false
  property double _prevW: -1
  property double _prevT: -1
  property bool _destroyed: false
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy-psu/"

  function handle(line) {
    if (_destroyed) return
    var msg = Model.parseLine(line)
    if (!msg) return
    seen = true

    if (msg.type === "absent") {
      present = false
      return
    }
    if (msg.type === "info") {
      info = msg
      present = true
      return
    }

    present = true
    var total = msg.type === "sample" ? (msg.w && msg.w.total !== undefined ? msg.w.total : null) : msg.w
    if (msg.type === "sample") {
      sample = msg
      var point = { total: total === null ? 0 : total, "12v": msg.w["12v"] || 0, "5v": msg.w["5v"] || 0, "3v3": msg.w["3v3"] || 0 }
      history = Model.pushRing(history, point, 300)
    }
    if (total !== null && total !== undefined) {
      barWatts = total
      var now = msg.t > 0 ? msg.t : Date.now()
      energyWh = Model.addEnergy(energyWh, _prevW >= 0 ? _prevW : null, _prevT >= 0 ? _prevT : null, total, now, 30)
      _prevW = total
      _prevT = now
      noteBucket(total)
    }
    if (msg.vrm !== null && msg.vrm !== undefined) barVrm = msg.vrm
  }

  function noteBucket(watts) {
    var now = Date.now()
    Model.recordBucket(_buckets, watts, now)
    _dirty = true
    if (_buckets.rolled) saveTimer.restart()
    stats = Model.bucketStats(_buckets, now)
  }

  function loadHistory(raw) {
    if (_historyLoaded) return
    // Whatever was recorded before the file arrived is kept, not overwritten.
    _buckets = Model.mergeHistory(Model.parseHistory(raw, Date.now()), _buckets)
    _historyLoaded = true
    stats = Model.bucketStats(_buckets, Date.now())
  }

  function flush() {
    if (_destroyed || !_historyLoaded || !_dirty) return
    _dirty = false
    historyFile.setText(Model.serializeHistory(_buckets))
  }

  // Fresh chart each time the panel opens: a ring that spans a closed panel would
  // show a flat line where nothing was sampled.
  onPanelOpenChanged: if (panelOpen) history = []

  Process { id: mkdirProc; command: ["mkdir", "-p", root.stateDir]; running: false }

  FileView {
    id: historyFile
    path: ""
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadHistory(text())
    onLoadFailed: root.loadHistory("")
  }

  Timer {
    id: saveTimer
    interval: 5000
    repeat: false
    onTriggered: root.flush()
  }

  // The always-on reader: three reads every few seconds.
  Process {
    id: slow
    command: ["python3", "-I", root.scriptPath, "--bar", "--interval", String(root.slowIntervalSec)]
    running: true
    stdout: SplitParser { onRead: function(line) { root.handle(line) } }
  }

  // The full reader, one second apart, only while the panel is on screen.
  Process {
    id: fast
    command: ["python3", "-I", root.scriptPath, "--interval", "1"]
    running: root.panelOpen
    stdout: SplitParser { onRead: function(line) { root.handle(line) } }
  }

  Component.onCompleted: {
    mkdirProc.running = true
    Qt.callLater(function() { if (!root._destroyed) historyFile.path = root.stateDir + "history.json" })
  }

  Component.onDestruction: {
    if (_historyLoaded && _dirty) historyFile.setText(Model.serializeHistory(_buckets))
    saveTimer.stop()
    _destroyed = true
    if (slow.running) slow.running = false
    if (fast.running) fast.running = false
  }
}
