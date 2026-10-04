import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Earthnet bar widget: a small live spinning Earth in the bar. Click opens the
// full-resolution panel with the HUD and per-connection labels.
//
// This widget owns the single Python sidecar process for the plugin; the panel
// borrows it through injectPanel() so the compact and full views can never
// disagree about where the connections are.
BarWidget {
  id: root

  moduleName: "earthnet.globe"
  readonly property string moduleId: "earthnet.globe"

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string scriptPath: pluginDir + "/earthnet-omarchy"
  readonly property real spinSpeed: Number(setting("spinSpeed", 0.35))
  // Config seed: the sidecar starts in demo when the setting says so.
  readonly property bool demoSeed: String(setting("demo", "Off")) === "On"
  // Live state: what the sidecar is actually doing right now.
  readonly property bool demoLive: sidecar.frame ? sidecar.frame.demo === true : demoSeed
  readonly property string mmdbPath: String(setting("mmdb", "") || "")

  PythonSidecar {
    id: sidecar
    script: root.scriptPath
    commandArgs: {
      var a = []
      if (root.demoSeed) a.push("--demo")
      if (root.mmdbPath !== "") { a.push("--mmdb"); a.push(root.mmdbPath) }
      return a
    }
  }

  // The bar globe is drawn smaller than the bar height so it reads as an icon
  // rather than filling the slot edge to edge. The widget slot itself spans the
  // full bar height (like the built-in widgets) so the whole area is a live
  // click target; the globe is just drawn smaller and nudged down inside it.
  readonly property real iconScale: 0.5
  readonly property int size: Math.round((bar ? bar.barSize : 26) * iconScale)
  // Space above the icon, in bar pixels. Positive nudges the globe down (more
  // space above); negative lifts it up. Tweak this to taste.
  readonly property real topPadding: 1
  // Optional fine nudge of the globe within the slot, in bar pixels.
  readonly property real verticalNudge: 0
  implicitWidth: size
  implicitHeight: bar ? bar.barSize : 26

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = globe
    if ("hostWidget" in target) target.hostWidget = root
    if ("sidecar" in target) target.sidecar = sidecar
  }

  // ---- shell summon/hide/toggle routing -------------------------------------
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle() }
  function refresh() { if (sidecar) sidecar.poll() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // The live globe itself. Kept compact and non-interactive in the bar; the
  // panel is where you spin, zoom and read the details.
  Globe {
    id: globe
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.verticalCenter: parent.verticalCenter
    anchors.verticalCenterOffset: root.topPadding + root.verticalNudge
    width: root.size
    height: root.size
    compact: true
    interactive: false
    showGraticule: false
    showStars: false
    showBorders: false       // no visible benefit at icon size
    // The bar icon is tiny; ~12 fps is plenty and costs a fraction of the CPU
    // that full-rate projection of the coastline would.
    frameInterval: 80
    spinSpeed: root.spinSpeed
    provider: sidecar
  }

  // Interaction layer.
  //
  // The bar only routes clicks and switches to the pointing cursor for widgets
  // registered as click targets, which is exactly what WidgetButton does on
  // completion (bar.registerClickTarget). A bare MouseArea is covered by the
  // bar's gesture overlay, so events only leaked through around the edges --
  // which is why the icon seemed to have a dead centre, no pointer cursor, and
  // required clicking near the top. WidgetButton gives us the same contract
  // every built-in widget uses; it is transparent here (no label) and the Globe
  // above is the visual.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true      // stay present with no text label
    keepSpace: true
    tooltipText: sidecar.ready
      ? (demoLive ? "Earthnet · demo"
         : "Earthnet · " + (sidecar.frame && sidecar.frame.flows !== undefined
             ? sidecar.frame.flows + " flows" : "live"))
      : "Earthnet · starting…"

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) sidecar.setMode(demoLive ? "live" : "demo")
      else if (mouseButton === Qt.MiddleButton) sidecar.poll()
      else root.togglePanel()
    }
  }
}
