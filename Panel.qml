import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Earthnet detail panel: the full-resolution live globe with the Jarvis HUD,
// the per-connection legend, and keyboard controls. Opened from the bar globe
// or via `omarchy-shell shell toggle earthnet.globe`.
Panel {
  id: root
  moduleName: "earthnet.globe"
  ipcTarget: "earthnet.globe"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Injected by BarWidget.injectPanel(); owns the Python sidecar process.
  property var sidecar: null

  // View state
  property bool paused: false
  property bool showTraces: true
  property bool showGraticule: true
  property bool showStars: true
  property bool showLabels: true
  property bool showHud: true

  // Which connection's detail card is open, keyed by trace id (the remote IP),
  // so it survives the per-frame re-sort of the list.
  property string selectedId: ""
  readonly property bool detailOpen: selectedId !== ""

  readonly property real spinSpeed: Number(setting("spinSpeed", 0.35))
  readonly property var traces: (showTraces && sidecar && sidecar.frame) ? (sidecar.frame.traces || []) : []
  readonly property int flowCount: sidecar && sidecar.frame && sidecar.frame.flows !== undefined ? sidecar.frame.flows : 0
  readonly property var backend: sidecar && sidecar.frame ? (sidecar.frame.backend || "none") : "none"
  readonly property var home: sidecar && sidecar.init ? sidecar.init.home : null
  readonly property bool demoMode: sidecar && sidecar.frame ? sidecar.frame.demo === true : false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function openFromHotkey() { root.controller.show() }
  function open() { root.controller.show() }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.openFromHotkey() }

  // ---- formatting helpers ---------------------------------------------------
  function flagEmoji(cc) {
    var s = String(cc || "").toUpperCase()
    if (s.length !== 2) return ""
    var a = s.charCodeAt(0), b = s.charCodeAt(1)
    if (a < 65 || a > 90 || b < 65 || b > 90) return ""
    return String.fromCodePoint(0x1F1E6 + (a - 65)) + String.fromCodePoint(0x1F1E6 + (b - 65))
  }
  function fmtDuration(age) {
    age = Number(age) || 0
    if (age < 60) return Math.floor(age) + "s"
    if (age < 3600) return Math.floor(age / 60) + "m" + ("0" + Math.floor(age % 60)).slice(-2) + "s"
    return Math.floor(age / 3600) + "h" + ("0" + Math.floor((age % 3600) / 60)).slice(-2) + "m"
  }
  function localTime(lon, age) {
    var offsetSec = Math.round(Number(lon || 0) / 15.0 * 3600)
    var d = new Date((Date.now() + offsetSec * 1000) + (Number(age) || 0) * 1000)
    return ("0" + ((d.getUTCHours() + 24) % 24)).slice(-2) + ":" + ("0" + d.getUTCMinutes()).slice(-2)
  }
  function labelOf(tr) {
    return truncate(tr.label || tr.city || tr.country || "?", 11)
  }
  // Direction of the flow: who initiated the connection.
  function dirGlyph(d) {
    if (d === "in") return "↓"
    if (d === "both") return "↕"
    return "↑"
  }
  function procOf(tr) {
    return truncate(tr.process || "", 24)
  }
  // Human byte rate: B/s, KB/s, MB/s, GB/s.
  function fmtRate(bps) {
    bps = Number(bps) || 0
    if (bps < 1) return ""
    if (bps < 1024) return Math.round(bps) + " B/s"
    if (bps < 1024 * 1024) return (bps / 1024).toFixed(1) + " KB/s"
    if (bps < 1024 * 1024 * 1024) return (bps / 1048576).toFixed(1) + " MB/s"
    return (bps / 1073741824).toFixed(2) + " GB/s"
  }
  function fmtRtt(ms) {
    ms = Number(ms) || 0
    if (ms <= 0) return ""
    return ms < 10 ? ms.toFixed(1) + "ms" : Math.round(ms) + "ms"
  }
  // The network operator, preferring a short ISP name over the long "AS…" line.
  function ispOf(tr) {
    return truncate(tr.isp || tr.org || tr["as"] || "", 30)
  }
  function truncate(s, n) {
    var t = String(s || "").replace(/[\r\n\t]+/g, " ")
    return t.length > n ? t.slice(0, n) : t
  }
  function sortedTraces() {
    var t = (traces || []).slice()
    t.sort(function(a, b) { return (b.alpha || 0) - (a.alpha || 0) || (b.age || 0) - (a.age || 0) })
    return t
  }
  function traceById(id) {
    var list = traces || []
    for (var i = 0; i < list.length; i++)
      if (String(list[i].id || "") === String(id)) return list[i]
    return null
  }
  readonly property var selectedTrace: detailOpen ? traceById(selectedId) : null

  // ---- connection detail helpers -------------------------------------------
  function dirWord(d) {
    return d === "in" ? "inbound (remote initiated)"
      : d === "both" ? "bidirectional" : "outbound (you initiated)"
  }
  function fmtBytes(n) {
    n = Number(n) || 0
    if (n < 1024) return n + " B"
    if (n < 1048576) return (n / 1024).toFixed(1) + " KB"
    if (n < 1073741824) return (n / 1048576).toFixed(1) + " MB"
    return (n / 1073741824).toFixed(2) + " GB"
  }
  function coordStr(tr) {
    if (!tr || tr.lat === undefined || tr.lon === undefined) return "-"
    var la = Math.abs(tr.lat).toFixed(3) + "°" + (tr.lat >= 0 ? "N" : "S")
    var lo = Math.abs(tr.lon).toFixed(3) + "°" + (tr.lon >= 0 ? "E" : "W")
    return la + "  " + lo
  }
  function detailRows(tr) {
    if (!tr) return []
    var rows = []
    rows.push(["Remote", String(tr.id || "-")])
    rows.push(["Location", (tr.city || "") + (tr.country ? (tr.city ? ", " : "") + tr.country : "") || "-"])
    rows.push(["Coordinates", coordStr(tr)])
    rows.push(["Network", tr.isp || tr.org || tr["as"] || "-"])
    if (tr["as"]) rows.push(["ASN", tr["as"]])
    rows.push(["Direction", dirWord(tr.direction)])
    rows.push(["Protocol", String(tr.proto || "ip").toUpperCase() + (tr.port ? (":" + tr.port) : "")])
    if (tr.state) rows.push(["State", String(tr.state)])
    rows.push(["Process", tr.process || "-"])
    if (tr.pids) rows.push(["PID", String(tr.pids)])
    rows.push(["Flows", String(tr.nflows !== undefined ? tr.nflows : 1)])
    rows.push(["Throughput", fmtRate(tr.rate || 0) || "idle"])
    rows.push(["Sent / Recv", fmtBytes(tr.tx || 0) + "  /  " + fmtBytes(tr.rx || 0)])
    rows.push(["Latency", fmtRtt(tr.rtt || 0) || "-"])
    rows.push(["Duration", fmtDuration(tr.age || 0)])
    rows.push(["Local time", localTime(tr.lon, 0)])
    return rows
  }
  function copySelected() {
    var tr = selectedTrace
    if (!tr || !bar) return
    var lines = detailRows(tr).map(function(r) { return r[0] + ": " + r[1] })
    bar.run("printf %s " + Util.shellQuote(lines.join("\n") + "\n") + " | wl-copy")
  }

  // ---- controls -------------------------------------------------------------
  function handleText(t) {
    var k = String(t || "").toLowerCase()
    if (k === "t") showTraces = !showTraces
    else if (k === "g") showGraticule = !showGraticule
    else if (k === "s") showStars = !showStars
    else if (k === "a") showLabels = !showLabels
    else if (k === "u") showHud = !showHud
    else if (k === "r") { if (sidecar) sidecar.refresh() }
    else if (k === "d") { if (sidecar) sidecar.setMode(demoMode ? "live" : "demo") }
    // With a connection detail open, 'c' copies it; otherwise it clears traces.
    else if (k === "c") { if (detailOpen) copySelected(); else if (sidecar) sidecar.send("clear") }
    else if (k === "+" || k === "=") globe.zoom = Math.min(globe.maxZoom, globe.zoom * 1.2)
    else if (k === "-" || k === "_") globe.zoom = Math.max(globe.minZoom, globe.zoom / 1.2)
  }
  function nudge(dx, dy) {
    globe.tiltPinned = true
    globe.spin += dx * 0.06
    globe.tilt = Math.max(-1.35, Math.min(1.35, globe.tilt + dy * 0.06))
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(860))
    contentHeight: panel.fittedContentHeight(Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the detail card is open, Esc closes it and Enter copies; the
      // globe otherwise keeps those keys.
      onCloseRequested: { if (root.detailOpen) root.selectedId = ""; else root.close() }
      onReturnRequested: {
        if (root.detailOpen) root.copySelected()
        else if (root.sidecar) root.sidecar.refresh()
      }
      onMoveRequested: function(dx, dy) { if (!root.detailOpen) root.nudge(dx, dy) }
      onActivateRequested: if (!root.detailOpen) root.paused = !root.paused
      onTextKey: function(t) { root.handleText(t) }

      Item {
        id: content
        anchors.fill: parent

        // ---- header -----------------------------------------------------
        // Title/mode on the left, status on the right. Anchoring the two
        // groups independently keeps the status inside the card no matter how
        // long the labels get (a single Row with a hand-computed spacer
        // overflowed the panel once the mode text and spacing were counted).
        Item {
          id: header
          anchors { left: parent.left; right: parent.right; top: parent.top }
          height: Math.max(headerTitle.implicitHeight, status.implicitHeight)

          Row {
            id: headerTitle
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Text {
              id: headerText
              text: "◉ EARTHNET"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              font.letterSpacing: 2
            }
            Text {
              text: root.demoMode ? "· DEMO" : "· LIVE"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.letterSpacing: 2
            }
          }

          Text {
            id: status
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            // Never run under the title; shrink + elide if the card is narrow.
            width: Math.min(implicitWidth, parent.width - headerTitle.width - Style.space(16))
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideLeft
            text: "flows " + root.flowCount + "   links " + (root.traces ? root.traces.length : 0)
              + (root.home ? ("   origin " + root.home.lat.toFixed(2) + "," + root.home.lon.toFixed(2)) : "")
              + (root.paused ? "   ⏸ PAUSED" : "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- body: globe + legend --------------------------------------
        Item {
          id: body
          anchors {
            left: parent.left; right: parent.right
            top: header.bottom; bottom: footer.top
            topMargin: Style.space(12); bottomMargin: Style.space(12)
          }

          Globe {
            id: globe
            // Square, as tall as the body allows but never wide enough to
            // collide with the legend column.
            readonly property real side: Math.min(body.height, body.width * 0.56)
            width: side
            height: side
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            interactive: true
            // Only animate while the panel is actually on screen; the panel
            // component stays loaded (and its Canvas would otherwise repaint)
            // even when the popout is closed.
            running: root.opened && !root.paused
            // ~30 fps: smooth to the eye, and halves the per-frame projection
            // cost of the 50m coastline versus the compositor's native rate.
            frameInterval: 40
            spinSpeed: root.spinSpeed
            showGraticule: root.showGraticule
            showStars: root.showStars
            showTraces: root.showTraces
            showHome: true
            provider: root.sidecar
          }

          // Legend: every live connection, colour-matched to its arc.
          Column {
            id: legend
            visible: root.showLabels
            anchors {
              left: globe.right; leftMargin: Style.space(18)
              right: parent.right; top: parent.top; bottom: parent.bottom
            }
            spacing: Style.space(7)

            Text {
              text: "ACTIVE CONNECTIONS"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 1.5
            }

            Repeater {
              model: root.sortedTraces()

              // Two lines per link: the destination + protocol on the first,
              // the owning process and flow direction on the second. Clicking
              // a row opens the connection's detail card.
              Item {
                id: rowItem
                required property var modelData
                required property int index
                readonly property bool hovered: rowMouse.containsMouse
                readonly property bool isSelected:
                  root.selectedId !== "" && String(modelData.id || "") === root.selectedId
                width: legend.width
                height: Math.max(Style.space(30), rowInner.implicitHeight + Style.space(6))
                visible: index < Math.max(0, Math.floor((body.height - Style.space(20)) / height))

                // Hover / selected background.
                Rectangle {
                  anchors.fill: parent
                  anchors.leftMargin: -Style.space(6)
                  anchors.rightMargin: -Style.space(6)
                  radius: Style.cornerRadius
                  color: rowItem.isSelected
                    ? Style.selectedFillFor(root.foreground, root.accent)
                    : rowItem.hovered ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"
                }

                Row {
                  id: rowInner
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                  spacing: Style.space(8)

                  Rectangle {
                    width: Style.space(9); height: Style.space(9)
                    radius: width / 2
                    color: modelData.color || root.accent
                    anchors.top: parent.top
                    anchors.topMargin: Style.space(4)
                  }

                  Column {
                    width: parent.width - Style.space(17)
                    spacing: 1

                  // Fixed-width trailing columns; the destination label takes
                  // whatever width is left so the row can never overflow the
                  // legend (eliding the name instead).
                  Row {
                    id: line1
                    width: parent.width
                    spacing: Style.space(6)

                    readonly property real protoW: Style.space(56)
                    readonly property real durW: Style.space(42)
                    readonly property real timeW: Style.space(40)
                    readonly property real rateW: Style.space(62)
                    readonly property real rttW: Style.space(46)
                    readonly property real fixed: protoW + durW + timeW + rateW + rttW
                      + spacing * 5
                    readonly property real labelW: Math.max(Style.space(40), width - fixed)

                    Text {
                      text: root.dirGlyph(modelData.direction) + " " + root.labelOf(modelData)
                      width: line1.labelW
                      elide: Text.ElideRight
                      color: modelData.color || root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      text: String(modelData.proto || "ip").toUpperCase().slice(0, 4)
                        + ":" + (modelData.port || "-")
                      width: line1.protoW
                      elide: Text.ElideRight
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      text: root.fmtDuration(modelData.age || 0)
                      width: line1.durW
                      horizontalAlignment: Text.AlignRight
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      text: root.localTime(modelData.lon, 0)
                      width: line1.timeW
                      horizontalAlignment: Text.AlignRight
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      // Throughput, right-aligned so the column lines up.
                      text: root.fmtRate(modelData.rate || 0)
                      width: line1.rateW
                      horizontalAlignment: Text.AlignRight
                      color: (modelData.rate || 0) > 0 ? root.accent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      text: root.fmtRtt(modelData.rtt || 0)
                      width: line1.rttW
                      horizontalAlignment: Text.AlignRight
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: {
                      var d = modelData.direction === "in" ? "inbound"
                        : modelData.direction === "both" ? "both ways" : "outbound"
                      var p = root.procOf(modelData)
                      var parts = []
                      if (p) parts.push(p)
                      parts.push(d)
                      var isp = root.ispOf(modelData)
                      if (isp) parts.push(isp)
                      return parts.join("  ·  ")
                    }
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    opacity: 0.85
                  }
                }
                }

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  acceptedButtons: Qt.LeftButton
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var id = String(modelData.id || "")
                    root.selectedId = (root.selectedId === id) ? "" : id
                  }
                }
              }
            }

            Text {
              visible: root.traces.length === 0
              text: root.sidecar && root.sidecar.ready ? "no active connections" : "starting sidecar…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        // ---- connection detail overlay ---------------------------------
        // Opened by clicking a legend row. Shows every field we have for the
        // selected connection; a full-card click-catcher closes it.
        Item {
          id: detail
          anchors.fill: body
          visible: root.detailOpen && root.selectedTrace !== null
          z: 50

          // Dim the globe behind the card.
          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.45)

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton
              onClicked: root.selectedId = ""
            }
          }

          Rectangle {
            id: card
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(parent.width * 0.62, Style.space(460))
            height: Math.min(parent.height - Style.space(8), detailColumn.implicitHeight + Style.space(28))
            color: Color.popups.background
            radius: Style.cornerRadius
            border.width: 1
            border.color: Color.popups.border

            MouseArea { anchors.fill: parent }   // swallow clicks

            Column {
              id: detailColumn
              anchors {
                left: parent.left; right: parent.right; top: parent.top
                leftMargin: Style.space(16); rightMargin: Style.space(16)
                topMargin: Style.space(14)
              }
              spacing: Style.space(10)

              Row {
                width: parent.width
                spacing: Style.space(8)

                Rectangle {
                  width: Style.space(10); height: Style.space(10)
                  radius: width / 2
                  color: root.selectedTrace ? (root.selectedTrace.color || root.accent) : root.accent
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: root.selectedTrace ? root.labelOf(root.selectedTrace) : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Repeater {
                model: root.selectedTrace ? root.detailRows(root.selectedTrace) : []

                Row {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(10)

                  Text {
                    text: modelData[0]
                    width: Style.space(92)
                    color: root.dim
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    text: modelData[1]
                    width: parent.width - Style.space(92) - Style.space(10)
                    color: root.foreground
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }

              Text {
                width: parent.width
                text: "[esc] close   [enter] copy details   [click outside] dismiss"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                topPadding: Style.space(2)
              }
            }
          }
        }

        // ---- footer / key hints ----------------------------------------
        Item {
          id: footer
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          height: footerText.implicitHeight

          Text {
            id: footerText
            anchors.left: parent.left
            anchors.right: srcText.left
            anchors.rightMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: "[space] pause  [t] traces  [g] grid  [s] stars  [a] labels  [d] demo  [r] refresh  [c] clear  [+/−] zoom  ·  click a link for details"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            id: srcText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "src " + root.backend
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
