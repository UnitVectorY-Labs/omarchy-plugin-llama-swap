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
  property var inFlightRequests: []
  property bool eventConnected: false
  property double nowMs: Date.now()
  readonly property int maxModels: 256
  readonly property int maxRequests: 128
  readonly property var visibleRequests: inFlightRequests.slice(0, 3)
  readonly property var visibleLoadedModels: loadedModels.slice(0, 2)

  function helperPath() {
    return String(Qt.resolvedUrl("lib/llama-swap-request")).replace(/^file:\/\//, "")
  }

  function requestCommand(path, method, maxTime) {
    return [helperPath(), "request", method, baseUrl + path, String(maxTime || 10)]
  }

  function writeToken(process) {
    // The helper consumes exactly one line. Credentials never enter argv.
    process.write(apiToken + "\n")
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
    for (var i = 0; i < rows.length && primary.length < maxModels; i++) {
      var entry = rows[i]
      var kind = entry.meta && entry.meta.llamaswap ? entry.meta.llamaswap.type : "model"
      var id = String(entry.id || "")
      if (kind !== "alias" && id.length > 0 && id.length <= 512) {
        var loaded = entry.status && entry.status.value === "loaded"
        for (var pendingIndex = 0; pendingIndex < pendingActions.count; pendingIndex++) {
          var pending = pendingActions.get(pendingIndex)
          if (pending.modelId === id) {
            loaded = pending.desiredLoaded
            break
          }
        }
        primary.push({
          id: id,
          name: String(entry.name || entry.id || "").slice(0, 512),
          loaded: loaded
        })
      }
    }

    // Match Llama Swap's UI ordering. State is not part of the key, so
    // load/unload can never move a row.
    primary.sort(function(a, b) {
      return (a.name + a.id).localeCompare(b.name + b.id, undefined, { numeric: true })
    })

    models = primary
    syncModelRows(primary)
    loadedModels = primary.filter(function(model) { return model.loaded })
    lastError = ""
  }

  function syncModelRows(next) {
    var stable = modelList.count === next.length
    if (stable) {
      for (var i = 0; i < next.length; i++) {
        if (modelList.get(i).modelId !== next[i].id) {
          stable = false
          break
        }
      }
    }

    if (!stable) {
      modelList.clear()
      for (var appendIndex = 0; appendIndex < next.length; appendIndex++) {
        modelList.append({
          modelId: next[appendIndex].id,
          modelName: next[appendIndex].name,
          loaded: next[appendIndex].loaded
        })
      }
      return
    }

    // Updating roles in place preserves ListView identity and contentY. A
    // JavaScript-array replacement makes Qt rebuild the model and jump to top.
    for (var updateIndex = 0; updateIndex < next.length; updateIndex++) {
      var current = modelList.get(updateIndex)
      if (current.modelName !== next[updateIndex].name)
        modelList.setProperty(updateIndex, "modelName", next[updateIndex].name)
      if (current.loaded !== next[updateIndex].loaded)
        modelList.setProperty(updateIndex, "loaded", next[updateIndex].loaded)
    }
  }

  function toggleModel(model) {
    if (!configured || !connected || !model || isModelPending(model.id)) return
    var desiredLoaded = !model.loaded
    setModelLoaded(model.id, desiredLoaded)
    pendingActions.append({ modelId: model.id, desiredLoaded: desiredLoaded })
  }

  function isModelPending(id) {
    for (var i = 0; i < pendingActions.count; i++)
      if (pendingActions.get(i).modelId === id) return true
    return false
  }

  function finishAction(id, exitCode) {
    for (var i = pendingActions.count - 1; i >= 0; i--) {
      if (pendingActions.get(i).modelId === id) pendingActions.remove(i)
    }
    if (exitCode !== 0) lastError = "Model action failed"
    refreshAfterAction.restart()
  }

  function setModelLoaded(id, loaded) {
    var next = []
    for (var i = 0; i < models.length; i++) {
      var model = models[i]
      next.push({ id: model.id, name: model.name, loaded: model.id === id ? loaded : model.loaded })
    }
    models = next
    syncModelRows(next)
    loadedModels = next.filter(function(model) { return model.loaded })
  }

  function eventCommand() {
    return [helperPath(), "events", "GET", baseUrl + "/api/events", "0"]
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
        next = []
        var requests = update.requests instanceof Array ? update.requests : []
        for (var snapshotIndex = 0; snapshotIndex < requests.length && next.length < maxRequests; snapshotIndex++) {
          var snapshotRequest = boundedRequest(requests[snapshotIndex])
          if (snapshotRequest) next.push(snapshotRequest)
        }
      } else if (update.operation === "upsert" && update.request) {
        var bounded = boundedRequest(update.request)
        if (!bounded) return
        var replaced = false
        for (var i = 0; i < next.length; i++) {
          if (next[i].id === bounded.id) {
            next[i] = bounded
            replaced = true
            break
          }
        }
        if (!replaced && next.length < maxRequests) next.push(bounded)
      } else if (update.operation === "remove") {
        var removedId = String(update.id || "").slice(0, 256)
        next = next.filter(function(request) { return request.id !== removedId })
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

  function boundedRequest(request) {
    if (!request) return null
    var id = String(request.id || "")
    if (id.length === 0 || id.length > 256) return null
    return {
      id: id,
      timestamp: String(request.timestamp || "").slice(0, 128),
      model: String(request.model || "Unknown model").slice(0, 512),
      req_path: String(request.req_path || "request").slice(0, 1024)
    }
  }

  function elapsedText(request) {
    var started = Date.parse(request && request.timestamp ? request.timestamp : "")
    if (!isFinite(started)) return "running"
    var seconds = Math.max(0, Math.floor((nowMs - started) / 1000))
    if (seconds < 60) return seconds + "s"
    return Math.floor(seconds / 60) + "m " + (seconds % 60) + "s"
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
    modelList.clear()
    loadedModels = []
    pendingActions.clear()
    lastError = ""
    if (opened && configured) startEvents()
    else stopEvents()
  }

  Process {
    id: modelsProcess
    stdinEnabled: true
    stdout: StdioCollector { id: modelsOutput; waitForEnd: true }
    onStarted: root.writeToken(modelsProcess)
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
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleEventLine(String(line)) } }
    onStarted: root.writeToken(eventsProcess)
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

  ListModel { id: modelList }
  ListModel { id: pendingActions }

  Instantiator {
    model: pendingActions

    delegate: Process {
      id: actionProcess
      required property string modelId
      required property bool desiredLoaded
      stdinEnabled: true
      command: desiredLoaded
        ? root.requestCommand("/upstream/" + encodeURIComponent(modelId) + "/", "GET", 600)
        : root.requestCommand("/api/models/unload/" + encodeURIComponent(modelId), "POST", 30)
      running: true
      onStarted: root.writeToken(actionProcess)
      onExited: function(exitCode) {
        var completedId = modelId
        Qt.callLater(function() { root.finishAction(completedId, exitCode) })
      }
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

        Row {
          id: loadedPills
          readonly property int pillHeight: Style.font.caption + Style.space(6)
          visible: root.configured
          width: parent.width
          height: visible ? pillHeight : 0
          spacing: Style.space(6)

          Rectangle {
            visible: root.loadedCount === 0
            width: noModelsLabel.implicitWidth + Style.space(14)
            height: loadedPills.pillHeight
            radius: height / 2
            color: "transparent"
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
            border.width: 1

            Text {
              id: noModelsLabel
              anchors.centerIn: parent
              text: "None loaded"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Repeater {
            model: root.visibleLoadedModels

            Rectangle {
              id: modelPill
              required property var modelData
              width: Math.min(Style.space(150), pillLabel.implicitWidth + Style.space(14))
              height: loadedPills.pillHeight
              radius: height / 2
              color: Style.normalFillFor(root.foreground, Color.accent)
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.28)
              border.width: 1

              Text {
                id: pillLabel
                anchors.fill: parent
                anchors.leftMargin: Style.space(7)
                anchors.rightMargin: Style.space(7)
                text: modelPill.modelData.name
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
              }
            }
          }

          Rectangle {
            visible: root.loadedCount > root.visibleLoadedModels.length
            width: overflowLabel.implicitWidth + Style.space(14)
            height: loadedPills.pillHeight
            radius: height / 2
            color: "transparent"
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
            border.width: 1

            Text {
              id: overflowLabel
              anchors.centerIn: parent
              text: "+" + (root.loadedCount - root.visibleLoadedModels.length)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
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
          text: "No active requests"
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
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
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

        ListView {
          id: modelRows
          visible: root.models.length > 0
          width: parent.width
          height: Math.min(contentHeight, Style.space(300))
          spacing: Style.space(2)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          model: modelList

          delegate: BorderSurface {
            id: modelRow
            required property string modelId
            required property string modelName
            required property bool loaded
            width: ListView.view.width
            height: Style.space(32)
            color: "transparent"
            borderSpec: Border.none()
            radius: Style.cornerRadius

            Text {
              anchors.left: parent.left
              anchors.right: modelSwitch.left
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: modelRow.modelName
              textFormat: Text.PlainText
              color: modelRow.loaded ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            ToggleSwitch {
              id: modelSwitch
              anchors.right: parent.right
              anchors.rightMargin: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              checked: modelRow.loaded
              busy: root.isModelPending(modelRow.modelId)
              interactive: root.connected && !busy
              cursorRing: true
              cursorPad: Style.space(2)
              trackHeight: Style.space(22)
              foreground: root.foreground
              accent: Color.accent
              onToggled: root.toggleModel({
                id: modelRow.modelId,
                name: modelRow.modelName,
                loaded: modelRow.loaded
              })
            }
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
