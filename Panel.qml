import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "fgonzal.keylight-air"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so popout coordination has to identify as the host widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Device state ----------------------------------------------------

  property string host: ""
  property string mdnsName: ""
  // Custom name stored on the light itself (accessory-info displayName).
  property string displayName: ""
  readonly property string deviceName: displayName || mdnsName || "Key Light Air"
  property bool reachable: false
  property bool discovering: false
  property bool lightOn: false
  property int brightness: 20          // 3..100 (%)
  property int temperature: 250        // mireds, 143..344

  readonly property string settingHost: setting("host", "")
  readonly property int pollSec: Math.max(5, setting("pollIntervalSec", 30))
  readonly property int kelvin: Model.kelvinFromMired(temperature)

  readonly property string statusText: !reachable
    ? (discovering ? "SEARCHING…" : "NOT FOUND")
    : (lightOn ? "ON · " + brightness + "% · " + kelvin + "K" : "OFF")

  // ---- Panel lifecycle (mirrors the first-party weather panel) ---------

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
    root.fetchInfo()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    root.fetchInfo()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingName) root.cancelEditingName()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Device I/O ------------------------------------------------------

  function refresh() {
    if (host) fetch()
    else discover()
  }

  function fetch() {
    if (!host || fetchProc.running) return
    fetchProc.command = ["curl", "-fsS", "--max-time", "2",
                         "http://" + host + ":9123/elgato/lights"]
    fetchProc.running = true
  }

  function discover() {
    if (settingHost) {
      host = settingHost
      fetch()
      return
    }
    if (discoverProc.running) return
    discovering = true
    discoverProc.running = true
  }

  function applyState(state) {
    if (!state) return
    reachable = true
    lightOn = state.on
    // A drag in progress owns the slider's live value; the device echo from
    // our own debounced PUT would otherwise fight the knob.
    if (!brightnessSlider.dragging) brightness = state.brightness
    if (!temperatureSlider.dragging) temperature = state.temperature
  }

  // Optimistic writes: update local state immediately, coalesce PUTs through
  // a short debounce so slider drags don't flood the lamp with requests.
  property var pending: ({})

  function queueApply(patch) {
    if (!reachable) return
    var merged = pending
    for (var key in patch) merged[key] = patch[key]
    pending = merged
    applyDebounce.restart()
  }

  function toggleLight() {
    if (!reachable) return
    lightOn = !lightOn
    queueApply({ on: lightOn })
  }

  function setBrightness(value) {
    brightness = Model.clampBrightness(value)
    queueApply({ brightness: brightness })
  }

  function setKelvin(value) {
    temperature = Model.miredFromKelvin(value)
    queueApply({ temperature: temperature })
  }

  function nudgeBrightness(delta) {
    if (!reachable) return
    setBrightness(brightness + delta)
  }

  // ---- Rename (stored on the light's flash via accessory-info) ---------

  property bool editingName: false
  property bool savingName: false
  property int wifiRssi: 0

  // Full accessory-info payload for the collapsed device-details section.
  // Session-only UI state: reopening the shell starts collapsed again.
  property var deviceInfo: null
  property bool showDetails: false

  function fetchInfo() {
    if (!host || infoProc.running) return
    infoProc.command = ["curl", "-fsS", "--max-time", "2",
                        "http://" + host + ":9123/elgato/accessory-info"]
    infoProc.running = true
  }

  function startEditingName() {
    if (!reachable) return
    editingName = true
    savingName = false
    Qt.callLater(function() {
      nameField.text = root.displayName || root.mdnsName
      nameField.selectAll()
      nameField.forceActiveFocus()
    })
  }

  function cancelEditingName() {
    editingName = false
    savingName = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitName() {
    var name = String(nameField.text || "").trim()
    if (name === root.displayName) {
      cancelEditingName()
      return
    }
    savingName = true
    // An empty name clears the stored displayName; the mDNS name returns.
    renameProc.command = ["curl", "-fsS", "--max-time", "2",
                          "-X", "PUT", "-H", "Content-Type: application/json",
                          "-d", JSON.stringify({ displayName: name }),
                          "http://" + host + ":9123/elgato/accessory-info"]
    renameProc.pendingName = name
    renameProc.running = true
  }

  Timer {
    id: applyDebounce
    interval: 120
    onTriggered: {
      if (!root.host) return
      var payload = Model.lightsPayload(root.pending)
      root.pending = {}
      applyProc.command = ["curl", "-fsS", "--max-time", "2",
                           "-X", "PUT", "-H", "Content-Type: application/json",
                           "-d", payload,
                           "http://" + root.host + ":9123/elgato/lights"]
      applyProc.running = true
    }
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = Model.parseLights(text)
        if (state) {
          root.applyState(state)
        } else {
          root.reachable = false
          // A configured host is authoritative; a discovered one may have
          // changed DHCP lease, so drop it and let the next poll rescan.
          if (!root.settingHost) root.host = ""
        }
      }
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector {
      waitForEnd: true
      // The device echoes resulting state; reconcile from it.
      onStreamFinished: root.applyState(Model.parseLights(text))
    }
  }

  Process {
    id: infoProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var info = Model.parseAccessoryInfo(text)
        if (info) {
          root.displayName = info.displayName
          root.wifiRssi = info.rssi
          root.deviceInfo = info
        }
      }
    }
  }

  Process {
    id: renameProc
    property string pendingName: ""
    // The PUT returns an empty body, so success/failure comes from curl's
    // exit code (-f maps HTTP errors to nonzero).
    onExited: function(exitCode) {
      root.savingName = false
      if (exitCode === 0) {
        root.displayName = renameProc.pendingName
        root.cancelEditingName()
        root.fetchInfo()
      }
    }
  }

  Process {
    id: discoverProc
    command: ["avahi-browse", "-rtp", "_elg._tcp"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.discovering = false
        var found = Model.parseAvahi(text)
        if (found) {
          root.host = found.address
          if (found.name) root.mdnsName = found.name
          root.fetch()
          root.fetchInfo()
        } else {
          root.reachable = false
        }
      }
    }
  }

  // Fast poll while the panel is open (external changes show up quickly),
  // slow poll otherwise (the bar icon stays truthful without network chatter).
  Timer {
    interval: root.opened ? 5000 : root.pollSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()
  onSettingHostChanged: {
    host = settingHost
    refresh()
  }

  // ---- UI --------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingName
      onReturnRequested: root.toggleLight()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        // ---- Hero: glyph, name + status, power switch ----
        Item {
          width: parent.width
          height: Math.max(heroGlyph.implicitHeight, heroLabels.implicitHeight, powerSwitch.height)

          Text {
            id: heroGlyph
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            text: root.lightOn ? "󰌵" : "󰌶"
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.displayLarge
            opacity: root.lightOn ? 1.0 : 0.55
          }

          Column {
            id: heroLabels
            anchors.left: heroGlyph.right
            anchors.leftMargin: Style.space(12)
            anchors.right: powerSwitch.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              visible: !root.editingName
              text: root.deviceName
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width

              TapHandler {
                enabled: root.reachable
                onTapped: root.startEditingName()
              }
              HoverHandler {
                enabled: root.reachable
                cursorShape: Qt.PointingHandCursor
              }
            }

            TextField {
              id: nameField
              visible: root.editingName
              width: parent.width
              enabled: !root.savingName
              placeholderText: "Light name"
              foreground: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelEditingName()
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.commitName()
                  event.accepted = true
                }
              }
            }

            Text {
              text: root.editingName
                ? (root.savingName ? "SAVING…" : "ENTER SAVES · ESC CANCELS")
                : root.statusText
              color: Qt.darker(root.barForeground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          ToggleSwitch {
            id: powerSwitch
            checked: root.lightOn
            interactive: root.reachable
            foreground: root.barForeground
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.toggleLight()
          }
        }

        PanelSeparator {
          foreground: root.barForeground
        }

        // ---- Brightness ----
        Column {
          width: parent.width
          spacing: Style.space(4)
          opacity: root.reachable ? 1.0 : 0.4

          Item {
            width: parent.width
            implicitHeight: brightnessHeader.implicitHeight

            PanelSectionHeader {
              id: brightnessHeader
              text: "BRIGHTNESS"
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: (brightnessSlider.dragging
                     ? Math.round(brightnessSlider.liveValue)
                     : root.brightness) + "%"
              color: Qt.darker(root.barForeground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSlider {
            id: brightnessSlider
            bar: root.bar
            width: parent.width
            minimum: 3
            maximum: 100
            step: 1
            integer: true
            value: root.brightness
            enabled: root.reachable
            onMoved: function(v) { root.setBrightness(v) }
          }
        }

        // ---- Color temperature ----
        Column {
          width: parent.width
          spacing: Style.space(4)
          opacity: root.reachable ? 1.0 : 0.4

          Item {
            width: parent.width
            implicitHeight: temperatureHeader.implicitHeight

            PanelSectionHeader {
              id: temperatureHeader
              text: "TEMPERATURE"
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: (temperatureSlider.dragging
                     ? Math.round(temperatureSlider.liveValue / 50) * 50
                     : root.kelvin) + "K"
              color: Qt.darker(root.barForeground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSlider {
            id: temperatureSlider
            bar: root.bar
            width: parent.width
            minimum: 2900
            maximum: 7000
            step: 50
            integer: true
            value: root.kelvin
            enabled: root.reachable
            onMoved: function(v) { root.setKelvin(v) }
          }
        }

        // ---- Offline row ----
        Item {
          width: parent.width
          implicitHeight: visible ? rescanButton.height : 0
          visible: !root.reachable

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: rescanButton.left
            text: root.discovering ? "Scanning the network…" : "No Key Light found."
            color: Qt.darker(root.barForeground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          PanelActionButton {
            id: rescanButton
            iconText: "󰑐"
            tooltipText: "Rescan"
            foreground: root.barForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            enabled: !root.discovering
            onClicked: root.discover()
          }
        }

        // ---- Device details (collapsed behind the footer) ----
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.showDetails && root.deviceInfo !== null

          PanelSeparator {
            foreground: root.barForeground
          }

          Repeater {
            model: root.deviceInfo ? [
              { label: "FIRMWARE", value: root.deviceInfo.firmware },
              { label: "SERIAL", value: root.deviceInfo.serialNumber },
              { label: "MAC", value: root.deviceInfo.macAddress },
              { label: "WI-FI", value: root.deviceInfo.ssid
                  + (root.deviceInfo.frequencyMHz
                     ? " · " + (root.deviceInfo.frequencyMHz / 1000) + "GHz" : "") }
            ] : []

            Item {
              required property var modelData
              width: parent.width
              implicitHeight: detailValue.implicitHeight

              Text {
                text: modelData.label
                color: Qt.darker(root.barForeground, 1.4)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: detailValue
                text: modelData.value || "—"
                color: Qt.darker(root.barForeground, 1.2)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }

        // ---- Footer: where the light was found; click for device details ----
        Text {
          width: parent.width
          visible: root.host !== ""
          text: root.host + (root.settingHost ? " (configured)" : " (mDNS)")
            + (root.wifiRssi !== 0
               ? "  ·  " + Model.wifiGlyph(root.wifiRssi) + " " + root.wifiRssi + "dBm"
               : "")
            + (root.deviceInfo ? "  " + (root.showDetails ? "󰅃" : "󰅀") : "")
          color: Qt.darker(root.barForeground, 1.7)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight

          TapHandler {
            enabled: root.deviceInfo !== null
            onTapped: root.showDetails = !root.showDetails
          }
          HoverHandler {
            enabled: root.deviceInfo !== null
            cursorShape: Qt.PointingHandCursor
          }
        }
      }
    }
  }
}
