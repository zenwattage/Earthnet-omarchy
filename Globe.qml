import QtQuick

// Full-resolution animated wireframe Earth for the Earthnet Omarchy plugin.
//
// All drawing happens on a Canvas at the item's native resolution (Qt scales
// the backing store by the window's devicePixelRatio), driven by a
// FrameAnimation so the globe spins and the trace pulses stay smooth without
// a terminal or sixel in sight.
//
// Geometry (coastline rings + graticule) is delivered once by the Python
// sidecar as lon/lat pairs and converted to unit-sphere vectors up front. Each
// frame only re-applies the spin/tilt rotation and projects, which keeps the
// per-frame cost to a few thousand multiply-adds.
Item {
  id: root

  // --- data injected by the panel / bar widget ---
  property var land: null            // { lat: [], lon: [], rings: [counts] }
  property var borders: null         // { lat: [], lon: [], lines: [counts] }
  property var traces: []            // [{lat, lon, color, proto, port, state, age, phase, alpha, label}]
  property var theme: ({})            // hex strings from earthnet.theme
  property var home: null            // { lat, lon }

  // Data provider: the shell-side process bridge. It is created outside this
  // component (in the panel/bar widget) from PythonSidecar.qml, and passed in
  // so both the compact bar globe and the full panel share one process.
  property var provider: null
  readonly property bool hasProvider: provider !== null && provider !== undefined

  function _applyInit(d) {
    if (!d) return
    if (d.palette) theme = d.palette
    // The compact bar globe uses the coarse geometry; the panel uses the full
    // 50m set for the coastline stroke and the country borders.
    land = (root.compact && d.landCoarse) ? d.landCoarse : d.land
    borders = d.borders || null
    if (d.home) home = d.home
  }
  function _applyFrame(d) {
    if (!d) return
    if (d.traces) traces = d.traces
    if (d.home && (!home || home.lat !== d.home.lat || home.lon !== d.home.lon)) home = d.home
  }
  onProviderChanged: {
    if (hasProvider) { _applyInit(provider.init); _applyFrame(provider.frame) }
  }
  Connections {
    target: root.provider
    ignoreUnknownSignals: true
    function onInited(d) { root._applyInit(d) }
    function onFramed(d) { root._applyFrame(d) }
  }

  // --- appearance / behaviour ---
  property bool running: true        // animate the spin
  property real spinSpeed: 0.35      // radians / second
  property bool showGraticule: true
  property bool showTraces: true
  property bool showStars: true
  // Opacity multiplier for the ocean disk that sits over the starfield. Lower
  // values let more stars show through behind the globe; 1.0 is the original.
  property real diskAlpha: 0.6
  property bool showHome: true
  property bool compact: false       // bar mode: no graticule, bolder rim
  property bool showBorders: true     // faint political (country) borders
  property real borderAlpha: 0.22     // how strongly the near-side borders read
  property bool interactive: false   // drag to rotate, wheel to zoom
  property real zoom: 1.0
  property real minZoom: 0.85
  property real maxZoom: 4.0

  // Rotation about Y (longitude) and X (centre latitude), radians.
  property real spin: 0.0
  property real tilt: 0.0
  property bool tiltPinned: false    // once the user drags, stop auto-setting tilt
  property real traceSpeed: 0.35     // packet pulses per second

  readonly property color oceanColor: theme.ocean || "#123a63"
  readonly property color landColor: theme.land || "#3f6f4a"
  readonly property color gridColor: theme.grid || "#6fb0d0"
  readonly property color ringColor: theme.ring || "#4b9ad0"
  // Political borders: a muted tint of the land colour so they read as
  // administrative lines, not coastlines.
  readonly property color borderColor: theme.border || hexMix(theme.land || "#3f6f4a", theme.grid || "#6fb0d0", 0.35)
  readonly property color starColor: theme.star || "#7a86a0"
  readonly property color spaceColor: theme.space || "#060812"
  readonly property color accentColor: theme.hud_accent || "#78dcff"

  // Internal animation clock (seconds) for the trace pulse and star twinkle.
  property real clock: 0.0

  // Prepared geometry: arrays of [x,y,z] triplets, one entry per prepared ring.
  property var preparedRings: []
  property var preparedBorders: []
  property var preparedGrid: []

  // Deterministic starfield, keyed by canvas size.
  property var stars: []

  // --- geometry preparation ------------------------------------------------

  function _prep(points, count, latFirst) {
    var out = new Float64Array(count * 3)
    var o = 0
    for (var i = 0; i < count; i++) {
      var la, lo
      if (latFirst) { la = points[i * 2 + 0]; lo = points[i * 2 + 1] }
      else { lo = points[i * 2 + 0]; la = points[i * 2 + 1] }
      // All geometry goes through geoToVec so land, borders, graticule, home
      // and traces share one (correct) lon/lat -> sphere embedding.
      var v = geoToVec(la, lo)
      out[o++] = v[0]
      out[o++] = v[1]
      out[o++] = v[2]
    }
    return out
  }

  // Convert a {lat, lon, <countsKey>: [n,...]} payload to unit-sphere
  // Float64Array triplets, one array per polyline/ring.
  function _prepare(geo, countsKey) {
    var rings = []
    if (!geo || !geo.lat || !geo.lon || !geo[countsKey]) return rings
    var lat = geo.lat, lon = geo.lon, counts = geo[countsKey]
    var off = 0
    for (var r = 0; r < counts.length; r++) {
      var n = counts[r]
      if (n < 2) { off += n; continue }
      var arr = new Float64Array(n * 3)
      var o = 0
      for (var i = 0; i < n; i++) {
        var v = geoToVec(lat[off + i], lon[off + i])
        arr[o++] = v[0]
        arr[o++] = v[1]
        arr[o++] = v[2]
      }
      off += n
      rings.push(arr)
    }
    return rings
  }

  function prepareGeometry() {
    preparedRings = _prepare(land, "rings")
    preparedBorders = _prepare(borders, "lines")

    // Graticule: parallels every 30 deg, meridians every 30 deg.
    var grid = []
    for (var plat = -60; plat <= 60; plat += 30) {
      var par = graticuleParallel(plat)
      grid.push(_prep(par, par.length / 2, true))
    }
    for (var plon = -180; plon < 180; plon += 30) {
      var mer = graticuleMeridian(plon)
      grid.push(_prep(mer, mer.length / 2, true))
    }
    preparedGrid = grid
    buildStars()
    globeCanvas.requestPaint()
  }

  function graticuleParallel(lat) {
    var a = []
    for (var lon = -180; lon <= 180; lon += 4) a.push(lat, lon)
    return a
  }

  function graticuleMeridian(lon) {
    var a = []
    for (var lat = -90; lat <= 90; lat += 4) a.push(lat, lon)
    return a
  }

  function buildStars() {
    var w = Math.max(1, Math.round(globeCanvas.width))
    var h = Math.max(1, Math.round(globeCanvas.height))
    var n = Math.floor(w * h * 0.0016)
    var out = []
    for (var i = 0; i < n; i++) {
      // cheap deterministic hash so stars are stable per size
      var x = (Math.sin(i * 12.9898 + w * 0.5) * 43758.5453) % 1
      var y = (Math.sin(i * 78.233 + h * 0.5) * 43758.5453) % 1
      x = Math.abs(x); y = Math.abs(y)
      // Per-star brightness; scaled 20% brighter (capped at full).
      out.push([x * w, y * h, Math.min(1.0, (0.25 + (i % 7) / 10) * 1.2)])
    }
    stars = out
  }

  // --- colour helpers ------------------------------------------------------

  function _rgb(hex) {
    var h = String(hex).replace("#", "")
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2]
    return [parseInt(h.substr(0, 2), 16), parseInt(h.substr(2, 2), 16), parseInt(h.substr(4, 2), 16)]
  }
  function rgba(hex, a) {
    var c = _rgb(hex)
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + a + ")"
  }
  function mix(hexA, hexB, t) {
    var a = _rgb(hexA), b = _rgb(hexB)
    return "rgb(" + Math.round(a[0] + (b[0] - a[0]) * t) + "," +
      Math.round(a[1] + (b[1] - a[1]) * t) + "," +
      Math.round(a[2] + (b[2] - a[2]) * t) + ")"
  }
  // Like mix(), but returns "#rrggbb" so the result can be assigned to a QML
  // `color` property (an "rgb(...)" string is not reliably parsed there).
  function hexMix(hexA, hexB, t) {
    var a = _rgb(hexA), b = _rgb(hexB)
    var h = function(v) { v = Math.max(0, Math.min(255, Math.round(v))); return ("0" + v.toString(16)).slice(-2) }
    return "#" + h(a[0] + (b[0] - a[0]) * t) + h(a[1] + (b[1] - a[1]) * t) + h(a[2] + (b[2] - a[2]) * t)
  }
  function shade(hex, k, floor) {
    var c = _rgb(hex)
    var f = floor === undefined ? 0.0 : floor
    var s = f + (1 - f) * Math.max(0, k)
    return "rgb(" + Math.min(255, Math.round(c[0] * s)) + "," +
      Math.min(255, Math.round(c[1] * s)) + "," +
      Math.min(255, Math.round(c[2] * s)) + ")"
  }

  // --- projection ----------------------------------------------------------

  readonly property real _sinSpin: Math.sin(spin)
  readonly property real _cosSpin: Math.cos(spin)
  readonly property real _sinTilt: Math.sin(tilt)
  readonly property real _cosTilt: Math.cos(tilt)

  // Returns [sx, sy, depth]; depth > 0 is the near hemisphere.
  function project(x, y, z, cx, cy, r) {
    var x1 = _cosSpin * x + _sinSpin * z
    var z1 = -_sinSpin * x + _cosSpin * z
    var y1 = y
    var y2 = _cosTilt * y1 - _sinTilt * z1
    var z2 = _sinTilt * y1 + _cosTilt * z1
    return [cx + x1 * r, cy - y2 * r, z2]
  }

  // Geographic (deg) -> unit vector. +y is north, +z is toward the viewer, and
  // the x-component is negated so the embedding is right-handed as seen from
  // outside the globe: longitude increases to the *right* (east on the right,
  // as on a real globe). Without the negation the sphere is mirrored and reads
  // as if seen from the inside.
  function geoToVec(lat, lon) {
    var p = lat * Math.PI / 180
    var l = lon * Math.PI / 180
    var cp = Math.cos(p)
    return [-cp * Math.cos(l), Math.sin(p), cp * Math.sin(l)]
  }

  // Canvas + frame loop -----------------------------------------------------

  Canvas {
    id: globeCanvas
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      if (ctx) root.paintGlobe(ctx)
    }
    onWidthChanged: root.buildStars()
    onHeightChanged: root.buildStars()
  }

  // Minimum ms between repaints. The panel renders at the compositor rate; the
  // tiny bar globe sets a larger interval so it doesn't project the coastline
  // 60x a second for an icon no one can see that closely.
  property int frameInterval: 0
  property double _accum: 0

  FrameAnimation {
    running: root.running
    onTriggered: {
      var dt = frameTime
      if (dt <= 0 || dt > 0.25) dt = 0.016
      if (root.running) root.spin += dt * root.spinSpeed
      root.clock += dt
      if (root.frameInterval > 0) {
        root._accum += dt * 1000
        if (root._accum < root.frameInterval) return
        root._accum = 0
      }
      globeCanvas.requestPaint()
    }
  }

  // Repaint on discrete state changes (data, theme, toggles) always. Spin and
  // zoom change continuously and are driven by the FrameAnimation while
  // running; only repaint them directly when paused, otherwise they would
  // bypass frameInterval every tick.
  function _repaintIfIdle() { if (!root.running) globeCanvas.requestPaint() }
  onTracesChanged: globeCanvas.requestPaint()
  onThemeChanged: globeCanvas.requestPaint()
  onHomeChanged: {
    if (!tiltPinned && home && home.lat !== undefined) tilt = home.lat * Math.PI / 180
    globeCanvas.requestPaint()
  }
  onLandChanged: prepareGeometry()
  onBordersChanged: prepareGeometry()
  onShowGraticuleChanged: globeCanvas.requestPaint()
  onShowTracesChanged: globeCanvas.requestPaint()
  onShowStarsChanged: globeCanvas.requestPaint()
  onShowHomeChanged: globeCanvas.requestPaint()
  onShowBordersChanged: globeCanvas.requestPaint()
  onZoomChanged: _repaintIfIdle()
  onSpinChanged: _repaintIfIdle()

  // --- painting ------------------------------------------------------------

  function paintGlobe(ctx) {
    var W = globeCanvas.width
    var H = globeCanvas.height
    if (W <= 0 || H <= 0) return
    ctx.reset()
    ctx.clearRect(0, 0, W, H)

    var cx = W / 2
    var cy = H / 2
    // In the panel, reserve headroom for the ballistic arcs: the tallest reach
    // ~2.0*R (see arcPoints), so R = 0.24 of the item keeps every arc inside
    // the canvas. The bar globe stays large (it clips arcs to the disk).
    var baseR = Math.min(W, H) * (root.compact ? 0.47 : 0.24)
    var R = baseR * root.zoom

    // Starfield behind everything.
    if (root.showStars) {
      ctx.fillStyle = rgba(root.starColor, 0.99)
      for (var i = 0; i < stars.length; i++) {
        var st = stars[i]
        var tw = 0.55 + 0.45 * Math.sin(root.clock * 1.7 + i)
        ctx.globalAlpha = st[2] * tw
        ctx.fillRect(st[0], st[1], 1, 1)
      }
      ctx.globalAlpha = 1
    }

    // Soft atmospheric glow behind the disk.
    var glow = ctx.createRadialGradient(cx, cy, R * 0.7, cx, cy, R * 1.0)
    glow.addColorStop(0, rgba(root.ringColor, 0.07))
    glow.addColorStop(1, rgba(root.ringColor, 0))
    ctx.fillStyle = glow
    ctx.beginPath()
    ctx.arc(cx, cy, R * 1.0, 0, Math.PI * 2)
    ctx.fill()

    // Translucent ocean disk: gives the wireframe something to sit on and
    // makes the sphere read as a globe rather than a flat map. The disk is
    // drawn over the starfield, so its opacity is scaled by diskAlpha to let
    // the stars behind the globe show through.
    var da = root.diskAlpha
    var sphere = ctx.createRadialGradient(
      cx - R * 0.28, cy - R * 0.32, R * 0.05,
      cx, cy, R)
    sphere.addColorStop(0, rgba(root.oceanColor, 0.85 * da))
    sphere.addColorStop(0.65, rgba(root.oceanColor, 0.55 * da))
    sphere.addColorStop(1, rgba(root.spaceColor, 0.18 * da))
    ctx.beginPath()
    ctx.arc(cx, cy, R, 0, Math.PI * 2)
    ctx.fillStyle = sphere
    ctx.fill()

    // Everything on the sphere is clipped to the disk silhouette.
    ctx.save()
    ctx.beginPath()
    ctx.arc(cx, cy, R - 0.4, 0, Math.PI * 2)
    ctx.clip()

    // Far hemisphere first (dim), then the near hemisphere (bright) on top.
    if (!root.compact && root.showGraticule) {
      drawGrid(ctx, cx, cy, R, false)
      drawGrid(ctx, cx, cy, R, true)
    }
    drawLand(ctx, cx, cy, R, false)
    drawLand(ctx, cx, cy, R, true)
    // Faint political borders over the near-side land only.
    if (root.showBorders && !root.compact) drawBorders(ctx, cx, cy, R)
    if (root.showHome) drawHome(ctx, cx, cy, R)

    ctx.restore()

    // Rim.
    var rimGrad = ctx.createRadialGradient(cx, cy, R * 0.9, cx, cy, R)
    rimGrad.addColorStop(0, rgba(root.ringColor, 0))
    rimGrad.addColorStop(1, rgba(root.ringColor, 0.9))
    ctx.beginPath()
    ctx.arc(cx, cy, R, 0, Math.PI * 2)
    ctx.lineWidth = root.compact ? 1.6 : 1.2
    ctx.strokeStyle = rimGrad
    ctx.stroke()

    // Traces are painted last and, in the panel, *outside* the disk clip so
    // their arcs can sweep past the silhouette for a 3D effect. The compact
    // bar globe clips itself internally.
    if (root.showTraces) drawTraces(ctx, cx, cy, R)
  }

  // Build a stroke path over the land rings for one hemisphere, without
  // stroking it. Rings are split at the limb so the far half never bleeds a
  // bright line across the near half. The rotation and projection are inlined
  // to avoid allocating a [x,y,depth] array per point, and all rings share one
  // path (a moveTo starts each subpath). Returns true if any point was drawn.
  function _buildRingsPath(ctx, rings, cx, cy, R, near) {
    var cs = _cosSpin, ss = _sinSpin, ct = _cosTilt, st = _sinTilt
    ctx.beginPath()
    var started = false
    for (var r = 0; r < rings.length; r++) {
      var a = rings[r]
      var n = a.length / 3
      var drawing = false
      for (var i = 0; i < n; i++) {
        var o = i * 3
        var x0 = a[o], y0 = a[o + 1], z0 = a[o + 2]
        var x1 = cs * x0 + ss * z0
        var z1 = -ss * x0 + cs * z0
        var depth = st * y0 + ct * z1
        if ((near && depth < 0) || (!near && depth >= 0)) { drawing = false; continue }
        var sy = cy - (ct * y0 - st * z1) * R
        var sx = cx + x1 * R
        if (!drawing) { ctx.moveTo(sx, sy); drawing = true; started = true }
        else ctx.lineTo(sx, sy)
      }
    }
    return started
  }

  // Coastlines for one hemisphere, stroked once. Rings are split at the limb
  // so the far half never bleeds a bright line across the near half.
  function drawLand(ctx, cx, cy, R, near) {
    var rings = root.preparedRings
    if (!rings || rings.length === 0) return
    ctx.lineJoin = "round"
    ctx.lineCap = "round"
    ctx.globalAlpha = 1
    ctx.strokeStyle = near
      ? shade(root.landColor, 1.15, 0.35)
      : rgba(root.landColor, 0.28)
    ctx.lineWidth = near ? Math.max(0.8, R / 320) : Math.max(0.6, R / 460)
    if (_buildRingsPath(ctx, rings, cx, cy, R, near)) ctx.stroke()
  }

  // Faint political borders over the near-side land, so countries read without
  // competing with the coastline. Near side only: the far side is occluded by
  // the globe anyway, so drawing it would be invisible cost.
  function drawBorders(ctx, cx, cy, R) {
    var lines = root.preparedBorders
    if (!lines || lines.length === 0) return
    var cs = _cosSpin, ss = _sinSpin, ct = _cosTilt, st = _sinTilt
    ctx.lineJoin = "round"
    ctx.lineCap = "round"
    ctx.globalAlpha = 1
    // borderColor may be a computed "rgb(...)" string, so build the stroke from
    // the resolved color channels rather than re-parsing it as hex.
    ctx.strokeStyle = Qt.rgba(root.borderColor.r, root.borderColor.g,
                              root.borderColor.b, root.borderAlpha)
    ctx.lineWidth = Math.max(0.5, R / 700)
    ctx.beginPath()
    var started = false
    for (var r = 0; r < lines.length; r++) {
      var a = lines[r]
      var n = a.length / 3
      var drawing = false
      for (var i = 0; i < n; i++) {
        var o = i * 3
        var x0 = a[o], y0 = a[o + 1], z0 = a[o + 2]
        var x1 = cs * x0 + ss * z0
        var z1 = -ss * x0 + cs * z0
        if (st * y0 + ct * z1 < 0) { drawing = false; continue }
        var sy = cy - (ct * y0 - st * z1) * R
        var sx = cx + x1 * R
        if (!drawing) { ctx.moveTo(sx, sy); drawing = true; started = true }
        else ctx.lineTo(sx, sy)
      }
    }
    if (started) ctx.stroke()
  }

  function drawGrid(ctx, cx, cy, R, near) {
    var grid = root.preparedGrid
    var cs = _cosSpin, ss = _sinSpin, ct = _cosTilt, st = _sinTilt
    ctx.setLineDash([])
    ctx.strokeStyle = near ? rgba(root.gridColor, 0.30) : rgba(root.gridColor, 0.10)
    ctx.lineWidth = near ? 0.8 : 0.6
    for (var g = 0; g < grid.length; g++) {
      var a = grid[g]
      var n = a.length / 3
      var drawing = false
      ctx.beginPath()
      for (var i = 0; i < n; i++) {
        var o = i * 3
        var x0 = a[o], y0 = a[o + 1], z0 = a[o + 2]
        var x1 = cs * x0 + ss * z0
        var z1 = -ss * x0 + cs * z0
        var depth = st * y0 + ct * z1
        if ((near && depth < 0) || (!near && depth >= 0)) { drawing = false; continue }
        var sy = cy - (ct * y0 - st * z1) * R
        var sx = cx + x1 * R
        if (!drawing) { ctx.moveTo(sx, sy); drawing = true }
        else ctx.lineTo(sx, sy)
      }
      ctx.stroke()
    }
  }

  function drawHome(ctx, cx, cy, R) {
    if (!home) return
    var v = geoToVec(home.lat, home.lon)
    var p = project(v[0], v[1], v[2], cx, cy, R)
    if (p[2] < 0) return
    var pulse = 0.5 + 0.5 * Math.sin(root.clock * 2.2)
    ctx.beginPath()
    ctx.arc(p[0], p[1], 2.2, 0, Math.PI * 2)
    ctx.fillStyle = rgba(root.accentColor, 1)
    ctx.fill()
    ctx.beginPath()
    ctx.arc(p[0], p[1], 4 + pulse * 4, 0, Math.PI * 2)
    ctx.strokeStyle = rgba(root.accentColor, 0.5 * (1 - pulse * 0.5))
    ctx.lineWidth = 1
    ctx.stroke()
  }

  // Great-circle path between two unit vectors, then bowed in *screen space*
  // into a ballistic flight path: it lifts off at the origin, rises clear of
  // the globe, and lands on the destination. Returns the projected polyline
  // plus per-point depth (the depth is the true surface depth, so near/behind
  // classification stays correct).
  //
  // A purely radial lift (scaling the 3D point away from the globe centre)
  // cannot produce this look: a point whose surface position projects near the
  // centre barely moves when scaled, so the arc just lies on the sphere and
  // appears to stop at the rim. Instead the surface path is projected first and
  // then offset in screen space, perpendicular to the globe, so the apex always
  // departs the disk no matter where the route sits.
  function arcPoints(alat, alon, blat, blon, cx, cy, R, steps) {
    var a = geoToVec(alat, alon)
    var b = geoToVec(blat, blon)
    var dot = Math.max(-1, Math.min(1, a[0] * b[0] + a[1] * b[1] + a[2] * b[2]))
    var omega = Math.acos(dot)

    // 1) The on-surface great circle, projected to screen space.
    var surf = []
    for (var i = 0; i <= steps; i++) {
      var t = i / steps
      var x, y, z
      if (omega < 1e-6) {
        x = a[0]; y = a[1]; z = a[2]
      } else if (omega > Math.PI - 1e-4) {
        var ux = 0, uy = a[2], uz = -a[1]
        var ul = Math.sqrt(ux * ux + uy * uy + uz * uz) || 1
        ux /= ul; uy /= ul; uz /= ul
        var th = t * Math.PI
        x = a[0] * Math.cos(th) + ux * Math.sin(th)
        y = a[1] * Math.cos(th) + uy * Math.sin(th)
        z = a[2] * Math.cos(th) + uz * Math.sin(th)
      } else {
        var s = Math.sin(omega)
        var w0 = Math.sin((1 - t) * omega) / s
        var w1 = Math.sin(t * omega) / s
        x = w0 * a[0] + w1 * b[0]
        y = w0 * a[1] + w1 * b[1]
        z = w0 * a[2] + w1 * b[2]
      }
      surf.push(project(x, y, z, cx, cy, R))
    }

    // 2) Bow direction: outward from the globe centre through the projected
    //    chord midpoint. If the chord passes through the centre (its midpoint
    //    lands on the centre) there is no outward direction, so bow upward on
    //    screen instead -- still a clean, unambiguous arc.
    var sa = surf[0], sb = surf[surf.length - 1]
    var mx = (sa[0] + sb[0]) * 0.5 - cx
    var my = (sa[1] + sb[1]) * 0.5 - cy
    var ml = Math.sqrt(mx * mx + my * my)
    var bx, by
    if (ml > 0.02 * R) { bx = mx / ml; by = my / ml }
    else { bx = 0; by = -1 }

    // 3) Offset each point by the ballistic profile: zero at both endpoints,
    //    peaking at the apex. Height scales with route distance.
    var archPx = (0.30 + 0.85 * Math.max(0, Math.min(1, (1 - dot) / 2))) * R
    var pts = []
    for (var j = 0; j <= steps; j++) {
      var tt = j / steps
      var lift = Math.sin(Math.PI * tt) * archPx
      var sp = surf[j]
      pts.push([sp[0] + bx * lift, sp[1] + by * lift, sp[2]])
    }
    return pts
  }

  // Build one stroke path over an arc's projected points.
  //
  //   pass === "near"   -- the hemisphere facing the viewer (depth >= 0),
  //                        drawn at full brightness.
  //   pass === "behind" -- the far hemisphere, but only where the lifted arc
  //                        has cleared the globe's silhouette (projected radius
  //                        >= 1). Those points arch over the limb, so they read
  //                        as passing *behind* the globe rather than being
  //                        hidden by it. Points behind the disk are skipped,
  //                        which is what creates the 3D wrap-around.
  //
  // When `head` is >= 0 the path is additionally limited to points within
  // `half` of the moving packet position, so the same helper draws the bright
  // comet head on both passes.
  function buildArc(ctx, pts, head, half, pass, cx, cy, R) {
    ctx.beginPath()
    var drawing = false
    for (var i = 0; i < pts.length; i++) {
      if (head >= 0) {
        var t = i / (pts.length - 1)
        var d = Math.abs(t - head)
        d = Math.min(d, 1 - d)
        if (d > half) { drawing = false; continue }
      }
      var p = pts[i]
      var behind = p[2] < 0
      if (pass === "near") {
        if (behind) { drawing = false; continue }
      } else {
        if (!behind) { drawing = false; continue }
        var dx = (p[0] - cx) / R
        var dy = (p[1] - cy) / R
        if (dx * dx + dy * dy < 1.0) { drawing = false; continue }
      }
      if (!drawing) { ctx.moveTo(p[0], p[1]); drawing = true }
      else ctx.lineTo(p[0], p[1])
    }
    ctx.stroke()
  }

  function drawTraces(ctx, cx, cy, R) {
    if (!home || !traces) return
    var compact = root.compact
    ctx.lineCap = "round"
    ctx.lineJoin = "round"
    // The bar globe stays a clean clipped circle; the full panel lets arcs
    // sweep outside the silhouette.
    if (compact) {
      ctx.save()
      ctx.beginPath()
      ctx.arc(cx, cy, R - 0.4, 0, Math.PI * 2)
      ctx.clip()
    }
    for (var i = 0; i < traces.length; i++) {
      var tr = traces[i]
      if (tr.lat === undefined || tr.lon === undefined) continue
      var alpha = tr.alpha === undefined ? 1 : tr.alpha
      if (alpha <= 0.02) continue
      var color = tr.color || root.accentColor
      var pts = arcPoints(home.lat, home.lon, tr.lat, tr.lon, cx, cy, R,
                          compact ? 26 : 60)
      var head = ((tr.phase || 0) + root.clock * root.traceSpeed) % 1

      // Soft glow + base arc in the destination's own colour, near side only.
      ctx.shadowBlur = compact ? 0 : 6
      ctx.shadowColor = rgba(color, 0.75)
      ctx.strokeStyle = rgba(color, 0.55 * alpha)
      ctx.lineWidth = compact ? 1.1 : 1.4
      buildArc(ctx, pts, -1, 0, "near", cx, cy, R)

      // The descending half of the flight path where it has cleared the limb --
      // drawn brighter than the far hemisphere so the arc visibly sails outside
      // the globe rather than stopping at its outline. Not drawn in the compact
      // bar globe.
      if (!compact) {
        ctx.shadowBlur = 0
        ctx.strokeStyle = rgba(color, 0.45 * alpha)
        ctx.lineWidth = 1.6
        buildArc(ctx, pts, -1, 0, "behind", cx, cy, R)
      }

      // Bright moving packet head, wrapping around the arc.
      ctx.shadowBlur = compact ? 0 : 10
      ctx.strokeStyle = rgba(color, Math.min(1, 0.95 * alpha))
      ctx.lineWidth = compact ? 1.5 : 2.3
      buildArc(ctx, pts, head, compact ? 0.14 : 0.10, "near", cx, cy, R)

      if (!compact) {
        ctx.shadowBlur = 0
        ctx.strokeStyle = rgba(color, 0.4 * Math.min(1, 0.95 * alpha))
        ctx.lineWidth = 1.6
        buildArc(ctx, pts, head, 0.10, "behind", cx, cy, R)
      }
      ctx.shadowBlur = 0
    }
    if (compact) ctx.restore()
    ctx.globalAlpha = 1
  }

  // Optional direct manipulation (used by the panel). Dragging rotates and
  // pins the tilt; the wheel zooms.
  DragHandler {
    id: dragHandler
    enabled: root.interactive
    target: null
    acceptedButtons: Qt.LeftButton
    property real lastX: 0
    property real lastY: 0
    onActiveChanged: {
      if (active) { lastX = centroid.position.x; lastY = centroid.position.y }
      root.tiltPinned = true
    }
    onTranslationChanged: function(delta) {
      root.spin += delta.x * 0.008 / root.zoom
      root.tilt = Math.max(-1.35, Math.min(1.35, root.tilt + delta.y * 0.008 / root.zoom))
    }
  }

  WheelHandler {
    enabled: root.interactive
    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: function(event) {
      var factor = Math.exp(event.angleDelta.y / 720)
      root.zoom = Math.max(root.minZoom, Math.min(root.maxZoom, root.zoom * factor))
      event.accepted = true
    }
  }

  Component.onCompleted: {
    buildStars()
    if (home && home.lat !== undefined && !tiltPinned) tilt = home.lat * Math.PI / 180
    prepareGeometry()
  }
}
