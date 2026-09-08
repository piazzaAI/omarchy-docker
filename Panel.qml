import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One row per Compose stack: state, container count, and the six actions that
// matter, with the keyboard map along the footer.
//
// Both sides of the list are needed to make it useful. The daemon knows the
// live state but only of stacks it has seen; the disk scan knows every project
// that has a compose file but nothing about what is running. The helper script
// merges them, so a repo you have never started is one keypress from being up.
Panel {
  id: root
  moduleName: "piazza.docker"
  ipcTarget: "piazza.docker"
  manageIpc: false

  // --- theme -----------------------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color cardBg: Color.popups.background
  readonly property color dim: blend(cardBg, foreground, 0.55)
  readonly property color dimmer: blend(cardBg, foreground, 0.34)
  readonly property color body: blend(cardBg, foreground, 0.86)
  readonly property color line: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.13)
  readonly property color recessed: blend(cardBg, foreground, 0.05)
  readonly property color selectedBg: blend(cardBg, foreground, 0.09)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function blend(base, over, amount) {
    return Qt.rgba(base.r + (over.r - base.r) * amount,
                   base.g + (over.g - base.g) * amount,
                   base.b + (over.b - base.b) * amount, 1)
  }

  // Themes carry no success or warning color, so state is a blend of the two
  // tokens every theme does define.
  function roleColor(role) {
    if (role === "active") return root.accent
    if (role === "mixed") return root.urgent
    if (role === "off") return root.dim
    return root.dimmer
  }

  // --- settings --------------------------------------------------------------
  readonly property string roots: String(setting("roots", "~/dev")).trim() || "~/dev"
  readonly property int refreshIntervalSec: Math.max(3, Number(setting("refreshIntervalSec", 10)) || 10)
  readonly property bool hideIdle: setting("hideIdle", false) === true
  readonly property bool showCount: setting("showCount", true) !== false

  // --- state -----------------------------------------------------------------
  property var stacks: []
  property string errorText: ""
  property bool loading: false
  property bool loadedOnce: false
  property int selectedIndex: 0
  // stack name -> action currently running against it. Rebuilt on every change:
  // a mutated object would not repaint the row.
  property var busy: ({})
  property string statusText: ""

  readonly property var rows: Model.visibleStacks(root.stacks, root.hideIdle)
  readonly property var selectedStack: rows.length > 0
    ? rows[Math.max(0, Math.min(root.selectedIndex, rows.length - 1))] : null
  readonly property int runningStacks: Model.runningCount(root.stacks)
  readonly property bool anyBusy: Object.keys(root.busy).length > 0

  readonly property string helperDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string stacksHelper: root.helperDir + "omarchy-docker-stacks"
  readonly property string actionHelper: root.helperDir + "omarchy-docker-action"

  // --- data ------------------------------------------------------------------
  function refresh() {
    if (stacksProc.running) return
    root.loading = true
    stacksProc.command = [root.stacksHelper, "--roots", root.roots]
    stacksProc.running = true
  }

  function applyStacks(payload) {
    root.loading = false
    root.loadedOnce = true
    if (!payload || payload.ok !== true) {
      root.errorText = (payload && payload.error) ? String(payload.error) : "Could not reach Docker"
      root.stacks = []
      return
    }
    root.errorText = ""
    root.stacks = payload.stacks || []
    if (root.selectedIndex >= root.rows.length) root.selectedIndex = Math.max(0, root.rows.length - 1)
  }

  function busyAction(name) {
    return root.busy[name] || ""
  }

  function setBusy(name, action) {
    var next = {}
    for (var key in root.busy) if (key !== name) next[key] = root.busy[key]
    if (action !== "") next[name] = action
    root.busy = next
  }

  // --- actions ---------------------------------------------------------------
  // Each action gets its own process so a three-minute rebuild of one stack does
  // not hold the panel hostage for the rest of them.
  function run(name, action) {
    if (!name || root.busyAction(name) !== "") return
    var proc = actionRunner.createObject(root, { stack: name, action: action })
    if (!proc) return
    root.setBusy(name, action)
    root.statusText = ""
    proc.command = [root.actionHelper, action, name, "--roots", root.roots]
    proc.running = true
  }

  function runSelected(action) {
    if (root.selectedStack) root.run(root.selectedStack.name, action)
  }

  // Enter is the obvious verb for the row: whatever it is not, make it that.
  function toggleSelected() {
    if (!root.selectedStack) return
    root.run(root.selectedStack.name, Model.isUp(root.selectedStack) ? "down" : "up")
  }

  function finishAction(name, action, payload) {
    root.setBusy(name, "")
    if (payload && payload.ok === true) {
      root.statusText = name + " · " + action + " ok"
      if (action !== "logs") root.notify(name, action + " finished")
    } else {
      var detail = (payload && payload.error) ? String(payload.error) : "failed"
      root.statusText = name + " · " + action + " failed"
      root.notify(name + " · " + action + " failed", detail)
    }
    statusResetTimer.restart()
    root.refresh()
  }

  function notify(headline, text) {
    // A rebuild outlives the panel; a click anywhere dismisses it. The
    // notification is what makes the result survive that.
    if (root.opened && text.indexOf("failed") < 0) return
    notifyProc.command = ["omarchy-notification-send", "-g", "󰡨", headline, text]
    notifyProc.running = true
  }

  function move(delta) {
    if (root.rows.length === 0) return
    var next = root.selectedIndex + delta
    if (next < 0) next = root.rows.length - 1
    else if (next >= root.rows.length) next = 0
    root.selectedIndex = next
  }

  // --- lifecycle -------------------------------------------------------------
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: root.refresh()

  onOpenedChanged: if (opened) {
    root.statusText = ""
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Open, or with something in flight, the list is worth watching. Closed and
  // idle it only feeds the bar's own count, which can lag by a minute.
  Timer {
    id: pollTimer
    running: true
    repeat: true
    interval: root.anyBusy ? 2000 : (root.opened ? root.refreshIntervalSec * 1000 : 60000)
    onTriggered: root.refresh()
  }

  Timer {
    id: statusResetTimer
    interval: 4000
    onTriggered: root.statusText = ""
  }

  Process {
    id: stacksProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(String(text || "")) } catch (e) { payload = null }
        root.applyStacks(payload)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.loading) {
        root.loading = false
        root.loadedOnce = true
        root.errorText = "Could not run omarchy-docker-stacks"
      }
    }
  }

  Process { id: notifyProc }

  Component {
    id: actionRunner
    Process {
      id: proc
      property string stack: ""
      property string action: ""
      property bool reported: false

      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var payload = null
          try { payload = JSON.parse(String(text || "")) } catch (e) { payload = null }
          if (payload) {
            proc.reported = true
            root.finishAction(proc.stack, proc.action, payload)
          }
        }
      }

      onExited: function(exitCode) {
        if (!proc.reported)
          root.finishAction(proc.stack, proc.action,
                            { ok: false, error: "could not run omarchy-docker-action" })
        Qt.callLater(function() { proc.destroy() })
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function up(stack: string): string { root.run(stack, "up"); return "ok" }
    function down(stack: string): string { root.run(stack, "down"); return "ok" }
    function rebuild(stack: string): string { root.run(stack, "rebuild"); return "ok" }
    function running(): string { return String(root.runningStacks) }
  }

  // --- small building blocks -------------------------------------------------
  component Keycap: Rectangle {
    property string label: ""
    implicitWidth: capText.implicitWidth + Style.space(11)
    implicitHeight: capText.implicitHeight + Style.space(4)
    radius: Style.space(4)
    color: "transparent"
    border.width: 1
    border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.5)

    Text {
      id: capText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.label
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component Hint: Row {
    property string cap: ""
    property string label: ""
    spacing: Style.space(6)

    Keycap { label: parent.cap; anchors.verticalCenter: parent.verticalCenter }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // --- bar icon --------------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰡨"
    active: root.errorText !== ""
    dimmed: root.runningStacks === 0
    tooltipText: root.opened ? "" : (root.errorText !== "" ? root.errorText
      : root.runningStacks + " of " + root.stacks.length + " stacks up")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }

    Text {
      visible: root.showCount && root.runningStacks > 0 && !root.bar.vertical
      // Tucked against the glyph's painted edge, not the icon slot's, so the
      // count does not float away from the whale on a wide bar.
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.horizontalCenterOffset: Math.round(button.glyphPaintedWidth / 2) + Style.space(2)
      anchors.top: parent.top
      anchors.topMargin: Style.space(2)
      textFormat: Text.PlainText
      text: String(root.runningStacks)
      color: root.roleColor(Model.summaryRole(root.stacks))
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // --- panel -----------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    padding: 0
    contentWidth: panel.fittedContentWidth(Style.space(700))
    contentHeight: panel.fittedContentHeight(Style.space(360), Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.move(dy > 0 ? 1 : -1) }
      onActivateRequested: root.toggleSelected()
      onReturnRequested: root.toggleSelected()
      onCloseRequested: root.close()
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === " ") { root.refresh(); return }
        var action = Model.actionForKey(key)
        if (action !== "") root.runSelected(action)
      }

      // ---------------------------------------------------------------- header
      Item {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: Style.space(52)

        Row {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(18)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(12)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(28)
            height: Style.space(28)
            radius: Style.space(7)
            color: root.recessed
            border.width: 1
            border.color: root.line

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: "󰡨"
              color: root.errorText !== "" ? root.urgent : root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
            }
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "Compose stacks"
              color: root.body
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }

            Text {
              textFormat: Text.PlainText
              text: root.errorText !== "" ? root.errorText
                : root.runningStacks + " of " + root.stacks.length + " up"
              color: root.errorText !== "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(18)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.statusText !== "" ? root.statusText : (root.loading ? "refreshing…" : "")
          color: root.statusText.indexOf("failed") >= 0 ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
          height: 1
          color: root.line
        }
      }

      // ------------------------------------------------------------------ list
      ListView {
        id: list
        anchors {
          top: header.bottom
          left: parent.left
          right: parent.right
          bottom: footer.top
        }
        clip: true
        model: root.rows
        currentIndex: root.selectedIndex
        highlightMoveDuration: 0
        boundsBehavior: Flickable.StopAtBounds

        delegate: Item {
          id: row
          required property var modelData
          required property int index
          width: list.width
          height: Style.space(46)

          readonly property bool selected: row.index === root.selectedIndex
          readonly property string runningAction: root.busyAction(row.modelData.name)
          readonly property bool rowBusy: row.runningAction !== ""

          Rectangle {
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            anchors.topMargin: Style.space(2)
            anchors.bottomMargin: Style.space(2)
            radius: Style.space(7)
            color: row.selected ? root.selectedBg : (hover.hovered ? root.recessed : "transparent")
          }

          HoverHandler {
            id: hover
            onHoveredChanged: if (hovered) root.selectedIndex = row.index
          }

          TapHandler {
            onTapped: {
              root.selectedIndex = row.index
              root.toggleSelected()
            }
          }

          // The name is bounded by the action lane rather than free to run
          // under it, and elides when a long project name meets a narrow bar.
          Item {
            id: info
            anchors.left: parent.left
            anchors.leftMargin: Style.space(20)
            anchors.right: actions.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            height: infoColumn.implicitHeight

            Rectangle {
              id: dot
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(8)
              height: Style.space(8)
              radius: width / 2
              color: root.roleColor(Model.stateRole(row.modelData.state))
              opacity: row.rowBusy ? 0.4 : 1

              SequentialAnimation on opacity {
                running: row.rowBusy
                loops: Animation.Infinite
                NumberAnimation { to: 1.0; duration: 550 }
                NumberAnimation { to: 0.25; duration: 550 }
              }
            }

            Column {
              id: infoColumn
              anchors.left: dot.right
              anchors.leftMargin: Style.space(11)
              anchors.right: parent.right
              spacing: Style.space(2)

              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: row.modelData.name
                color: row.selected ? root.foreground : root.body
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: row.rowBusy ? row.runningAction + "…" : Model.stateLabel(row.modelData)
                color: row.rowBusy ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // The lane is always laid out, and only its paint and input follow the
          // selection. Showing it with `visible` would hand the width back to the
          // name on every unselected row, so the text would jump on each move.
          Row {
            id: actions
            anchors.right: parent.right
            anchors.rightMargin: Style.space(18)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(5)
            opacity: row.selected && !row.rowBusy ? 1 : 0
            enabled: row.selected && !row.rowBusy

            Repeater {
              model: Model.actions()

              delegate: Rectangle {
                id: actionButton
                required property var modelData
                readonly property bool available: Model.actionEnabled(modelData, row.modelData)

                width: actionLabel.implicitWidth + Style.space(16)
                height: Style.space(24)
                radius: Style.space(6)
                enabled: actionButton.available
                color: actionHover.hovered ? root.selectedBg : root.recessed
                border.width: 1
                border.color: actionHover.hovered
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.5) : root.line
                opacity: actionButton.available ? 1 : 0.35

                HoverHandler { id: actionHover }
                TapHandler {
                  onTapped: root.run(row.modelData.name, actionButton.modelData.action)
                }

                Text {
                  id: actionLabel
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: actionButton.modelData.label
                  color: actionHover.hovered ? root.accent : root.body
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }

      // Nothing to list is a real state worth naming: an empty card with no
      // explanation reads as a broken panel.
      Text {
        anchors.centerIn: list
        width: list.width - Style.space(60)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        visible: root.loadedOnce && root.rows.length === 0 && root.errorText === ""
        textFormat: Text.PlainText
        text: "No compose files under " + root.roots
          + ". Point the widget's \"Project folders\" setting somewhere else."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      // ---------------------------------------------------------------- footer
      Item {
        id: footer
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: Style.space(42)

        Rectangle {
          anchors { top: parent.top; left: parent.left; right: parent.right }
          height: 1
          color: root.line
        }

        Row {
          anchors.centerIn: parent
          spacing: Style.space(14)

          Hint { cap: "u"; label: "up" }
          Hint { cap: "d"; label: "down" }
          Hint { cap: "r"; label: "restart" }
          Hint { cap: "b"; label: "build" }
          Hint { cap: "f"; label: "rebuild" }
          Hint { cap: "o"; label: "logs" }
        }
      }
    }
  }
}
