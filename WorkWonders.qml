import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "WorkWondersModel.js" as WorkWondersModel

// Work Wonders: which workspace every screen is showing, from one bar.
//
// One group per monitor (see "order" below). With more than
// one monitor each group gets a square border, and the focused monitor's border takes
// the theme accent. The group for the screen this bar is on gets a second,
// inner line, like the Omarchy logo, so with a bar on every screen each bar
// shows which group is "here". The workspace each monitor is showing is drawn inverted.
// Empty workspaces are dimmed. Click a number to go there.
//
// Settings (on this widget's entry in ~/.config/omarchy/shell.json):
//   "screens": "all" (default) shows every monitor; "own" shows only the
//              monitor this bar is on, for setups with a bar on every screen.
//   "alwaysShow": how many numbered workspaces to show even when they don't
//              exist yet. Default: 5 without workspace rules, 0 with them.
//   "specials": special workspaces (scratchpad, drop-down terminal...):
//              "open" (default) slides one in while it is open, on the screen
//              showing it; "always" keeps it listed; "hide" never shows them.
//   "order":   "auto" (default): side-by-side screens left to right; stacked
//              screens laptop first, then reading order. "layout": reading
//              order only. Or a list of output names / "desc:" prefixes to put
//              first, e.g. ["eDP-1", "desc:Dell"]; unlisted screens follow.
//   "specialLabels": letters for special workspaces, e.g.
//              {"scratchpad": "S", "terminal": "Q"}. Default: first letter.
BarWidget {
  id: root
  moduleName: "jamesforan.workwonders"

  property var groups: []

  readonly property var screen: QsWindow.window ? QsWindow.window.screen : null
  // The screen this bar is on (a test can set it).
  property string ownMonitor: screen ? String(screen.name || "") : ""
  readonly property var shownGroups: WorkWondersModel.forScreen(root.groups, root.setting("screens", "all"), root.ownMonitor)
  readonly property bool bordered: shownGroups.length > 1

  // True for the group of the screen this bar is on, which gets the inner line.
  function isOwn(monitor) {
    return root.bordered && root.ownMonitor !== "" && monitor === root.ownMonitor
  }

  readonly property color fg: root.bar ? root.bar.barForeground : Color.foreground
  readonly property color inverseText: Color.background
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  // Square cells sized so the filled one is exactly the Omarchy logo: the logo
  // is the omarchy font glyph at body size, and the fill sits 1px inside.
  readonly property real cellSize: Style.font.body + 2
  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  // Workspace and monitor names go into a Lua dispatch, so quote them as Lua
  // strings: a name with a quote or backslash can't break out of it.
  function luaString(value) {
    return "\"" + String(value).replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, "\\n") + "\""
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = " + luaString(id) + " })"))
  }

  function toggleSpecial(name, monitor) {
    if (!root.bar) return
    // toggle_special acts on the focused monitor, so focus this group's first.
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ monitor = " + luaString(monitor) + " })")
      + " && hyprctl dispatch " + Util.shellQuote("hl.dsp.workspace.toggle_special(" + luaString(name) + ")"))
  }

  // Special workspaces that just opened, so only that moment animates and a
  // routine refresh (a window opening) doesn't replay the slide-in. Ones that
  // just closed stay as a "leaving" cell long enough to slide back out.
  property var openSpecials: ({})
  property var justOpened: ({})
  // name -> { monitor, cell, since }: specials sliding out. Kept across the
  // burst of refreshes a close triggers, so the slide-out isn't cut short.
  property var leavingSpecials: ({})
  readonly property int leaveMs: 200
  // name -> since: specials sliding in, kept across refreshes like the above.
  property var openingSpecials: ({})
  readonly property int enterMs: 180
  property var settledGroups: []

  function refresh() {
    if (queryProc.running) {
      root.refreshPending = true
      return
    }
    root.refreshPending = false
    queryProc.running = true
  }

  property bool refreshPending: false

  Process {
    id: queryProc
    command: ["sh", "-c", "printf '{\"monitors\":%s,\"workspaces\":%s,\"rules\":%s}' \"$(hyprctl -j monitors)\" \"$(hyprctl -j workspaces)\" \"$(hyprctl -j workspacerules)\""]
    onRunningChanged: if (!running && root.refreshPending) root.refresh()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        let data
        try {
          data = JSON.parse(text || "")
        } catch (e) {
          return
        }
        const groups = WorkWondersModel.layout(data, {
          vertical: root.vertical,
          alwaysShow: root.setting("alwaysShow", null),
          order: root.setting("order", "auto"),
          specials: root.setting("specials", "open"),
          specialLabels: root.setting("specialLabels", {})
        })
        const open = {}
        const fresh = {}
        const listed = {}
        groups.forEach(function(g) {
          g.workspaces.forEach(function(w) {
            if (!w.special) return
            listed[w.name] = true
            if (!w.shown) return
            open[w.name] = { monitor: g.monitor, cell: w }
          })
        })
        const now = Date.now()
        // Which monitors had a special open before this read.
        const hadOpen = {}
        for (const name in root.openSpecials) hadOpen[root.openSpecials[name].monitor] = name
        const hasOpen = {}
        for (const name in open) hasOpen[open[name].monitor] = name
        // Slide in only onto a screen that had no special open; one special
        // replacing another on the same screen just takes its place.
        for (const name in open) {
          if (root.openingSpecials[name] !== undefined && now - root.openingSpecials[name] < root.enterMs) fresh[name] = root.openingSpecials[name]
          else if (!root.openSpecials[name] && !hadOpen[open[name].monitor]) fresh[name] = now
        }
        // Closed since the last read and no longer listed at all: keep a
        // leaving copy where it was until the slide-out finishes.
        const leavingNow = {}
        for (const name in root.leavingSpecials) {
          const l = root.leavingSpecials[name]
          if (!open[name] && !listed[name] && now - l.since < root.leaveMs) leavingNow[name] = l
        }
        for (const name in root.openSpecials) {
          if (open[name] || listed[name] || leavingNow[name]) continue
          // Replaced by another special on the same screen: no slide-out.
          if (hasOpen[root.openSpecials[name].monitor]) continue
          leavingNow[name] = Object.assign({}, root.openSpecials[name], { since: now })
        }
        const shown = groups.map(function(g) {
          const cells = g.workspaces.slice()
          for (const name in leavingNow) {
            const l = leavingNow[name]
            if (l.monitor === g.monitor) cells.push(Object.assign({}, l.cell, { leaving: true, leaveSince: l.since }))
          }
          return Object.assign({}, g, { workspaces: cells })
        })
        root.justOpened = fresh
        root.openingSpecials = fresh
        root.openSpecials = open
        root.leavingSpecials = leavingNow
        root.settledGroups = groups
        root.groups = shown
        if (Object.keys(leavingNow).length) leaveTimer.restart()
      }
    }
  }

  // Re-read after anything that can change which workspace sits where. Monitor
  // changes get a second, later read because config hooks often rewrite
  // workspace rules a moment after a monitor appears.
  Timer {
    id: soonTimer
    interval: 50
    onTriggered: root.refresh()
  }

  // Drop leaving cells once their slide-out has played.
  Timer {
    id: leaveTimer
    interval: root.leaveMs + 20
    onTriggered: {
      root.leavingSpecials = ({})
      root.groups = root.settledGroups
    }
  }

  Timer {
    id: laterTimer
    interval: 1500
    onTriggered: root.refresh()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      const name = String(event.name)
      if (/^(workspace|focusedmon|moveworkspace|createworkspace|destroyworkspace|renameworkspace|activespecial|openwindow|closewindow|movewindow)/.test(name))
        soonTimer.restart()
      if (/^(monitoradded|monitorremoved|configreloaded)/.test(name)) {
        soonTimer.restart()
        laterTimer.restart()
      }
    }
  }

  Component.onCompleted: root.refresh()
  // Settings changed in shell.json: lay out again now, not at the next event.
  onSettingsChanged: root.refresh()
  onVerticalChanged: root.refresh()

  implicitWidth: groupGrid.implicitWidth + trailingGap
  // Full bar height so the shorter groups centre on the bar (and the logo).
  implicitHeight: root.vertical ? groupGrid.implicitHeight : Math.max(groupGrid.implicitHeight, root.barSize)

  GridLayout {
    id: groupGrid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : Math.max(1, root.shownGroups.length)
    columnSpacing: Style.space(6)
    rowSpacing: Style.space(6)

    Repeater {
      model: root.shownGroups

      Rectangle {
        id: group
        required property var modelData
        readonly property bool own: root.isOwn(modelData.monitor)

        visible: modelData.workspaces.length > 0
        Layout.alignment: Qt.AlignVCenter
        // Same size with or without the inner line, so groups don't shift
        // between bars.
        implicitWidth: cells.implicitWidth + (root.bordered ? 6 : 0)
        implicitHeight: cells.implicitHeight + (root.bordered ? 6 : 0)
        color: "transparent"
        radius: 0
        border.width: root.bordered ? 1 : 0
        border.color: modelData.focused ? Color.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35)

        // This bar's own screen: an inner line 1px inside the border.
        Rectangle {
          objectName: "ownFrame"
          anchors.fill: parent
          anchors.margins: 2
          visible: group.own
          color: "transparent"
          radius: 0
          border.width: 1
          border.color: group.border.color
        }

        GridLayout {
          id: cells
          anchors.centerIn: parent
          columns: root.vertical ? 1 : Math.max(1, group.modelData.workspaces.length)
          columnSpacing: 1
          rowSpacing: 1

          Repeater {
            model: group.modelData.workspaces

            Item {
              id: cell
              required property var modelData

              readonly property bool slideIn: modelData.special && modelData.shown && !modelData.leaving && root.justOpened[modelData.name] !== undefined
              readonly property bool slideOut: !!modelData.leaving
              // A rebuild mid slide recreates this cell; carry on from where
              // the old one was instead of starting over.
              readonly property real enterFrom: slideIn ? Math.min(1, (Date.now() - root.justOpened[modelData.name]) / root.enterMs) : 1
              readonly property real leaveFrom: slideOut ? Math.max(0, 1 - (Date.now() - modelData.leaveSince) / root.leaveMs) : 1
              property real reveal: slideIn ? enterFrom : leaveFrom

              implicitWidth: root.vertical ? root.cellSize : root.cellSize * reveal
              implicitHeight: root.vertical ? root.cellSize * reveal : root.cellSize
              clip: true
              opacity: reveal

              NumberAnimation on reveal {
                running: cell.slideIn && cell.enterFrom < 1
                from: cell.enterFrom
                to: 1
                duration: Math.max(1, root.enterMs * (1 - cell.enterFrom))
                easing.type: Easing.OutCubic
              }

              NumberAnimation on reveal {
                running: cell.slideOut
                from: cell.leaveFrom
                to: 0
                duration: Math.max(1, root.leaveMs * cell.leaveFrom)
                easing.type: Easing.OutCubic
              }

              // Inset 1px so the filled block keeps a gap from the screen border.
              Rectangle {
                anchors.fill: parent
                anchors.margins: 1
                radius: 0
                color: cell.modelData.shown ? root.fg : "transparent"
                // The workspace under an open special keeps an outline.
                border.width: cell.modelData.under ? 1 : 0
                border.color: root.fg
              }

              Text {
                anchors.centerIn: parent
                text: cell.modelData.label
                textFormat: Text.PlainText
                color: cell.modelData.shown ? root.inverseText : root.fg
                opacity: cell.modelData.shown || cell.modelData.occupied ? 1 : 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: cell.modelData.shown
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: cell.modelData.special
                  ? root.toggleSpecial(cell.modelData.name, group.modelData.monitor)
                  : root.focusWorkspace(cell.modelData.id)
              }
            }
          }
        }
      }
    }
  }
}
