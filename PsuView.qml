import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The PSU panel's content: everything visual and nothing that talks to hardware.
// The host (Panel.qml) hands it the parsed readings and it draws them, which also
// lets it be rendered on its own with made-up readings.
//
// Animations (dashes along the power-flow lines, the fan rotor, the gauge sweep)
// run only while `active`, i.e. while the panel is open.
Item {
  id: view

  // ---- readings, from the host
  property var info: null         // { vendor, model, ratedW, limits }
  property var sample: null       // latest full sample
  property var history: []        // recent samples, oldest first: { total, "12v", "5v", "3v3" } watts
  property var stats: null        // 12 h { min, max, avg }
  property real energyWh: 0
  property bool present: false
  property bool active: true
  property bool fahrenheit: false
  // The supply's 80 PLUS tier (bronze, silver, gold, platinum, titanium), used only to
  // estimate wall power; "" hides the estimate rather than guess.
  property string rating: "platinum"

  // ---- tokens, from the host
  property color baseColor: Color.foreground
  property color accent: Color.accent
  property color hotColor: Color.urgent
  property string fontFamily: Style.font.family

  readonly property real rated: info && info.ratedW > 0 ? info.ratedW : 1200
  readonly property real totalW: sample && sample.w && sample.w.total !== undefined ? sample.w.total : -1
  readonly property real loadPct: totalW >= 0 ? Model.loadPercent(totalW, rated) : -1
  readonly property real tempLimit: info && info.limits && info.limits.temp > 0 ? info.limits.temp : 70
  readonly property var ac: totalW >= 0 ? Model.estimatedAcWatts(totalW, rated, rating) : null
  readonly property var rails: Model.RAILS
  readonly property color dim: Qt.darker(baseColor, 1.45)

  implicitHeight: content.implicitHeight

  // One line of the figures beside the gauge: its label, current value and tooltip.
  function statRow(key) {
    if (key === "range") return { label: "12h range", value: stats ? Model.formatWatts(stats.min) + " – " + Model.formatWatts(stats.max) : "collecting…", tip: "Lowest and highest total output in the last 12 hours (kept across restarts)." }
    if (key === "average") return { label: "12h average", value: stats ? Model.formatWatts(stats.avg) : "–", tip: "Average total output over the last 12 hours." }
    if (key === "energy") return { label: "Energy", value: Model.formatEnergy(energyWh), tip: "Energy delivered since the shell started." }
    if (key === "ac") return { label: "AC draw (est.)", value: ac ? "~" + Math.round(ac.watts) + " W" : "–", tip: "An estimate: the supply does not report wall power. Uses the " + Model.ratingLabel(rating) + " minimum efficiency at 115 V (" + Model.ratingNote(rating) + "), so the real figure is a little lower." }
    return { label: "Lost as heat (est.)", value: ac ? "~" + Math.round(ac.heat) + " W" : "–", tip: "Estimated conversion loss, from the same certification minimums." }
  }

  function railPower(key) { return sample && sample.w && sample.w[key] !== undefined ? sample.w[key] : -1 }
  function railVolts(key) { return sample && sample.v && sample.v[key] !== undefined ? sample.v[key] : -1 }
  function railAmps(key) { return sample && sample.a && sample.a[key] !== undefined ? sample.a[key] : -1 }
  function bandColor(band) {
    if (band === "bad") return hotColor
    if (band === "warn") return Qt.rgba((accent.r + hotColor.r) / 2, (accent.g + hotColor.g) / 2, (accent.b + hotColor.b) / 2, 1)
    return accent
  }
  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function warm(from, amount) {
    if (!(amount > 0)) return from
    var t = Math.min(1, amount)
    return Qt.rgba(from.r + (hotColor.r - from.r) * t, from.g + (hotColor.g - from.g) * t, from.b + (hotColor.b - from.b) * t, from.a)
  }

  // ---- animation clock
  //
  // Each flow line keeps its own phase and advances it at a speed taken from the
  // current it carries. Integrating (rather than computing phase from time and
  // speed) means a change in load speeds the dashes up smoothly instead of
  // making them jump.
  property real phaseAc: 0
  property var phaseRail: [0, 0, 0]
  property real fanAngle: 0
  property real shownLoad: 0

  FrameAnimation {
    running: view.active && view.present
    onTriggered: {
      var dt = Math.min(frameTime, 0.1)
      var accAmps = view.railAmps("12v") + view.railAmps("5v") + view.railAmps("3v3")
      view.phaseAc += dt * (6 + Math.sqrt(Math.max(0, view.totalW)) * 1.2)
      var next = []
      for (var i = 0; i < view.rails.length; i++) {
        var amps = Math.max(0, view.railAmps(view.rails[i].key))
        next.push(view.phaseRail[i] + dt * (5 + Math.sqrt(amps) * 7))
      }
      view.phaseRail = next
      var fan = view.sample && view.sample.fan ? view.sample.fan : 0
      view.fanAngle = (view.fanAngle + dt * 360 * (fan > 0 ? 0.4 + 2.0 * Math.min(1, fan / 2000) : 0)) % 360
    }
  }

  // The gauge eases toward the load instead of snapping to it.
  Behavior on shownLoad { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
  onLoadPctChanged: shownLoad = loadPct >= 0 ? Math.min(100, loadPct) : 0

  Column {
    id: content
    width: parent.width
    spacing: Style.space(12)

    // ------------------------------------------------------------- header
    Row {
      width: parent.width
      spacing: Style.space(10)

      Text {
        id: bolt
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: ""
        color: view.accent
        font.family: view.fontFamily
        font.pixelSize: Style.font.display
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - bolt.implicitWidth - lineChip.width - parent.spacing * 2

        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: view.info && view.info.model ? view.info.model : "Power supply"
          color: view.baseColor
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: view.present
            ? ((view.info && view.info.vendor ? view.info.vendor : "") + (view.info && view.info.ratedW ? "  ·  " + view.info.ratedW + " W" : "") + (Model.ratingLabel(view.rating) !== "" ? "  ·  " + Model.ratingLabel(view.rating) : ""))
            : "not detected"
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // Mains voltage, with how far it is from the 115 V nominal.
      Rectangle {
        id: lineChip
        anchors.verticalCenter: parent.verticalCenter
        visible: view.sample && view.sample.vin !== null && view.sample.vin !== undefined
        width: lineText.implicitWidth + Style.space(14)
        height: lineText.implicitHeight + Style.space(8)
        radius: Style.cornerRadius
        readonly property string band: view.sample ? Model.lineBand(view.sample.vin, 115) : "unknown"
        color: view.tint(view.bandColor(band), 0.14)
        border.color: view.tint(view.bandColor(band), 0.5)
        border.width: 1

        Text {
          id: lineText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "AC " + (view.sample ? Model.formatVolts(view.sample.vin, 0) : "–")
          color: view.bandColor(lineChip.band)
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        HoverHandler { id: lineHover }
        PanelToolTip {
          visible: lineHover.hovered
          text: "Mains input\n" + (view.sample ? Model.formatVolts(view.sample.vin, 1) : "–")
            + "  (" + (view.sample ? Model.formatSigned(Model.deviationPercent(view.sample.vin, 115)) : "–") + " from 115 V)"
            + "\nNo input current is reported, so wall power cannot be measured."
        }
      }
    }

    Text {
      width: parent.width
      visible: !view.present
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: "No Corsair PSU found. This needs the corsairpsu kernel driver and a Corsair i-series supply connected by its USB cable."
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }

    // --------------------------------------------------------- power flow
    Item {
      id: flow
      width: parent.width
      height: Style.space(112)
      visible: view.present

      readonly property real acW: Style.space(60)
      readonly property real railW: Style.space(88)
      readonly property real psuW: Style.space(112)
      readonly property real gap: Math.max(Style.space(20), (width - acW - psuW - railW) / 2)
      readonly property real psuX: acW + gap
      readonly property real railX: width - railW
      readonly property real midY: height / 2
      readonly property real nodeH: Style.space(30)
      function nodeY(i) { return Style.space(2) + i * (nodeH + Style.space(7)) }

      // Faint wiring, always drawn.
      Shape {
        anchors.fill: parent
        ShapePath {
          strokeColor: view.tint(view.baseColor, 0.12)
          strokeWidth: 2
          fillColor: "transparent"
          startX: flow.acW; startY: flow.midY
          PathLine { x: flow.psuX; y: flow.midY }
        }
        ShapePath {
          strokeColor: view.tint(view.baseColor, 0.12)
          strokeWidth: 2
          fillColor: "transparent"
          startX: flow.psuX + flow.psuW; startY: flow.midY
          PathCubic { x: flow.railX; y: flow.nodeY(0) + flow.nodeH / 2; control1X: flow.psuX + flow.psuW + flow.gap * 0.6; control1Y: flow.midY; control2X: flow.railX - flow.gap * 0.6; control2Y: flow.nodeY(0) + flow.nodeH / 2 }
        }
        ShapePath {
          strokeColor: view.tint(view.baseColor, 0.12)
          strokeWidth: 2
          fillColor: "transparent"
          startX: flow.psuX + flow.psuW; startY: flow.midY
          PathLine { x: flow.railX; y: flow.nodeY(1) + flow.nodeH / 2 }
        }
        ShapePath {
          strokeColor: view.tint(view.baseColor, 0.12)
          strokeWidth: 2
          fillColor: "transparent"
          startX: flow.psuX + flow.psuW; startY: flow.midY
          PathCubic { x: flow.railX; y: flow.nodeY(2) + flow.nodeH / 2; control1X: flow.psuX + flow.psuW + flow.gap * 0.6; control1Y: flow.midY; control2X: flow.railX - flow.gap * 0.6; control2Y: flow.nodeY(2) + flow.nodeH / 2 }
        }
      }

      // Moving dashes: speed follows current, weight follows power.
      Shape {
        anchors.fill: parent
        visible: view.present
        layer.enabled: true
        layer.samples: 4

        ShapePath {
          strokeColor: view.accent
          strokeWidth: 1.2 + 4.5 * Math.sqrt(Math.max(0, view.totalW) / view.rated)
          strokeStyle: ShapePath.DashLine
          dashPattern: [1.6, 2.4]
          dashOffset: -view.phaseAc
          capStyle: ShapePath.RoundCap
          fillColor: "transparent"
          startX: flow.acW; startY: flow.midY
          PathLine { x: flow.psuX; y: flow.midY }
        }
        ShapePath {
          strokeColor: view.bandColor(Model.railBand(Model.deviationPercent(view.railVolts("12v"), 12)))
          strokeWidth: 1.2 + 4.5 * Math.sqrt(Math.max(0, view.railPower("12v")) / view.rated)
          strokeStyle: ShapePath.DashLine
          dashPattern: [1.6, 2.4]
          dashOffset: -view.phaseRail[0]
          capStyle: ShapePath.RoundCap
          fillColor: "transparent"
          startX: flow.psuX + flow.psuW; startY: flow.midY
          PathCubic { x: flow.railX; y: flow.nodeY(0) + flow.nodeH / 2; control1X: flow.psuX + flow.psuW + flow.gap * 0.6; control1Y: flow.midY; control2X: flow.railX - flow.gap * 0.6; control2Y: flow.nodeY(0) + flow.nodeH / 2 }
        }
        ShapePath {
          strokeColor: view.bandColor(Model.railBand(Model.deviationPercent(view.railVolts("5v"), 5)))
          strokeWidth: 1.2 + 4.5 * Math.sqrt(Math.max(0, view.railPower("5v")) / view.rated)
          strokeStyle: ShapePath.DashLine
          dashPattern: [1.6, 2.4]
          dashOffset: -view.phaseRail[1]
          capStyle: ShapePath.RoundCap
          fillColor: "transparent"
          startX: flow.psuX + flow.psuW; startY: flow.midY
          PathLine { x: flow.railX; y: flow.nodeY(1) + flow.nodeH / 2 }
        }
        ShapePath {
          strokeColor: view.bandColor(Model.railBand(Model.deviationPercent(view.railVolts("3v3"), 3.3)))
          strokeWidth: 1.2 + 4.5 * Math.sqrt(Math.max(0, view.railPower("3v3")) / view.rated)
          strokeStyle: ShapePath.DashLine
          dashPattern: [1.6, 2.4]
          dashOffset: -view.phaseRail[2]
          capStyle: ShapePath.RoundCap
          fillColor: "transparent"
          startX: flow.psuX + flow.psuW; startY: flow.midY
          PathCubic { x: flow.railX; y: flow.nodeY(2) + flow.nodeH / 2; control1X: flow.psuX + flow.psuW + flow.gap * 0.6; control1Y: flow.midY; control2X: flow.railX - flow.gap * 0.6; control2Y: flow.nodeY(2) + flow.nodeH / 2 }
        }
      }

      // The wall.
      Rectangle {
        x: 0
        y: flow.midY - height / 2
        width: flow.acW
        height: Style.space(40)
        radius: Style.cornerRadius
        color: view.tint(view.baseColor, 0.06)
        border.color: view.tint(view.baseColor, 0.2)
        border.width: 1

        Column {
          anchors.centerIn: parent
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: "AC"
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: view.sample ? Model.formatVolts(view.sample.vin, 0) : "–"
            color: view.baseColor
            font.family: view.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }
      }

      // The supply.
      Rectangle {
        x: flow.psuX
        y: flow.midY - height / 2
        width: flow.psuW
        height: Style.space(76)
        radius: Style.cornerRadius
        color: view.tint(view.accent, 0.08)
        border.color: view.tint(view.warm(view.accent, Model.severity(view.sample && view.sample.vrm !== null && view.sample.vrm !== undefined ? view.sample.vrm : 0, view.tempLimit - 25, view.tempLimit)), 0.7)
        border.width: 1

        Column {
          anchors.centerIn: parent
          spacing: Style.space(1)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: view.info && view.info.model ? view.info.model : "PSU"
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: view.totalW >= 0 ? Math.round(view.totalW) + " W" : "–"
            color: view.baseColor
            font.family: view.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: view.loadPct >= 0 ? Model.formatPercent(view.loadPct, 0) + " of " + Math.round(view.rated) + " W" : ""
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // The three rails.
      Repeater {
        model: view.rails

        Rectangle {
          required property var modelData
          required property int index
          x: flow.railX
          y: flow.nodeY(index)
          width: flow.railW
          height: flow.nodeH
          radius: Style.cornerRadius
          readonly property string band: Model.railBand(Model.deviationPercent(view.railVolts(modelData.key), modelData.nominal))
          color: view.tint(view.bandColor(band), 0.1)
          border.color: view.tint(view.bandColor(band), 0.5)
          border.width: 1

          Row {
            anchors.centerIn: parent
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: modelData.label
              color: view.bandColor(band)
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Column {
              anchors.verticalCenter: parent.verticalCenter
              Text {
                textFormat: Text.PlainText
                text: Model.formatWatts(view.railPower(modelData.key) >= 0 ? view.railPower(modelData.key) : null)
                color: view.baseColor
                font.family: view.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: Model.formatAmps(view.railAmps(modelData.key) >= 0 ? view.railAmps(modelData.key) : null)
                color: view.dim
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption - 1
              }
            }
          }
        }
      }
    }

    // ----------------------------------------------- load gauge and 12 h figures
    Row {
      width: parent.width
      spacing: Style.space(14)
      visible: view.present

      Item {
        id: gauge
        width: Style.space(96)
        height: Style.space(96)

        readonly property real radius: width / 2 - Style.space(7)

        Shape {
          anchors.fill: parent
          layer.enabled: true
          layer.samples: 4

          ShapePath {
            strokeColor: view.tint(view.baseColor, 0.12)
            strokeWidth: Style.space(7)
            capStyle: ShapePath.RoundCap
            fillColor: "transparent"
            PathAngleArc { centerX: gauge.width / 2; centerY: gauge.height / 2; radiusX: gauge.radius; radiusY: gauge.radius; startAngle: 135; sweepAngle: 270 }
          }
          ShapePath {
            strokeColor: view.warm(view.accent, Model.severity(view.shownLoad, 60, 100))
            strokeWidth: Style.space(7)
            capStyle: ShapePath.RoundCap
            fillColor: "transparent"
            PathAngleArc { centerX: gauge.width / 2; centerY: gauge.height / 2; radiusX: gauge.radius; radiusY: gauge.radius; startAngle: 135; sweepAngle: Math.max(0.5, 270 * Math.min(1, view.shownLoad / 100)) }
          }
        }

        // The 12 h high-water mark.
        Rectangle {
          visible: view.stats !== null && view.stats !== undefined
          readonly property real frac: view.stats ? Math.min(1, view.stats.max / view.rated) : 0
          readonly property real angle: (135 + 270 * frac) * Math.PI / 180
          width: Style.space(3)
          height: Style.space(11)
          radius: 1
          color: view.hotColor
          opacity: 0.85
          x: gauge.width / 2 + Math.cos(angle) * gauge.radius - width / 2
          y: gauge.height / 2 + Math.sin(angle) * gauge.radius - height / 2
          rotation: angle * 180 / Math.PI + 90
        }

        Column {
          anchors.centerIn: parent
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: view.loadPct >= 0 ? Math.round(view.loadPct) + "%" : "–"
            color: view.baseColor
            font.family: view.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: "load"
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        HoverHandler { id: gaugeHover }
        PanelToolTip {
          visible: gaugeHover.hovered
          text: "Output as a share of the rated " + Math.round(view.rated) + " W\nThe red tick is the highest in the last 12 hours."
        }
      }

      Column {
        width: parent.width - gauge.width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        // The model is only which rows exist; each row reads its own live values, so
        // the rows are not rebuilt every second (which would also reset a hover tip).
        Repeater {
          model: view.ac !== null ? ["range", "average", "energy", "ac", "heat"] : ["range", "average", "energy"]

          Row {
            required property var modelData
            readonly property var row: view.statRow(modelData)
            width: parent.width

            Text {
              id: statLabel
              textFormat: Text.PlainText
              text: row.label
              color: view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              width: parent.width - statLabel.implicitWidth
              horizontalAlignment: Text.AlignRight
              textFormat: Text.PlainText
              text: row.value
              color: view.baseColor
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            HoverHandler { id: statHover }
            PanelToolTip { visible: statHover.hovered; text: row.tip }
          }
        }
      }
    }

    // ---------------------------------------------------- rails in detail
    Row {
      id: railRow
      width: parent.width
      spacing: Style.space(8)
      visible: view.present

      Repeater {
        model: view.rails

        Rectangle {
          id: card
          required property var modelData
          width: (railRow.width - railRow.spacing * 2) / 3
          height: cardCol.implicitHeight + Style.space(16)
          radius: Style.cornerRadius
          color: view.tint(view.baseColor, 0.04)
          border.color: view.tint(view.baseColor, 0.1)
          border.width: 1

          readonly property real volts: view.railVolts(modelData.key)
          readonly property real dev: volts >= 0 ? Model.deviationPercent(volts, modelData.nominal) : NaN
          readonly property string band: volts >= 0 ? Model.railBand(dev) : "unknown"
          readonly property var limits: view.info && view.info.limits ? view.info.limits : null
          readonly property var voltLimit: limits && limits.volts ? limits.volts[modelData.key] : null
          readonly property real ocp: limits && limits.amps && limits.amps[modelData.key] ? limits.amps[modelData.key] : 0

          HoverHandler { id: cardHover }
          PanelToolTip {
            visible: cardHover.hovered
            text: modelData.label + " rail\n"
              + "Nominal " + modelData.nominal.toFixed(1) + " V, now " + Model.formatVolts(card.volts >= 0 ? card.volts : null, 3) + " (" + Model.formatSigned(isNaN(card.dev) ? null : card.dev, 2) + ")\n"
              + "ATX allows ±5%. Comfortable inside ±3%.\n"
              + "Protection trips (the supply shuts down):\n"
              + "  under-voltage " + Model.formatVolts(card.voltLimit ? card.voltLimit.min : null, 2) + "   over-voltage " + Model.formatVolts(card.voltLimit ? card.voltLimit.max : null, 2) + "\n"
              + "  over-current " + (card.ocp > 0 ? card.ocp.toFixed(0) + " A" : "–")
          }

          Column {
            id: cardCol
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(4)

            Row {
              width: parent.width
              Text {
                id: railName
                textFormat: Text.PlainText
                text: modelData.label
                color: view.dim
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Text {
                width: parent.width - railName.implicitWidth
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                text: Model.formatSigned(isNaN(card.dev) ? null : card.dev, 1)
                color: view.bandColor(card.band)
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Text {
              textFormat: Text.PlainText
              text: Model.formatVolts(card.volts >= 0 ? card.volts : null, 2)
              color: view.baseColor
              font.family: view.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            // Regulation: centre is nominal, edges are ±6%, the lighter zone is ±3%.
            Item {
              width: parent.width
              height: Style.space(10)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: view.tint(view.hotColor, 0.18)
              }
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                x: parent.width * (1 - 5 / 6) / 2
                width: parent.width * (5 / 6)
                height: Style.space(4)
                color: view.tint(view.accent, 0.22)
              }
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                x: parent.width * (1 - 3 / 6) / 2
                width: parent.width * (3 / 6)
                height: Style.space(4)
                color: view.tint(view.accent, 0.4)
              }
              Rectangle {
                visible: !isNaN(card.dev)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(3)
                height: parent.height
                radius: 1
                color: view.bandColor(card.band)
                x: parent.width * (0.5 + Math.max(-6, Math.min(6, isNaN(card.dev) ? 0 : card.dev)) / 12) - width / 2
                Behavior on x { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: Model.formatWatts(view.railPower(modelData.key) >= 0 ? view.railPower(modelData.key) : null)
                + "  ·  " + Model.formatAmps(view.railAmps(modelData.key) >= 0 ? view.railAmps(modelData.key) : null)
              color: view.baseColor
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
            }

            // How much of the over-current trip is in use.
            Rectangle {
              width: parent.width
              height: Style.space(3)
              radius: height / 2
              color: view.tint(view.baseColor, 0.12)

              Rectangle {
                height: parent.height
                radius: parent.radius
                color: view.warm(view.accent, Model.severity(Model.usePercent(view.railAmps(modelData.key), card.ocp) || 0, 60, 100))
                width: Math.max(parent.height, parent.width * (Model.usePercent(view.railAmps(modelData.key), card.ocp) || 0) / 100)
                Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
              }
            }
          }
        }
      }
    }

    // ------------------------------------------------------ thermals and fan
    Row {
      width: parent.width
      spacing: Style.space(14)
      visible: view.present

      Column {
        id: thermals
        width: parent.width - fanBlock.width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Repeater {
          model: [
            { label: "VRM", key: "vrm" },
            { label: "Case", key: "case" }
          ]

          Item {
            id: tbar
            required property var modelData
            width: parent.width
            height: Style.space(14)
            readonly property real temp: view.sample && view.sample[modelData.key] !== null && view.sample[modelData.key] !== undefined ? view.sample[modelData.key] : -1
            readonly property real sev: Model.severity(temp, view.tempLimit - 25, view.tempLimit)

            Text {
              id: tName
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(44)
              textFormat: Text.PlainText
              text: modelData.label
              color: view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              id: tVal
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(40)
              horizontalAlignment: Text.AlignRight
              textFormat: Text.PlainText
              text: Model.formatTemp(tbar.temp >= 0 ? tbar.temp : null, view.fahrenheit)
              color: view.warm(view.accent, tbar.sev)
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            Rectangle {
              anchors.left: tName.right
              anchors.right: tVal.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              height: Style.space(6)
              radius: height / 2
              color: view.tint(view.baseColor, 0.12)

              Rectangle {
                height: parent.height
                radius: parent.radius
                color: view.warm(view.accent, tbar.sev)
                width: tbar.temp > 0 ? Math.max(parent.height, parent.width * Math.min(1, tbar.temp / view.tempLimit)) : 0
                Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
              }
              // Where it starts to count as warm.
              Rectangle {
                x: parent.width * (view.tempLimit - 25) / view.tempLimit
                width: 1
                height: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                color: view.tint(view.baseColor, 0.4)
              }
            }
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: "limit " + Model.formatTemp(view.tempLimit, view.fahrenheit)
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        id: fanBlock
        spacing: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter

        // Five blades; stops when the fan does.
        Item {
          id: rotor
          width: Style.space(44)
          height: Style.space(44)
          readonly property real rpm: view.sample && view.sample.fan !== null && view.sample.fan !== undefined ? view.sample.fan : -1
          opacity: rpm > 0 ? 1 : 0.4
          Behavior on opacity { NumberAnimation { duration: 300 } }

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: view.tint(view.accent, 0.06)
            border.color: view.tint(view.accent, 0.45)
            border.width: 1
          }
          Item {
            anchors.fill: parent
            rotation: view.fanAngle

            Repeater {
              model: 5

              Rectangle {
                required property int index
                width: rotor.width * 0.2
                height: rotor.height * 0.34
                radius: width / 2
                x: rotor.width / 2 - width / 2
                y: rotor.height / 2 - height
                transformOrigin: Item.Bottom
                rotation: index * 72
                color: view.tint(view.accent, 0.6)
              }
            }
          }
          Rectangle {
            anchors.centerIn: parent
            width: rotor.width * 0.2
            height: width
            radius: width / 2
            color: view.accent
          }
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(96)

          Text {
            textFormat: Text.PlainText
            text: Model.formatFan(rotor.rpm >= 0 ? rotor.rpm : null)
            color: view.baseColor
            font.family: view.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: Model.fanNote(rotor.rpm >= 0 ? rotor.rpm : null, view.sample ? view.sample.vrm : null, view.tempLimit)
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption - 1
          }
          Text {
            textFormat: Text.PlainText
            visible: view.sample && view.sample.duty !== null && view.sample.duty !== undefined
            text: view.sample && view.sample.duty !== null && view.sample.duty !== undefined ? "duty " + Math.round(view.sample.duty) + "%" : ""
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption - 1
          }
        }
      }
    }

    // ------------------------------------------------------ power history
    Column {
      width: parent.width
      spacing: Style.space(4)
      visible: view.present

      Row {
        width: parent.width
        Text {
          id: histTitle
          textFormat: Text.PlainText
          text: "Output, last " + Math.max(1, Math.round(view.history.length / 60)) + " min"
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        Row {
          width: parent.width - histTitle.implicitWidth
          layoutDirection: Qt.RightToLeft
          spacing: Style.space(10)

          Repeater {
            model: [{ l: "+3.3V", k: "3v3", o: 0.35 }, { l: "+5V", k: "5v", o: 0.6 }, { l: "+12V", k: "12v", o: 1 }]
            Row {
              required property var modelData
              spacing: Style.space(3)
              Rectangle { width: Style.space(7); height: Style.space(7); radius: 1; anchors.verticalCenter: parent.verticalCenter; color: view.tint(view.accent, modelData.o) }
              Text {
                textFormat: Text.PlainText
                text: modelData.l
                color: view.dim
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption - 1
              }
            }
          }
        }
      }

      Item {
        id: chart
        width: parent.width
        height: Style.space(72)

        // The window grows with the data up to five minutes, so a freshly opened
        // panel fills the chart instead of leaving a sliver at the right edge.
        readonly property int cap: Math.max(10, Math.min(300, view.history.length))
        readonly property real yMax: {
          var peak = 0
          for (var i = 0; i < view.history.length; i++) peak = Math.max(peak, view.history[i].total || 0)
          return Math.max(100, Math.ceil(peak * 1.15 / 50) * 50)
        }

        // Cumulative layers: +12V at the bottom, then +5V, then +3.3V on top.
        function stack(upToIndex) {
          var keys = ["12v", "5v", "3v3"]
          var top = [], bottom = []
          var n = view.history.length
          for (var i = 0; i < n; i++) {
            var x = (i + (cap - n)) / (cap - 1) * width
            var lower = 0, upper = 0
            for (var k = 0; k <= upToIndex; k++) {
              var v = view.history[i][keys[k]] || 0
              if (k < upToIndex) lower += v
              upper += v
            }
            top.push(Qt.point(x, height - Math.min(1, upper / yMax) * height))
            bottom.push(Qt.point(x, height - Math.min(1, lower / yMax) * height))
          }
          return top.concat(bottom.reverse())
        }
        readonly property var layer12: view.history.length >= 2 ? stack(0) : []
        readonly property var layer5: view.history.length >= 2 ? stack(1) : []
        readonly property var layer3: view.history.length >= 2 ? stack(2) : []
        readonly property var totalLine: {
          var line = []
          var n = view.history.length
          for (var i = 0; i < n; i++) {
            line.push(Qt.point((i + (cap - n)) / (cap - 1) * width, height - Math.min(1, (view.history[i].total || 0) / yMax) * height))
          }
          return line
        }

        Rectangle { anchors.fill: parent; radius: Style.space(3); color: view.tint(view.baseColor, 0.04) }
        Repeater {
          model: 3
          Rectangle {
            required property int index
            width: chart.width
            height: 1
            y: chart.height * (index + 1) / 4
            color: view.tint(view.baseColor, 0.07)
          }
        }

        Shape {
          anchors.fill: parent
          layer.enabled: true
          layer.samples: 4
          visible: view.history.length >= 2

          ShapePath {
            strokeWidth: 0; strokeColor: "transparent"
            fillColor: view.tint(view.accent, 0.35)
            startX: chart.layer3.length > 0 ? chart.layer3[0].x : 0; startY: chart.layer3.length > 0 ? chart.layer3[0].y : 0
            PathPolyline { path: chart.layer3 }
          }
          ShapePath {
            strokeWidth: 0; strokeColor: "transparent"
            fillColor: view.tint(view.accent, 0.6)
            startX: chart.layer5.length > 0 ? chart.layer5[0].x : 0; startY: chart.layer5.length > 0 ? chart.layer5[0].y : 0
            PathPolyline { path: chart.layer5 }
          }
          ShapePath {
            strokeWidth: 0; strokeColor: "transparent"
            fillColor: view.tint(view.accent, 0.9)
            startX: chart.layer12.length > 0 ? chart.layer12[0].x : 0; startY: chart.layer12.length > 0 ? chart.layer12[0].y : 0
            PathPolyline { path: chart.layer12 }
          }
          ShapePath {
            strokeWidth: Style.space(1.4)
            strokeColor: view.baseColor
            fillColor: "transparent"
            joinStyle: ShapePath.RoundJoin
            startX: chart.totalLine.length > 0 ? chart.totalLine[0].x : 0; startY: chart.totalLine.length > 0 ? chart.totalLine[0].y : 0
            PathPolyline { path: chart.totalLine }
          }
        }

        Text {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.margins: Style.space(3)
          textFormat: Text.PlainText
          text: Math.round(chart.yMax) + " W"
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption - 1
        }
        Text {
          anchors.centerIn: parent
          visible: view.history.length < 2
          textFormat: Text.PlainText
          text: "collecting…"
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
