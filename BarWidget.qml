import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.unitvectory-labs.llama-swap"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool modelLoaded: panelLoader.item ? panelLoader.item.loadedCount > 0 : false
  readonly property bool available: panelLoader.item ? panelLoader.item.connected : true

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

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
    tooltipText: panelLoader.item ? panelLoader.item.statusText : "Llama Swap"

    iconComponent: Component {
      Item {
        Image {
          id: llamaIcon
          anchors.fill: parent
          source: Qt.resolvedUrl("assets/llama-outline.svg")
          fillMode: Image.PreserveAspectFit
          visible: false
          layer.enabled: true
        }

        MultiEffect {
          anchors.fill: llamaIcon
          source: llamaIcon
          colorization: 1.0
          colorizationColor: !root.available
            ? Qt.darker(root.bar.barForeground, 1.5)
            : root.bar.barForeground
        }
      }
    }

    onPressed: root.toggle()
  }
}
