import QtQuick
import Quickshell
import Quickshell.Io

// Process bridge for the earthnet-omarchy Python sidecar.
//
// Owns the long-running child process, parses its line-delimited JSON into
// `init` and `frame` signals, and exposes a `send()` method for commands
// (mode switching, refresh, immediate poll). The bar widget creates one of
// these; the panel borrows the same instance so the two views stay in sync.
QtObject {
  id: root

  // Path to the sidecar executable, injected by the host plugin.
  property string script: ""
  property var commandArgs: []
  // Set once `init` has arrived; used to gate views until data is ready.
  property var init: null
  property var frame: null
  property bool ready: false
  property string lastError: ""
  property bool autoStart: true
  property int restartCount: 0

  signal inited(var data)
  signal framed(var data)
  signal failed(string message)

  property string _buffer: ""

  readonly property var fullCommand: script !== "" ? [script].concat(commandArgs) : []

  function start() {
    if (script === "" || proc.running) return
    proc.running = true
  }

  function stop() {
    if (!proc.running) return
    send("quit")
    proc.running = false
  }

  function send(line) {
    if (!proc.running || script === "") return
    try {
      proc.write(line + "\n")
    } catch (e) {
      // Process not writable yet; the next tick will retry.
    }
  }

  function setMode(mode) { if (root.ready) root.send("mode " + mode) }
  function refresh() { root.send("refresh") }
  function poll() { root.send("poll") }

  function _handleLine(line) {
    var text = String(line || "").trim()
    if (text.length === 0) return
    // Non-JSON lines are the sidecar's human-readable diagnostics.
    if (text.charAt(0) !== "{") {
      root.lastError = text
      return
    }
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      return
    }
    if (!data || !data.type) return
    if (data.type === "init") {
      root.init = data
      root.ready = true
      root.inited(data)
    } else if (data.type === "frame") {
      root.frame = data
      root.framed(data)
    } else if (data.type === "error") {
      root.lastError = String(data.message || "sidecar error")
      root.failed(root.lastError)
    }
  }

  property Process proc: Process {
    id: proc
    command: root.fullCommand
    running: false
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function(line) { root._handleLine(line) }
    }

    onExited: function(code) {
      root.ready = false
      if (!root.autoStart) return
      // Unexpected death (python missing, crash). Back off then bring it back
      // so the widget self-heals instead of going dark for the session.
      root.restartCount++
      if (root.restartCount < 20) root.restartTimer.restart()
    }
  }

  property Timer restartTimer: Timer {
    interval: 2000
    repeat: false
    onTriggered: if (root.autoStart) root.start()
  }

  Component.onCompleted: if (autoStart) start()
}
