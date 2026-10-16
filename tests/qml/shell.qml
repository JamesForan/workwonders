// Test harness: a stand-in for the Omarchy shell that loads WorkWonders.qml
// the way the bar does, against one fixture (see tests/qml/run).
//
// It creates the widget with a stub bar (no window, nothing on screen), waits for the widget's own
// hyprctl query (answered by a stub from the fixture), checks the groups it
// built, then clicks a workspace and a special workspace through the widget's
// own functions. Results are printed as RESULT/EXPECT-DISPATCH lines for
// tests/qml/run to check; any QML warning from the plugin fails the run.
import QtQuick
import Quickshell

ShellRoot {
  id: harness

  readonly property var expected: JSON.parse(Quickshell.env("EXPECTED_JSON") || "[]")
  readonly property var settings: JSON.parse(Quickshell.env("SETTINGS_JSON") || "{}")
  property var widget: null
  property bool done: false

  function fail(message) {
    console.error("RESULT FAIL " + message)
    harness.finish()
  }

  function finish() {
    harness.done = true
    quitTimer.start()
  }

  // Only what WorkWonders reads from the real bar: colours, font, and run().
  // run() executes the command like the bar does, so the hyprctl stub sees
  // exactly what a click would send.
  QtObject {
    id: stubBar
    property bool vertical: false
    property int barSize: 30
    property color barForeground: "#ffffff"
    property string fontFamily: "monospace"
    function run(command) {
      Quickshell.execDetached(["sh", "-c", command])
    }
  }

  Component.onCompleted: {
    const component = Qt.createComponent(Quickshell.env("PLUGIN_ENTRY"), Component.PreferSynchronous)
    if (component.status !== Component.Ready) {
      harness.fail("load: " + component.errorString())
      return
    }
    harness.widget = component.createObject(null, { bar: stubBar, moduleName: "jamesforan.workwonders", settings: harness.settings })
    if (!harness.widget) harness.fail("createObject returned null")
  }

  function summary(groups) {
    return JSON.stringify(groups.map(function(g) {
      return { monitor: g.monitor, workspaces: g.workspaces.map(function(w) { return w.label }) }
    }))
  }

  // Poll until the widget has read the fixture, then compare and click.
  Timer {
    interval: 50
    repeat: true
    running: harness.widget !== null && !harness.done
    property int ticks: 0
    onTriggered: {
      ticks++
      const groups = harness.widget.groups || []
      if (groups.length === 0 && harness.expected.length > 0) {
        if (ticks > 100) harness.fail("widget never built its groups")
        return
      }
      // Specials that are open slide in over ~180ms; let that settle.
      if (ticks < 8) return
      const got = harness.summary(harness.widget.groups)
      const want = harness.summary(harness.expected)
      if (got !== want) {
        harness.fail("groups\n  got:  " + got + "\n  want: " + want)
        return
      }
      const first = harness.expected[0]
      const numbered = first ? first.workspaces.filter(function(w) { return !w.special }) : []
      if (numbered.length > 0) {
        harness.widget.focusWorkspace(numbered[0].id)
        console.info("EXPECT-DISPATCH hl.dsp.focus({ workspace = \"" + numbered[0].id + "\" })")
      }
      if (first) {
        // A name with a quote and a backslash must reach Hyprland intact.
        harness.widget.toggleSpecial("odd\"name\\x", first.monitor)
        console.info("EXPECT-DISPATCH hl.dsp.focus({ monitor = \"" + first.monitor + "\" })")
        console.info("EXPECT-DISPATCH hl.dsp.workspace.toggle_special(\"odd\\\"name\\\\x\")")
      }
      console.info("RESULT OK " + got)
      harness.finish()
    }
  }

  // Give the clicks' commands time to run, then exit.
  Timer {
    id: quitTimer
    interval: 400
    onTriggered: Qt.quit()
  }
}
