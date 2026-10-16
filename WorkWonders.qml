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
// One group per monitor, ordered as the monitors are laid out. With more than
// one monitor each group gets a square border, and the focused monitor's border takes
// the theme accent. The workspace each monitor is showing is drawn inverted.
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
//   "specialLabels": letters for special workspaces, e.g.
//              {"scratchpad": "S", "terminal": "Q"}. Default: first letter.
BarWidget {
  id: root
  moduleName: "jamesforan.workwonders"

  property var groups: []

  readonly property var screen: QsWindow.window ? QsWindow.window.screen : null
  readonly property string ownMonitor: screen ? String(screen.name || "") : ""
  readonly property var shownGroups: WorkWondersModel.forScreen(root.groups, root.setting("screens", "all"), root.ownMonitor)
  readonly property bool bordered: shownGroups.length > 1

  readonly property color fg: root.bar ? root.bar.barForeground : Color.foreground
  readonly property color inverseText: Color.background
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  // Square cells sized so the filled one is exactly the Omarchy logo: the logo
  // is the omarchy font glyph at body size, and the fill sits 1px inside.
  readonly property real cellSize: Style.font.body + 2
  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  function toggleSpecial(name, monitor) {
    if (!root.bar) return
    // toggle_special acts on the focused monitor, so focus this group's first.
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ monitor = \"" + monitor + "\" })")
      + " && hyprctl dispatch " + Util.shellQuote("hl.dsp.workspace.toggle_special(\"" + name + "\")"))
  }

  // Special workspaces that just opened, so only that moment animates and a
  // routine refresh (a window opening) doesn't replay the slide-in.
  property var openSpecials: ({})
  property var justOpened: ({})

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
          specials: root.setting("specials", "open"),
          specialLabels: root.setting("specialLabels", {})
        })
        const open = {}
        const fresh = {}
        groups.forEach(function(g) {
          g.workspaces.forEach(function(w) {
            if (!w.special || !w.shown) return
            open[w.name] = true
            if (!root.openSpecials[w.name]) fresh[w.name] = true
          })
        })
        root.justOpened = fresh
        root.openSpecials = open
        root.groups = groups
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

        visible: modelData.workspaces.length > 0
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: cells.implicitWidth + (root.bordered ? 4 : 0)
        implicitHeight: cells.implicitHeight + (root.bordered ? 4 : 0)
        color: "transparent"
        radius: 0
        border.width: root.bordered ? 1 : 0
        border.color: modelData.focused ? Color.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35)

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

              readonly property bool slideIn: modelData.special && modelData.shown && !!root.justOpened[modelData.name]
              property real reveal: slideIn ? 0 : 1

              implicitWidth: root.vertical ? root.cellSize : root.cellSize * reveal
              implicitHeight: root.vertical ? root.cellSize * reveal : root.cellSize
              clip: true
              opacity: reveal

              NumberAnimation on reveal {
                running: cell.slideIn
                from: 0
                to: 1
                duration: 180
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
