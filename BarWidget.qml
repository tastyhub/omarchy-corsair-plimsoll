import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// PSU bar widget: a bolt and the supply's total output in watts, coloured as the
// load climbs, opening a panel with every rail, the thermals, the fan and history.
//
// This item owns the data (PsuData.qml); Panel.qml is a view over it, loaded through
// a Loader so the open/close/opened contract the bar expects exists before the
// panel is ever shown.
//
//   left   toggle the panel
//   middle (nothing)
BarWidget {
  id: root
  moduleName: "io.github.tastyhub.corsair-plimsoll"

  readonly property bool showWatts: root.setting("showWatts", true) !== false
  readonly property bool hideWhenAbsent: root.setting("hideWhenAbsent", true) !== false
  readonly property int pollIntervalSec: Math.max(2, Math.min(60, Math.round(Number(root.setting("pollIntervalSec", 5)) || 5)))

  // The supply's 80 PLUS tier, for the wall-power estimate. Unknown or "none" hides it.
  readonly property string efficiencyRating: Model.normalizeRating(root.setting("efficiencyRating", "platinum"))

  property alias psu: data

  PsuData {
    id: data
    panelOpen: root.opened
    slowIntervalSec: root.pollIntervalSec
  }

  // A supply that is not there leaves no stray icon, but only once the helper has
  // actually said so: until its first line the widget stays put rather than flicker.
  readonly property bool shown: data.present || !data.seen || !root.hideWhenAbsent

  readonly property color loadColor: {
    var base = root.bar ? root.bar.barForeground : Color.foreground
    var hot = root.bar ? root.bar.urgent : Color.urgent
    var sev = Model.severity(data.loadPercent, 60, 100)
    if (!(sev > 0)) return base
    return Qt.rgba(base.r + (hot.r - base.r) * sev, base.g + (hot.g - base.g) * sev, base.b + (hot.b - base.b) * sev, base.a)
  }

  readonly property string labelText: {
    if (!data.present) return ""
    return root.showWatts && !root.vertical ? " " + Model.barText(data.barWatts) : ""
  }

  readonly property string tooltip: {
    if (!data.present) return "Power supply not detected"
    var lines = [(data.info && data.info.model ? data.info.model : "Power supply") + ": " + Model.formatWatts(data.barWatts)
      + " (" + Model.formatPercent(data.loadPercent, 0) + " of " + Math.round(data.rated) + " W)"]
    if (data.barVrm >= 0) lines.push("VRM " + Model.formatTemp(data.barVrm, false))
    if (data.stats) lines.push("12h: " + Model.formatWatts(data.stats.min) + " to " + Model.formatWatts(data.stats.max))
    return lines.join("\n")
  }

  // ---- Panel lifecycle. Shape contract for shell.summon/hide/toggle routing
  //      (Bar.findPanelWidget requires open/close/opened).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = root
    if ("hostWidget" in target) target.hostWidget = root
  }

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

  IpcHandler {
    target: "psu"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  visible: root.shown
  implicitWidth: root.shown ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelText
    foreground: root.loadColor
    useActiveColor: false
    fontSize: root.labelText.length > 1 ? Style.font.body : Style.bar.iconFont
    tooltipText: root.tooltip
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.toggle()
    }
  }
}
