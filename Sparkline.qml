import QtQuick
import qs.Commons
import qs.Ui

// Pageviews-over-time bar chart. Adapted from omarchy-matomo/Sparkline.qml —
// a generic, credential-free rendering component with no request logic, so
// it's safe to reuse close to verbatim.
Item {
  id: root

  property var values: []
  property var labels: []
  property color lineColor: Color.accent
  property color fillColor: Util.alpha(lineColor, 0.22)
  property color trackColor: Util.alpha(lineColor, 0.10)
  property string fontFamily: Style.font.family
  property color labelColor: Color.foreground
  property int hoveredIndex: -1

  readonly property var points: Array.isArray(values) ? values : []
  readonly property int count: points.length
  readonly property real peak: {
    var maximum = 1
    for (var i = 0; i < points.length; i++) {
      var n = Number(points[i])
      if (isFinite(n) && n > maximum) maximum = n
    }
    return maximum
  }
  readonly property real barSpacing: count > 16 ? 1 : 2
  readonly property real barWidth: {
    if (count <= 0 || bars.width <= 0) return 0
    return Math.max(1, (bars.width - Math.max(0, count - 1) * barSpacing) / count)
  }

  implicitHeight: Style.space(72)

  function pointLabel(index) {
    if (!root.labels || root.labels.length <= index) return ""
    return String(root.labels[index] || "")
  }

  function pointTip(index) {
    var count = Math.round(Number(root.points[index] || 0))
    var when = pointLabel(index)
    var amount = count === 1 ? "1 view" : (count + " views")
    return when !== "" ? (when + " · " + amount) : amount
  }

  function indexAt(x) {
    if (count <= 0 || barWidth <= 0) return -1
    var stride = barWidth + barSpacing
    var i = Math.floor(x / stride)
    if (i < 0) i = 0
    if (i >= count) i = count - 1
    return i
  }

  function barCenter(index) {
    return index * (barWidth + barSpacing) + barWidth / 2
  }

  function axisLabelAt(which) {
    if (!root.labels || !root.labels.length) return ""
    if (which === "start") return String(root.labels[0])
    if (which === "mid") return root.labels.length > 2 ? String(root.labels[Math.floor(root.labels.length / 2)]) : ""
    return root.labels.length > 1 ? String(root.labels[root.labels.length - 1]) : ""
  }

  Row {
    id: bars
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: axis.top
    anchors.bottomMargin: Style.space(4)
    spacing: root.barSpacing

    Repeater {
      model: root.count

      Rectangle {
        required property int index
        readonly property real value: Number(root.points[index] || 0)
        readonly property bool hovered: root.hoveredIndex === index
        width: root.barWidth
        height: bars.height
        color: hovered ? Util.alpha(root.lineColor, 0.10) : "transparent"

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Math.max(Style.space(2), parent.height * (parent.value / root.peak))
          radius: Math.min(2, width / 2)
          color: parent.hovered
            ? (parent.value > 0 ? root.lineColor : Util.alpha(root.lineColor, 0.35))
            : (parent.value > 0 ? root.fillColor : root.trackColor)
          border.width: parent.value > 0 || parent.hovered ? 1 : 0
          border.color: root.lineColor
        }
      }
    }
  }

  MouseArea {
    anchors.fill: bars
    hoverEnabled: true
    preventStealing: true
    onPositionChanged: function(mouse) { root.hoveredIndex = root.indexAt(mouse.x) }
    // MouseArea.entered carries no mouse parameter (only positionChanged/
    // clicked/pressed do) — mouseX/mouseY are the area's own properties,
    // always current, and the right way to get a position here.
    onEntered: root.hoveredIndex = root.indexAt(mouseX)
    onExited: root.hoveredIndex = -1
  }

  // Drawn inside the chart so it isn't clipped and doesn't need a Qt popup.
  BorderSurface {
    id: tip
    visible: root.hoveredIndex >= 0
    z: 10
    x: {
      var left = root.barCenter(Math.max(0, root.hoveredIndex)) - width / 2
      return Math.max(0, Math.min(root.width - width, left))
    }
    y: 0
    implicitWidth: tipLabel.implicitWidth + Style.space(12)
    implicitHeight: tipLabel.implicitHeight + Style.space(6)
    color: Color.tooltip.background
    borderSpec: Border.localOrSurfaceSpec("tooltip", "border", Color.tooltip.border, Color.tooltip.border, Style.normalBorderWidth)
    radius: Style.cornerRadius

    Text {
      id: tipLabel
      anchors.centerIn: parent
      text: root.hoveredIndex >= 0 ? root.pointTip(root.hoveredIndex) : ""
      color: Color.tooltip.text
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  Item {
    id: axis
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: axisLabel.implicitHeight

    Text {
      id: axisLabel
      anchors.left: parent.left
      text: root.axisLabelAt("start")
      color: root.labelColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      opacity: 0.7
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: root.axisLabelAt("mid") !== ""
      text: root.axisLabelAt("mid")
      color: root.labelColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      opacity: 0.7
    }

    Text {
      anchors.right: parent.right
      visible: root.axisLabelAt("end") !== ""
      text: root.axisLabelAt("end")
      color: root.labelColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      opacity: 0.7
    }
  }
}
