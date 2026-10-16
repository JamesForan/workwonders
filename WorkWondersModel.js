// Layout logic for the Work Wonders bar widget, kept Qt-free so tests/run can check
// it under node against recorded hyprctl output.
//
// Input is what hyprctl prints: { monitors, workspaces, rules } from
// `hyprctl -j monitors`, `hyprctl -j workspaces` and `hyprctl -j workspacerules`.
// Output is one group per monitor, in the order sortedMonitors() explains,
// each listing the workspaces that belong to it:
//
//   [{ monitor: "DP-1", focused: false,
//      workspaces: [{ id: 2, label: "2", special: false, shown: true,
//                     under: false, occupied: true }, ...] }]
//
// Special workspaces (scratchpad, drop-down terminal...) follow
// options.specials: "open" (default) lists one only while it is open, on the
// monitor showing it; "always" also lists it on the monitor it last lived on;
// "hide" never lists them. While one is open it is the shown cell and the
// regular workspace underneath is marked "under". options.specialLabels maps a
// name ("scratchpad") to its label; the default is its first letter.
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

function isInternal(m) {
  return /^(eDP|LVDS|DSI)-/.test(String(m.name || ""))
}

// Default order. Screens side by side (one row, judged by vertical overlap)
// go left to right, as they sit. Stacked screens (more than one row) put the
// built-in panel first, then the rest in reading order: rows top to bottom,
// each row left to right. options.order overrides: "layout" is plain reading
// order; a list of output names or "desc:" prefixes goes first, in that order,
// and any screen not listed follows in the default order.
function sortedMonitors(monitors, order) {
  var list = (monitors || []).filter(function(m) { return m && !m.disabled })
  list.sort(function(a, b) { return ((a.y || 0) - (b.y || 0)) || ((a.x || 0) - (b.x || 0)) })

  var rows = []
  list.forEach(function(m) {
    var top = m.y || 0
    var row = rows[rows.length - 1]
    if (row && top < row.end) {
      row.items.push(m)
      row.end = Math.max(row.end, top + logicalSize(m).h)
    } else {
      rows.push({ end: top + logicalSize(m).h, items: [m] })
    }
  })

  var reading = []
  rows.forEach(function(row) {
    row.items.sort(function(a, b) { return (a.x || 0) - (b.x || 0) })
    reading = reading.concat(row.items)
  })

  var ordered = reading
  if (order !== "layout" && rows.length > 1) {
    ordered = reading.filter(isInternal).concat(reading.filter(function(m) { return !isInternal(m) }))
  }

  if (Array.isArray(order) && order.length) {
    var first = []
    order.forEach(function(spec) {
      var name = resolveMonitor(spec, ordered)
      var m = ordered.filter(function(x) { return x.name === name })[0]
      if (m && first.indexOf(m) === -1) first.push(m)
    })
    ordered = first.concat(ordered.filter(function(m) { return first.indexOf(m) === -1 }))
  }
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
  var monitors = sortedMonitors(data && data.monitors, opts.order)
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

  var specialsMode = opts.specials || "open"
  var specialLabels = opts.specialLabels || {}
  var specials = workspaces.filter(function(ws) {
    return ws && ws.id < 0 && String(ws.name || "").indexOf("special:") === 0
  })

  return monitors.map(function(m) {
    var active = m.activeWorkspace ? m.activeWorkspace.id : 0
    var openSpecial = specialsMode !== "hide" && m.specialWorkspace && m.specialWorkspace.name ? String(m.specialWorkspace.name) : ""
    var ids = Object.keys(home)
      .map(Number)
      .filter(function(id) { return home[id] === m.name })
      .sort(function(a, b) { return a - b })
    var cells = ids.map(function(id) {
      var ws = byId[id]
      var name = ws && ws.name !== undefined ? String(ws.name) : String(id)
      return {
        id: id,
        label: name !== "" ? name : String(id),
        special: false,
        // A special workspace drawn over this monitor takes the fill; the
        // workspace underneath keeps an outline ("under").
        shown: id === active && !openSpecial,
        under: id === active && !!openSpecial,
        occupied: !!ws && (ws.windows || 0) > 0
      }
    })

    if (specialsMode !== "hide") {
      specials.forEach(function(ws) {
        var full = String(ws.name)
        var isOpenHere = full === openSpecial
        var belongsHere = specialsMode === "always" && ws.monitor === m.name && !openElsewhere(full, m.name, monitors)
        if (!isOpenHere && !belongsHere) return
        var short = full.slice("special:".length)
        cells.push({
          id: ws.id,
          name: short,
          label: specialLabels[short] !== undefined ? String(specialLabels[short]) : short.charAt(0).toUpperCase(),
          special: true,
          shown: isOpenHere,
          under: false,
          occupied: (ws.windows || 0) > 0
        })
      })
    }

    return {
      monitor: m.name,
      focused: m.name === focused.name,
      workspaces: cells
    }
  })
}

// A special workspace that is open on one monitor is listed there only.
function openElsewhere(name, here, monitors) {
  return monitors.some(function(m) {
    return m.name !== here && m.specialWorkspace && m.specialWorkspace.name === name
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
    openElsewhere: openElsewhere,
    layout: layout,
    isInternal: isInternal,
    numericId: numericId,
    sortedMonitors: sortedMonitors,
    resolveMonitor: resolveMonitor
  }
}
