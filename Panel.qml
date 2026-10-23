import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Details panel for the PSU widget: the live, animated view of the supply.
//
// BarWidget.qml owns the data (through PsuData.qml); this panel hosts PsuView.qml
// over it and does nothing else.
Panel {
  id: root
  moduleName: "io.github.tastyhub.corsair-plimsoll"
  ipcTarget: "psu-panel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // The bar tracks the widget mounted in its slot, not this nested panel, so
  // the popout coordinator has to key off the host widget.
  readonly property var barIdentity: hostWidget || root

  readonly property var psu: root.hostWidget ? root.hostWidget.psu : null
  readonly property color contentForeground: root.barForeground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(view.implicitHeight + Style.space(16), Style.space(2000))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: view.width
        contentHeight: view.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        PsuView {
          id: view
          width: scroll.width
          active: root.opened
          present: root.psu ? root.psu.present : false
          info: root.psu ? root.psu.info : null
          sample: root.psu ? root.psu.sample : null
          history: root.psu ? root.psu.history : []
          stats: root.psu ? root.psu.stats : null
          energyWh: root.psu ? root.psu.energyWh : 0
          rating: root.hostWidget ? root.hostWidget.efficiencyRating : "platinum"
          baseColor: root.contentForeground
          hotColor: root.bar ? root.bar.urgent : Color.urgent
          fontFamily: root.contentFontFamily
        }
      }
    }
  }
}
