// Layout logic for the Bearings bar widget, kept Qt-free so tests/run can check
// it under node against recorded hyprctl output.
//
// Input is what hyprctl prints: { monitors, workspaces, rules } from
// `hyprctl -j monitors`, `hyprctl -j workspaces` and `hyprctl -j workspacerules`.
// Output is one group per monitor, left to right (top to bottom for a vertical
// bar), each listing the workspaces that belong to it:
//
//   [{ monitor: "DP-1", focused: false,
//      workspaces: [{ id: 2, label: "2", shown: true, occupied: true }, ...] }]
//
// A workspace belongs to the monitor it is on right now. One that doesn't
// exist yet belongs to the monitor its workspace rule names, so empty slots
// stay clickable where they will open. Without any numbered workspace rules,
// workspaces 1 to `alwaysShow` (default 5, like Omarchy's own widget) are shown
// on the focused monitor, which is where Hyprland would create them.

function numericId(value) {
  var text = String(value === undefined || value === null ? "" : value).trim()
  return /^[0-9]+$/.test(text) ? parseInt(text, 10) : 0
}

// Logical size: pixels divided by scale, swapped for 90/270 degree transforms.
function logicalSize(m) {
  var scale = m.scale > 0 ? m.scale : 1
  var w = (m.width || 0) / scale, h = (m.height || 0) / scale
  return (m.transform || 0) % 2 === 1 ? { w: h, h: w } : { w: w, h: h }
}

// Reading order. For a horizontal bar, monitors whose vertical extents overlap
// form a row; rows go top to bottom and each row left to right. So a laptop
// under a monitor comes after it, and a laptop beside a taller monitor stays in
// its row. A vertical bar does the same with columns.
function sortedMonitors(monitors, vertical) {
  var list = (monitors || []).filter(function(m) { return m && !m.disabled })
  var across = vertical ? "y" : "x"
  var down = vertical ? "x" : "y"
  var extent = function(m) { return vertical ? logicalSize(m).w : logicalSize(m).h }

  list.sort(function(a, b) { return ((a[down] || 0) - (b[down] || 0)) || ((a[across] || 0) - (b[across] || 0)) })

  var bands = []
  list.forEach(function(m) {
    var start = m[down] || 0
    var band = bands[bands.length - 1]
    if (band && start < band.end) {
      band.items.push(m)
      band.end = Math.max(band.end, start + extent(m))
    } else {
      bands.push({ end: start + extent(m), items: [m] })
    }
  })

  var ordered = []
  bands.forEach(function(band) {
    band.items.sort(function(a, b) { return (a[across] || 0) - (b[across] || 0) })
    ordered = ordered.concat(band.items)
  })
  return ordered
}

// A rule's monitor is an output name ("DP-1") or a description prefix
// ("desc:Samsung Electric Company SE790C"), as in Hyprland config.
function resolveMonitor(spec, monitors) {
  var text = String(spec || "")
  if (!text) return null
  if (text.indexOf("desc:") === 0) {
    var prefix = text.slice(5)
    for (var i = 0; i < monitors.length; i++) {
      if (String(monitors[i].description || "").indexOf(prefix) === 0) return monitors[i].name
    }
    return null
  }
  for (var j = 0; j < monitors.length; j++) {
    if (monitors[j].name === text) return text
  }
  return null
}

function layout(data, options) {
  var opts = options || {}
  var monitors = sortedMonitors(data && data.monitors, !!opts.vertical)
  var workspaces = (data && data.workspaces) || []
  var rules = (data && data.rules) || []
  if (monitors.length === 0) return []

  var focused = monitors.filter(function(m) { return m.focused })[0] || monitors[0]
  var home = {}
  var byId = {}

  workspaces.forEach(function(ws) {
    if (!ws || ws.id <= 0) return
    byId[ws.id] = ws
    if (ws.monitor) home[ws.id] = ws.monitor
  })

  var numbered = 0
  rules.forEach(function(rule) {
    var id = numericId(rule && rule.workspaceString)
    if (id <= 0) return
    numbered++
    if (home[id]) return
    var name = resolveMonitor(rule.monitor, monitors)
    if (name) home[id] = name
  })

  var alwaysShow = opts.alwaysShow
  if (alwaysShow === undefined || alwaysShow === null) alwaysShow = numbered > 0 ? 0 : 5
  for (var id = 1; id <= alwaysShow; id++) {
    if (!home[id]) home[id] = focused.name
  }

  return monitors.map(function(m) {
    var active = m.activeWorkspace ? m.activeWorkspace.id : 0
    var ids = Object.keys(home)
      .map(Number)
      .filter(function(id) { return home[id] === m.name })
      .sort(function(a, b) { return a - b })
    return {
      monitor: m.name,
      focused: m.name === focused.name,
      workspaces: ids.map(function(id) {
        var ws = byId[id]
        var name = ws && ws.name !== undefined ? String(ws.name) : String(id)
        return {
          id: id,
          label: name !== "" ? name : String(id),
          shown: id === active,
          occupied: !!ws && (ws.windows || 0) > 0
        }
      })
    }
  })
}

// Keep only this bar's own monitor ("own"), or every monitor ("all").
function forScreen(groups, screens, ownMonitor) {
  if (screens !== "own" || !ownMonitor) return groups
  var mine = groups.filter(function(g) { return g.monitor === ownMonitor })
  return mine.length > 0 ? mine : groups
}

if (typeof module !== "undefined") {
  module.exports = {
    forScreen: forScreen,
    layout: layout,
    numericId: numericId,
    resolveMonitor: resolveMonitor
  }
}
