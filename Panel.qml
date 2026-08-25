import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Layout patterns (hero, stat row, sparkline, period chips, settings
// overlay) borrowed from omarchy-matomo/Panel.qml; the site picker uses a
// single-select Dropdown instead of Matomo's MultiSelect, since Umarchy
// switches between one site at a time rather than aggregating several.
Panel {
  id: root
  moduleName: "io.github.rolfkoenders.umarchy"
  ipcTarget: "io.github.rolfkoenders.umarchy"
  manageIpc: false

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(contentForeground, 1.5)
  readonly property bool vertical: bar ? bar.vertical : false

  readonly property string label: stats.barLabel
  readonly property string tooltipText: stats.barTooltip
  readonly property bool iconOnBar: !stats.ready || !stats.config.showLiveCount
  readonly property bool editingConnection: !stats.connected || setupOpen
  property bool setupOpen: false

  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight
  readonly property Item barButton: root.iconOnBar ? iconButton : textButton

  function refresh() {
    stats.refresh()
  }

  function saveSetup() {
    stats.saveConnection(hostField.text, usernameField.text, passwordField.text)
  }

  function handleSetupKey(event, onEnter) {
    if (event.key === Qt.Key_Escape) {
      if (stats.connected) root.setupOpen = false
      else root.close()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      onEnter()
      event.accepted = true
    }
  }

  component PeriodChip: BorderSurface {
    property string value
    property string chipLabel
    property string hint
    readonly property bool selected: stats.config.period === value
    readonly property bool hovered: chipMouse.containsMouse
    readonly property int borderPad: Math.max(Style.hoverBorderWidth, Style.normalBorderWidth)

    implicitWidth: chipText.implicitWidth + Style.spacing.controlPaddingX * 2 + borderPad * 2
    implicitHeight: Math.max(Style.spacing.controlHeight, chipText.implicitHeight + Style.spacing.controlPaddingY * 2 + borderPad * 2)
    radius: Style.cornerRadius
    color: hovered
      ? Style.hoverFillFor(root.contentForeground, Color.accent)
      : (selected ? Style.selectedFillFor(root.contentForeground, Color.accent) : "transparent")
    borderSpec: Border.controlSpec(hovered ? "hover-cursor" : "normal", root.contentForeground, Color.accent)

    Text {
      id: chipText
      anchors.centerIn: parent
      text: chipLabel
      color: selected ? Style.selectedStateColor(root.contentForeground, Color.accent) : root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      font.bold: selected
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: stats.setPeriod(value)
    }

    PanelToolTip {
      visible: hint !== "" && chipMouse.containsMouse
      text: hint
      fontFamily: root.contentFontFamily
    }
  }

  component StatColumn: Column {
    property string title
    property string amount
    spacing: Style.space(4)
    Text {
      text: title
      color: root.dim
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
      font.letterSpacing: 1
    }
    Text {
      text: amount
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.title
    }
  }

  component TopList: Column {
    property string title
    property var rows: []
    width: parent ? parent.width : implicitWidth
    spacing: Style.space(6)
    visible: rows.length > 0

    Text {
      text: title
      color: root.dim
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
      font.letterSpacing: 1
    }

    Repeater {
      model: rows
      delegate: Item {
        required property var modelData
        width: parent ? parent.width : implicitWidth
        height: rowName.implicitHeight

        Text {
          id: rowName
          anchors.left: parent.left
          anchors.right: rowCount.left
          anchors.rightMargin: Style.space(8)
          text: modelData.name
          color: root.contentForeground
          elide: Text.ElideMiddle
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          id: rowCount
          anchors.right: parent.right
          text: Model.formatCount(modelData.count)
          color: root.dim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  onOpenedChanged: if (opened) {
    stats.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: stats
    onConnectedChanged: if (connected) {
      root.setupOpen = false
      passwordField.text = ""
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  function handleBarPress(b) {
    if (b === Qt.MiddleButton) root.refresh()
    else if (b === Qt.RightButton && stats.config.host) omarchyOpen.openHost(stats.config.host)
    else root.toggle()
  }

  // The only URL this ever opens is the plugin's own saved, already
  // validated (https-only) host — never anything server-supplied.
  QtObject {
    id: omarchyOpen
    function openHost(host) {
      var url = Model.normalizeHost(host)
      if (!url) return
      launchProc.command = ["omarchy-launch-browser", url]
      launchProc.running = true
    }
  }
  Process { id: launchProc }

  BarIconButton {
    id: iconButton
    visible: root.iconOnBar
    anchors.fill: parent
    bar: root.bar
    text: stats.barIcon
    tooltipText: root.tooltipText
    onPressed: function(b) { root.handleBarPress(b) }
  }

  WidgetButton {
    id: textButton
    visible: !root.iconOnBar
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.label
    labelVisible: !root.vertical
    hasVisualContent: true
    tooltipText: root.tooltipText
    horizontalMargin: 8.75
    verticalPadding: 8.75
    onPressed: function(b) { root.handleBarPress(b) }

    Column {
      visible: root.vertical
      anchors.fill: parent

      OpticalGlyph {
        width: textButton.width
        height: Style.bar.iconSlot
        text: stats.barIcon
        fontFamily: textButton.fontFamily
        fontSize: textButton.fontSize
        color: textButton.foreground
      }

      OpticalGlyph {
        width: textButton.width
        height: Style.bar.iconSlot
        text: root.label
        fontFamily: textButton.fontFamily
        fontSize: textButton.fontSize
        color: textButton.foreground
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(body.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingConnection || siteDropdown.popupOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "1") stats.setPeriod("today")
        else if (t === "2") stats.setPeriod("7d")
        else if (t === "3") stats.setPeriod("30d")
        else if (t === "s" || t === "S") root.setupOpen = true
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        anchors.leftMargin: edgeInset
        anchors.rightMargin: edgeInset
        contentWidth: width
        contentHeight: body.implicitHeight
        clip: interactive
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        readonly property int edgeInset: Math.max(Style.space(4), Style.normalBorderWidth * 2)

        Column {
          id: body
          width: scroll.width
          spacing: Style.space(14)

          Column {
            visible: root.editingConnection
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: "UMAMI"
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 1
            }

            TextField {
              id: hostField
              width: parent.width
              placeholderText: "https://analytics.example.com"
              text: stats.config.host
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              Keys.onPressed: function(event) {
                root.handleSetupKey(event, function() { usernameField.forceActiveFocus() })
              }
            }

            TextField {
              id: usernameField
              width: parent.width
              placeholderText: "View-only username"
              text: stats.config.username
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              Keys.onPressed: function(event) {
                root.handleSetupKey(event, function() { passwordField.forceActiveFocus() })
              }
            }

            TextField {
              id: passwordField
              width: parent.width
              password: true
              placeholderText: stats.connected ? "Leave blank to keep the saved password" : "Password"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              Keys.onPressed: function(event) {
                root.handleSetupKey(event, root.saveSetup)
              }
            }

            Toggle {
              width: parent.width
              label: "Live count on the bar"
              description: "Show live visitors on the bar. Off uses the icon only."
              checked: stats.config.showLiveCount
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: stats.setShowLiveCount(!checked)
            }

            Text {
              visible: stats.lastError !== "" && !stats.connected
              width: parent.width
              text: stats.lastError
              color: Color.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(8)

              Button {
                text: stats.checking ? "Checking…" : "Save & Connect"
                enabled: !stats.checking
                foreground: root.contentForeground
                onClicked: root.saveSetup()
              }

              Button {
                visible: stats.connected
                text: "Cancel"
                foreground: root.contentForeground
                onClicked: root.setupOpen = false
              }
            }
          }

          Column {
            visible: !root.editingConnection
            width: parent.width
            spacing: Style.space(14)

            Item {
              width: parent.width
              height: Math.max(heroLeft.height, heroRight.height)

              Column {
                id: heroLeft
                anchors.left: parent.left
                anchors.top: parent.top
                spacing: Style.space(2)

                Text {
                  text: Model.formatCount(stats.activeVisitors)
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: 52
                  font.bold: true
                }

                Text {
                  text: "LIVE NOW"
                  color: root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }
              }

              Column {
                id: heroRight
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: Style.space(6)

                Row {
                  anchors.right: parent.right
                  spacing: Style.space(2)

                  PanelActionButton {
                    iconText: "󰑐"
                    tooltipText: "Refresh"
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    enabled: !stats.loading
                    onClicked: root.refresh()
                  }

                  PanelActionButton {
                    iconText: "󰒓"
                    tooltipText: "Settings"
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: root.setupOpen = true
                  }
                }

                Text {
                  anchors.right: parent.right
                  text: stats.loading ? "Updating…" : (stats.lastError !== "" ? stats.lastError : "")
                  color: root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            Dropdown {
              id: siteDropdown
              visible: stats.sites.length > 1
              width: parent.width
              label: "Site"
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              value: stats.config.siteId
              options: {
                var out = []
                for (var i = 0; i < stats.sites.length; i++) {
                  out.push({ value: stats.sites[i].id, label: stats.sites[i].name })
                }
                return out
              }
              onChanged: function(value) { stats.setSiteId(value) }
            }

            Row {
              width: parent.width
              spacing: Style.space(28)

              StatColumn {
                title: "PAGEVIEWS"
                amount: Model.formatCount(stats.summary.pageviews)
              }
              StatColumn {
                title: "VISITORS"
                amount: Model.formatCount(stats.summary.visitors)
              }
              StatColumn {
                title: "BOUNCE"
                amount: stats.bounceRateLabel
              }
              StatColumn {
                title: "AVG. TIME"
                amount: stats.avgTimeLabel
              }
            }

            Sparkline {
              width: parent.width
              height: Style.space(78)
              values: stats.chartValues
              labels: stats.chartLabels
              lineColor: Color.accent
              fillColor: Util.alpha(Color.accent, 0.35)
              trackColor: Util.alpha(root.contentForeground, 0.10)
              labelColor: root.dim
              fontFamily: root.contentFontFamily
            }

            Row {
              spacing: Style.spacing.md

              PeriodChip {
                value: "today"
                chipLabel: "Today"
                hint: "Today · press 1"
              }
              PeriodChip {
                value: "7d"
                chipLabel: "7d"
                hint: "Last 7 days · press 2"
              }
              PeriodChip {
                value: "30d"
                chipLabel: "30d"
                hint: "Last 30 days · press 3"
              }
            }

            TopList { title: "TOP PAGES"; rows: stats.topPages }
            TopList { title: "TOP REFERRERS"; rows: stats.topReferrers }
            TopList { title: "TOP COUNTRIES"; rows: stats.topCountries }
          }
        }
      }
    }
  }
}
