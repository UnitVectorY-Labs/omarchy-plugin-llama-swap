import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.unitvectory-labs.llama-swap"
  ipcTarget: "io.github.unitvectory-labs.llama-swap"
  manageIpc: false

  property Item anchorItem: null
  property Item hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string baseUrl: settings && settings.url
    ? String(settings.url).replace(/\/+$/, "") : ""
  readonly property string apiToken: settings && settings.apiToken
    ? String(settings.apiToken).trim() : ""
  readonly property bool configured: baseUrl !== ""
  readonly property bool connected: lastError === ""
  readonly property int loadedCount: loadedModels.length
  readonly property string statusText: !configured ? "Llama Swap is not configured"
    : !connected ? "Llama Swap is unavailable"
    : loadedCount > 0 ? loadedCount + " model" + (loadedCount === 1 ? " loaded" : "s loaded")
    : "No models loaded"

  property var models: []
  property var loadedModels: []
  property string lastError: ""
  property bool refreshing: false
  property string actionModel: ""
  property var inFlightRequests: []
  property bool eventConnected: false
  property double nowMs: Date.now()
  property int page: 0
  readonly property int pageSize: 5
  readonly property int pageCount: Math.max(1, Math.ceil(models.length / pageSize))
  readonly property var pageModels: models.slice(page * pageSize, Math.min(models.length, (page + 1) * pageSize))
  readonly property var visibleRequests: inFlightRequests.slice(0, 3)

  function requestCommand(path, method, maxTime) {
    var command = ["curl", "-fsS", "--connect-timeout", "4", "--max-time", String(maxTime || 10), "-X", method]
    if (apiToken !== "") command.push("-H", "Authorization: Bearer " + apiToken)
    command.push(baseUrl + path)
    return command
  }

  function refresh() {
    if (!configured || modelsProcess.running) return
    refreshing = true
    modelsProcess.command = requestCommand("/v1/models", "GET")
    modelsProcess.running = true
  }

  function parseModels(text) {
    var payload = JSON.parse(text)
    var rows = payload && payload.data instanceof Array ? payload.data : []
    var primary = []
    for (var i = 0; i < rows.length; i++) {
      var entry = rows[i]
      var kind = entry.meta && entry.meta.llamaswap ? entry.meta.llamaswap.type : "model"
      if (kind !== "alias") primary.push({
        id: String(entry.id || ""),
        name: String(entry.name || entry.id || ""),
        loaded: entry.status && entry.status.value === "loaded"
      })
    }

    // Match Llama Swap's UI ordering. State is not part of the key, so
    // load/unload can never move a row.
    primary.sort(function(a, b) {
      return (a.name + a.id).localeCompare(b.name + b.id, undefined, { numeric: true })
    })

    models = primary
    loadedModels = primary.filter(function(model) { return model.loaded })
    page = Math.min(page, Math.max(0, Math.ceil(primary.length / pageSize) - 1))
    lastError = ""
  }

  function toggleModel(model) {
    if (!configured || actionProcess.running || !model) return
    var desiredLoaded = !model.loaded
    actionModel = model.id
    setModelLoaded(model.id, desiredLoaded)
    if (!desiredLoaded)
      actionProcess.command = requestCommand("/api/models/unload/" + encodeURIComponent(model.id), "POST", 30)
    else
      actionProcess.command = requestCommand("/upstream/" + encodeURIComponent(model.id) + "/", "GET", 600)
    actionProcess.running = true
  }

  function setModelLoaded(id, loaded) {
    var next = []
    for (var i = 0; i < models.length; i++) {
      var model = models[i]
      next.push({ id: model.id, name: model.name, loaded: model.id === id ? loaded : model.loaded })
    }
    models = next
    loadedModels = next.filter(function(model) { return model.loaded })
  }

  function eventCommand() {
    var command = ["curl", "-NsS", "--connect-timeout", "4"]
    if (apiToken !== "") command.push("-H", "Authorization: Bearer " + apiToken)
    command.push(baseUrl + "/api/events")
    return command
  }

  function startEvents() {
    if (!opened || !configured || eventsProcess.running) return
    eventConnected = false
    eventsProcess.command = eventCommand()
    eventsProcess.running = true
  }

  function stopEvents() {
    eventsRestart.stop()
    eventsProcess.running = false
    eventConnected = false
    inFlightRequests = []
  }

  function handleEventLine(line) {
    if (line.indexOf("data:") !== 0) return
    try {
      var envelope = JSON.parse(line.slice(5))
      if (envelope.type !== "inflight") return
      eventConnected = true
      var update = JSON.parse(envelope.data)
      var next = inFlightRequests.slice()
      if (update.operation === "snapshot") {
        next = update.requests || []
      } else if (update.operation === "upsert" && update.request) {
        var replaced = false
        for (var i = 0; i < next.length; i++) {
          if (next[i].id === update.request.id) {
            next[i] = update.request
            replaced = true
            break
          }
        }
        if (!replaced) next.push(update.request)
      } else if (update.operation === "remove") {
        next = next.filter(function(request) { return request.id !== update.id })
      }
      next.sort(function(a, b) {
        var byTime = Date.parse(a.timestamp) - Date.parse(b.timestamp)
        return byTime || String(a.id).localeCompare(String(b.id), undefined, { numeric: true })
      })
      inFlightRequests = next
    } catch (error) {
      // Other SSE messages and incomplete lines do not affect request state.
    }
  }

  function elapsedText(request) {
    var started = Date.parse(request && request.timestamp ? request.timestamp : "")
    if (!isFinite(started)) return "running"
    var seconds = Math.max(0, Math.floor((nowMs - started) / 1000))
    if (seconds < 60) return seconds + "s"
    return Math.floor(seconds / 60) + "m " + (seconds % 60) + "s"
  }

  function changePage(delta) {
    page = Math.max(0, Math.min(pageCount - 1, page + delta))
  }

  onOpenedChanged: {
    if (opened) {
      nowMs = Date.now()
      refresh()
      startEvents()
    } else {
      stopEvents()
    }
  }
  onConfiguredChanged: {
    models = []
    loadedModels = []
    page = 0
    lastError = ""
    if (opened && configured) startEvents()
    else stopEvents()
  }

  Process {
    id: modelsProcess
    stdout: StdioCollector { id: modelsOutput; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode !== 0) {
        root.lastError = "Could not reach " + root.baseUrl
        return
      }
      try { root.parseModels(modelsOutput.text || "") }
      catch (error) { root.lastError = "Invalid response from Llama Swap" }
    }
  }

  Process {
    id: eventsProcess
    stdout: SplitParser { onRead: function(line) { root.handleEventLine(String(line)) } }
    onExited: function(exitCode) {
      if (root.opened && root.configured) eventsRestart.restart()
    }
  }

  Timer {
    id: eventsRestart
    interval: 2000
    onTriggered: root.startEvents()
  }

  Timer {
    interval: 1000
    running: root.opened && root.inFlightRequests.length > 0
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Process {
    id: actionProcess
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = "Model action failed"
      root.actionModel = ""
      refreshAfterAction.restart()
    }
  }

  Timer { id: refreshAfterAction; interval: 700; onTriggered: root.refresh() }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    // The mounted bar widget is the popout identity. It forwards lifecycle
    // calls to this nested Panel, matching Omarchy's first-party split panels.
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (dx !== 0) root.changePage(dx) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Llama Swap"
          meta: root.refreshing ? "Checking model state"
            : root.connected ? root.statusText : "Connection error"
          detail: root.models.length > 0 ? root.models.length + " models" : ""
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Item {
              width: Style.font.display
              height: Style.font.display

              Image {
                id: heroLlama
                anchors.fill: parent
                source: Qt.resolvedUrl("assets/llama-outline.svg")
                fillMode: Image.PreserveAspectFit
                visible: false
                layer.enabled: true
              }

              MultiEffect {
                anchors.fill: heroLlama
                source: heroLlama
                colorization: 1.0
                colorizationColor: root.connected ? root.foreground : root.urgent
              }
            }
          }
        }

        Text {
          visible: !root.configured || root.lastError !== ""
          width: parent.width
          text: !root.configured
            ? "Set the Llama Swap URL in this plugin's settings."
            : root.lastError
          color: root.lastError !== "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator {
          visible: root.configured
          foreground: root.foreground
        }

        PanelSectionHeader {
          visible: root.configured
          text: "ACTIVE REQUESTS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          visible: root.configured && (!root.eventConnected || root.inFlightRequests.length === 0)
          width: parent.width
          leftPadding: Style.space(10)
          text: root.eventConnected ? "No requests running" : "Connecting…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Column {
          visible: root.inFlightRequests.length > 0
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.visibleRequests

            Item {
              id: requestRow
              required property var modelData
              width: parent.width
              implicitHeight: Style.space(34)

              Text {
                anchors.left: parent.left
                anchors.right: requestMeta.left
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: String(requestRow.modelData.model || "Unknown model")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                id: requestMeta
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: root.elapsedText(requestRow.modelData) + "  ·  " + String(requestRow.modelData.req_path || "request")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            visible: root.inFlightRequests.length > root.visibleRequests.length
            width: parent.width
            text: "+" + (root.inFlightRequests.length - root.visibleRequests.length) + " more running"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
          }
        }

        PanelSeparator {
          visible: root.models.length > 0
          foreground: root.foreground
        }

        PanelSectionHeader {
          visible: root.models.length > 0
          text: "MODELS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Column {
          id: modelRows
          visible: root.models.length > 0
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.pageModels

            BorderSurface {
              id: modelRow
              required property var modelData
              width: modelRows.width
              implicitHeight: Style.space(42)
              color: "transparent"
              borderSpec: Border.none()
              radius: Style.cornerRadius

              Text {
                anchors.left: parent.left
                anchors.right: modelSwitch.left
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: modelRow.modelData.name
                color: modelRow.modelData.loaded ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              ToggleSwitch {
                id: modelSwitch
                anchors.right: parent.right
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                checked: modelRow.modelData.loaded
                busy: root.actionModel === modelRow.modelData.id
                interactive: root.actionModel === "" && root.connected
                // Keep the geometry fixed while an API action disables input.
                cursorRing: true
                foreground: root.foreground
                accent: Color.accent
                onToggled: root.toggleModel(modelRow.modelData)
              }
            }
          }
        }

        Row {
          visible: root.pageCount > 1
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(10)

          Button {
            text: "Previous"
            bordered: true
            enabled: root.page > 0
            opacity: enabled ? 1 : 0.4
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.changePage(-1)
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: (root.page + 1) + " / " + root.pageCount
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            text: "Next"
            bordered: true
            enabled: root.page < root.pageCount - 1
            opacity: enabled ? 1 : 0.4
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.changePage(1)
          }
        }

        Text {
          visible: root.configured && !root.refreshing && root.connected && root.models.length === 0
          width: parent.width
          text: "No configured models found."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }
}
