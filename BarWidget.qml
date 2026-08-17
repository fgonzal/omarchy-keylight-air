import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "fgonzal.keylight-air"

  readonly property var panelItem: panelLoader.item

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelItem && panelItem.toggle) panelItem.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing: the bar identifies
  // a panel by open/close/opened on the bar-widget root.
  readonly property bool opened: panelItem ? panelItem.opened === true : false

  function open() {
    if (panelItem && panelItem.openFromHotkey) panelItem.openFromHotkey()
  }

  function close() {
    if (panelItem && panelItem.close) panelItem.close()
  }

  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelItem) panelItem.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    text: root.panelItem && root.panelItem.lightOn ? "󰌵" : "󰌶"
    dimmed: !(root.panelItem && root.panelItem.reachable)
    tooltipText: root.panelItem
      ? "Key Light Air: " + root.panelItem.statusText.toLowerCase()
      : "Key Light Air"

    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
      else if (root.panelItem) root.panelItem.toggleLight()
    }

    // Scroll on the icon adjusts brightness without opening anything.
    onWheelMoved: function(delta) {
      if (root.panelItem) root.panelItem.nudgeBrightness(delta > 0 ? 5 : -5)
    }
  }
}
