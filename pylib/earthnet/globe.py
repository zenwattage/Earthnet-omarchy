"""3D translucent globe renderer for the terminal.

Pure-stdlib, truecolor, half-block compositing. Each terminal cell is split into
a top and bottom sub-pixel (▀/▄/█/space) so we get ~square pixels and smooth
shading. The globe is rendered by *reverse* orthographic projection: for every
sub-pixel inside the globe disk we compute the near and far surface points,
inverse-rotate them back to geographic (lat,lon), look up a land mask, and blend
a near (bright) surface over a far (dim, translucent) surface. Coastlines and a
lat/long graticule are drawn in the same pass.

The module is deliberately independent of the rest of the app: ``render_frame``
returns a complete ANSI string for a given (cols, rows) canvas, so it can be
dumped to a file for offline verification or written straight to a TTY.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------

TRUECOLOR = "\x1b[38;2;{r};{g};{b}m"
TRUECOLOR_BG = "\x1b[48;2;{r};{g};{b}m"
RESET = "\x1b[0m"
HIDE = "\x1b[?25l"
SHOW = "\x1b[?25h"
ALT_ON = "\x1b[?1049h"
ALT_OFF = "\x1b[?1049l"
CLEAR = "\x1b[2J"
HOME = "\x1b[H"


def clamp(v: int, lo: int = 0, hi: int = 255) -> int:
    return lo if v < lo else hi if v > hi else v


_STAR_CACHE: dict[tuple[int, int], frozenset] = {}


def _stars_for(W: int, H: int) -> frozenset:
    key = (W, H)
    s = _STAR_CACHE.get(key)
    if s is not None:
        return s
    import hashlib
    n = int(W * H * 0.012)
    pts = set()
    for i in range(n):
        h = hashlib.md5(f"{W}x{H}:{i}".encode()).digest()
        px = (h[0] << 8 | h[1]) % W
        py = (h[2] << 8 | h[3]) % H
        pts.add((px, py))
    fs = frozenset(pts)
    _STAR_CACHE[key] = fs
    return fs


def mix(a, b, t: float):
    """Blend two (r,g,b) tuples by t (0=a .. 1=b)."""
    return (
        int(a[0] + (b[0] - a[0]) * t),
        int(a[1] + (b[1] - a[1]) * t),
        int(a[2] + (b[2] - a[2]) * t),
    )


# Palette --------------------------------------------------------------------
def hex_rgb(s: str) -> tuple[int, int, int]:
    """Parse '#RRGGBB' or 'RRGGBB' into an (r,g,b) tuple."""
    s = s.strip().lstrip("#")
    if len(s) == 3:
        s = "".join(c * 2 for c in s)
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


def darken(c, k: float):
    return (int(c[0] * k), int(c[1] * k), int(c[2] * k))


@dataclass
class Palette:
    space: tuple = (6, 8, 18)
    ocean: tuple = (18, 42, 88)
    land: tuple = (54, 104, 70)
    land_hi: tuple = (96, 150, 92)
    grid: tuple = (70, 150, 170)
    ring: tuple = (40, 90, 150)
    star: tuple = (90, 100, 130)
    trace: tuple = (90, 220, 255)
    trace_hot: tuple = (255, 240, 150)
    trace_far: tuple = (40, 90, 130)
    # protocol arc colors
    proto_tcp: tuple = (90, 220, 255)
    proto_udp: tuple = (255, 200, 90)
    proto_icmp: tuple = (230, 130, 200)
    # HUD
    hud_dim: tuple = (120, 140, 170)
    hud_bright: tuple = (200, 230, 255)
    hud_accent: tuple = (120, 220, 255)


DEFAULT_PALETTE = Palette()

# Backward-compatible module constants (used by the demo / fallback).
SPACE = DEFAULT_PALETTE.space
OCEAN = DEFAULT_PALETTE.ocean
LAND = DEFAULT_PALETTE.land
LAND_HI = DEFAULT_PALETTE.land_hi
GRID = DEFAULT_PALETTE.grid
RING = DEFAULT_PALETTE.ring
STAR = DEFAULT_PALETTE.star
TRACE = DEFAULT_PALETTE.trace
TRACE_HOT = DEFAULT_PALETTE.trace_hot
TRACE_FAR = DEFAULT_PALETTE.trace_far


# ---------------------------------------------------------------------------
# Land mask
# ---------------------------------------------------------------------------

@dataclass
class LandMask:
    """Equiangular land-coverage grid. ``data`` is a flat bytearray of 0..255
    coverage over (n_lat x n_lon) cells, lat index 0 = +90 (north), last =
    -90. Coverage is pre-supersampled at build time so coastlines render
    anti-aliased at no runtime cost."""
    n_lat: int
    n_lon: int
    data: bytearray

    def coverage(self, lat: float, lon: float) -> float:
        """Land fraction 0..1 at a geographic point."""
        if lat > 90.0 or lat < -90.0:
            return 0.0
        lon = (lon + 180.0) % 360.0 - 180.0
        li = int((90.0 - lat) / 180.0 * self.n_lat)
        lo = int((lon + 180.0) / 360.0 * self.n_lon)
        if li < 0:
            li = 0
        elif li >= self.n_lat:
            li = self.n_lat - 1
        if lo < 0:
            lo = 0
        elif lo >= self.n_lon:
            lo = self.n_lon - 1
        return self.data[li * self.n_lon + lo] / 255.0

    def is_land(self, lat: float, lon: float) -> bool:
        return self.coverage(lat, lon) > 0.5


def empty_landmask(n_lat: int = 360, n_lon: int = 720) -> LandMask:
    return LandMask(n_lat, n_lon, bytearray(n_lat * n_lon))


# ---------------------------------------------------------------------------
# Rotation / projection math
# ---------------------------------------------------------------------------

def geo_to_vec(lat: float, lon: float):
    """Geographic (deg) -> unit vector. +y north, +z toward viewer."""
    p = math.radians(lat)
    l = math.radians(lon)
    cp = math.cos(p)
    return (cp * math.cos(l), math.sin(p), cp * math.sin(l))


def vec_to_geo(v):
    x, y, z = v
    lat = math.degrees(math.asin(max(-1.0, min(1.0, y))))
    lon = math.degrees(math.atan2(z, x))
    return lat, lon


def _rot_x(v, a):
    c, s = math.cos(a), math.sin(a)
    x, y, z = v
    return (x, c * y - s * z, s * y + c * z)


def _rot_y(v, a):
    c, s = math.cos(a), math.sin(a)
    x, y, z = v
    return (c * x + s * z, y, -s * x + c * z)


def _mat_rot_x(a):
    c, s = math.cos(a), math.sin(a)
    return (1.0, 0.0, 0.0, 0.0, c, -s, 0.0, s, c)


def _mat_rot_y(a):
    c, s = math.cos(a), math.sin(a)
    return (c, 0.0, s, 0.0, 1.0, 0.0, -s, 0.0, c)


def _mat_mul(a, b):
    return tuple(
        sum(a[i // 3 * 3 + k] * b[k * 3 + (i % 3)] for k in range(3))
        for i in range(9)
    )


def _mat_vec(m, v):
    x, y, z = v
    return (m[0] * x + m[1] * y + m[2] * z,
            m[3] * x + m[4] * y + m[5] * z,
            m[6] * x + m[7] * y + m[8] * z)


@dataclass
class Camera:
    spin: float = 0.0          # rotation about Y (longitude drift), radians
    tilt: float = math.radians(23.5)  # tilt about X, radians
    radius: float = 1.0        # set per-frame from canvas size
    _fwd: tuple = field(default=(1, 0, 0, 0, 1, 0, 0, 0, 1), repr=False)
    _inv: tuple = field(default=(1, 0, 0, 0, 1, 0, 0, 0, 1), repr=False)

    def update_matrices(self):
        # Order: tilt (about X) *after* spin (about Y) -> world = Rx(tilt)·Ry(spin)·geo.
        # This keeps the screen-center latitude constant (== tilt) while longitude
        # rotates through, so the globe stays centered on a chosen latitude.
        self._fwd = _mat_mul(_mat_rot_x(self.tilt), _mat_rot_y(self.spin))
        self._inv = _mat_mul(_mat_rot_y(-self.spin), _mat_rot_x(-self.tilt))

    def world(self, v):
        """geographic unit vector -> world (post spin/tilt)."""
        return _mat_vec(self._fwd, v)

    def geo(self, w):
        """world unit vector -> geographic (inverse)."""
        return vec_to_geo(_mat_vec(self._inv, w))


# ---------------------------------------------------------------------------
# Traces (great-circle arcs)
# ---------------------------------------------------------------------------

@dataclass
class Trace:
    a_lat: float
    a_lon: float
    b_lat: float
    b_lon: float
    color: tuple = TRACE
    age: float = 0.0          # seconds since first seen
    life: float = 9999.0      # remaining visibility seconds
    phase: float = 0.0        # animation position 0..1
    alpha: float = 1.0        # overall opacity (fade in/out)
    label: str = ""
    proto: str = ""
    country: str = ""
    cc: str = ""               # ISO 3166-1 alpha-2 country code (for flag emoji)
    city: str = ""
    dst_port: int = 0          # remote port (e.g. 443)
    state: str = ""            # conntrack state (ESTABLISHED, TIME_WAIT, ...)

    def a_vec(self):
        return geo_to_vec(self.a_lat, self.a_lon)

    def b_vec(self):
        return geo_to_vec(self.b_lat, self.b_lon)

    def arch_height(self) -> float:
        """How far the arc bows above the surface, scaled by distance."""
        a, b = self.a_vec(), self.b_vec()
        d = max(0.0, min(1.0, (1.0 - sum(x * y for x, y in zip(a, b))) / 2.0))
        # d=0 same point, d=1 antipode. bow up to 0.45R for far hops.
        return 0.12 + 0.45 * d

    def point(self, t: float, camera: Camera):
        """Point along the arc at parameter t in world coordinates.

        slerp on the unit sphere, then lift radially outward by a sin arch so
        long hops visibly arc over the globe."""
        a, b = self.a_vec(), self.b_vec()
        dot = max(-1.0, min(1.0, sum(x * y for x, y in zip(a, b))))
        omega = math.acos(dot)
        if omega < 1e-6:
            p = a
        elif omega > math.pi - 1e-4:
            # antipode: slerp undefined; use a perpendicular great circle
            ux, uy, uz = a[1] * 1 - a[2] * 0, a[2] * 0 - a[0] * 1, a[0] * 0 - a[1] * 0
            # cross(a, [1,0,0]) = (0, a[2], -a[1]); fallback cross(a,[0,1,0])
            ux, uy, uz = 0.0, a[2], -a[1]
            ul = math.sqrt(ux * ux + uy * uy + uz * uz)
            if ul < 1e-6:
                ux, uy, uz = -a[2], 0.0, a[0]
                ul = math.sqrt(ux * ux + uy * uy + uz * uz)
            ux, uy, uz = ux / ul, uy / ul, uz / ul
            th = t * math.pi
            p = (a[0] * math.cos(th) + ux * math.sin(th),
                 a[1] * math.cos(th) + uy * math.sin(th),
                 a[2] * math.cos(th) + uz * math.sin(th))
        else:
            s = math.sin(omega)
            p = tuple(
                (math.sin((1 - t) * omega) / s) * a[i]
                + (math.sin(t * omega) / s) * b[i]
                for i in range(3)
            )
        lift = 1.0 + math.sin(math.pi * t) * self.arch_height()
        p = tuple(c * lift for c in p)
        return camera.world(p)


# ---------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------

@dataclass
class GlobeConfig:
    land: LandMask = field(default_factory=empty_landmask)
    graticule: bool = True
    grid_step_lat: int = 15
    grid_step_lon: int = 30
    translucent: float = 0.30   # how much far-side shows through near ocean
    space_alpha: float = 0.10   # how much bg shows through the disk edge
    stars: bool = True
    palette: Palette = field(default_factory=Palette)


def _shade(base, z: float, gain: float = 1.0):
    """Lambert-ish shading from depth z (-1..1), light from camera (+z)."""
    b = 0.18 + 0.82 * max(0.0, z)  # near side lit; far gets ambient floor
    return (
        clamp(int(base[0] * b * gain)),
        clamp(int(base[1] * b * gain)),
        clamp(int(base[2] * b * gain)),
    )


def render_frame(
    cols: int,
    rows: int,
    camera: Camera,
    traces: list[Trace],
    cfg: GlobeConfig,
    bg: tuple | None = None,
    rx: float | None = None,
    ry: float | None = None,
) -> str:
    """Render one frame to an ANSI string sized for (cols, rows).

    Sub-pixel grid: W=cols, H=rows*2. Each terminal cell packs a top (▀) and
    bottom (▄) sub-pixel via fg/bg colours, or a full block / space.

    ``rx``/``ry`` are the globe radii in sub-pixels (horizontal/vertical). They
    account for the terminal cell aspect so the disk is a true physical circle,
    and let the caller fix a physical size (e.g. 6 inches). When omitted, the
    globe fills the canvas with a square projection.
    """
    pal = cfg.palette
    if bg is None:
        bg = pal.space
    W = max(8, cols)
    H = max(8, rows * 2)
    cx = W / 2.0
    cy = H / 2.0
    if rx is None or ry is None:
        R = min(W, H) * 0.46
        rx = ry = R
    camera.radius = max(rx, ry)

    land = cfg.land
    n_lat = land.n_lat
    inv_180 = 180.0
    inv_360 = 360.0

    # Pre-compute star positions deterministically from size (cached).
    star_set = _stars_for(W, H) if cfg.stars else set()

    # Trace pixel buffer: each sub-pixel can hold a glowing colour + alpha.
    trace_buf: dict[tuple[int, int], tuple] = {}

    def plot(px, py, color, alpha):
        if 0 <= px < W and 0 <= py < H:
            key = (px, py)
            prev = trace_buf.get(key)
            if prev is None or alpha > prev[1]:
                trace_buf[key] = (color, alpha)

    for tr in traces:
        _draw_trace(tr, camera, rx, ry, cx, cy, plot, pal)

    out = [HOME]
    inv_rx = 1.0 / rx
    inv_ry = 1.0 / ry
    camera.update_matrices()
    minv = camera._inv

    for row in range(rows):
        line = []
        for col in range(W):
            top_py = row * 2
            bot_py = row * 2 + 1
            top = _sample_subpixel(col, top_py, cx, cy, inv_rx, inv_ry,
                                   minv, land, n_lat, inv_180, inv_360,
                                   cfg, bg, star_set, trace_buf)
            bot = _sample_subpixel(col, bot_py, cx, cy, inv_rx, inv_ry,
                                   minv, land, n_lat, inv_180, inv_360,
                                   cfg, bg, star_set, trace_buf)
            # collapse identical/space pairs into single chars
            if top is None and bot is None:
                line.append(" ")
                continue
            if top is None:
                # bottom only -> lower half block, fg=bot, bg=default
                r, g, b = bot
                line.append(f"\x1b[38;2;{r};{g};{b}m▄\x1b[39m")
                continue
            if bot is None:
                r, g, b = top
                line.append(f"\x1b[38;2;{r};{g};{b}m▀\x1b[39m")
                continue
            if top == bot:
                r, g, b = top
                line.append(f"\x1b[38;2;{r};{g};{b}m█\x1b[39m")
                continue
            tr_, tg_, tb_ = top
            br_, bg_, bb_ = bot
            line.append(
                f"\x1b[38;2;{tr_};{tg_};{tb_};48;2;{br_};{bg_};{bb_}m▀\x1b[0m"
            )
        out.append("".join(line))
    return "\n".join(out)


def _sample_subpixel(px, py, cx, cy, inv_rx, inv_ry, minv, land, n_lat,
                     inv_180, inv_360, cfg, bg, star_set, trace_buf):
    pal = cfg.palette
    sx = px + 0.5 - cx
    sy = py + 0.5 - cy
    nx0 = sx * inv_rx
    ny0 = -sy * inv_ry
    r2n = nx0 * nx0 + ny0 * ny0   # squared distance on the unit disk

    # trace glow on top of everything (drawn over space too, for arching arcs)
    tb = trace_buf.get((px, py))
    trace_over = tb  # (color, alpha) or None

    if r2n > 1.0:
        # outside the disk: space, maybe a star or an arching trace pixel
        if (px, py) in star_set:
            return pal.star
        return trace_over[0] if trace_over else None

    # near and far surface points on the unit sphere
    z = math.sqrt(1.0 - r2n)
    nx, ny, nz = nx0, ny0, z
    fx, fy, fz = nx0, ny0, -z

    # inverse-rotate near and far world points -> geographic (inline mat-vec)
    m0, m1, m2, m3, m4, m5, m6, m7, m8 = minv
    gy_n = m3 * nx + m4 * ny + m5 * nz
    gz_n = m6 * nx + m7 * ny + m8 * nz
    nlat = math.degrees(math.asin(gy_n if -1.0 < gy_n < 1.0 else (1.0 if gy_n > 0 else -1.0)))
    nlon = math.degrees(math.atan2(gz_n, m0 * nx + m1 * ny + m2 * nz))

    gy_f = m3 * fx + m4 * fy + m5 * fz
    gz_f = m6 * fx + m7 * fy + m8 * fz
    flat = math.degrees(math.asin(gy_f if -1.0 < gy_f < 1.0 else (1.0 if gy_f > 0 else -1.0)))
    flon = math.degrees(math.atan2(gz_f, m0 * fx + m1 * fy + m2 * fz))

    # coverage 0..1 for anti-aliased coastlines
    cn = land.coverage(nlat, nlon)
    cf = land.coverage(flat, flon)

    # depth-based shading
    nz_clamp = nz  # already in -1..1
    fz_clamp = fz

    near_base = mix(pal.ocean, pal.land, cn)
    far_base = mix(pal.ocean, pal.land, cf)
    near_col = _shade(near_base, nz_clamp, gain=0.90 + 0.10 * cn)
    far_col = _shade(far_base, fz_clamp, gain=0.55)

    # blend near over far: land is mostly opaque, ocean lets far side through
    alpha_near = 0.78 * cn + (1.0 - cfg.translucent) * (1.0 - cn)
    col = mix(far_col, near_col, alpha_near)

    # graticule
    if cfg.graticule:
        if abs(nlon % cfg.grid_step_lon) < 1.2 or abs(nlat % cfg.grid_step_lat) < 1.1:
            # only tint lines on the near side strongly; far side faintly
            g = mix(col, pal.grid, 0.45 if nz_clamp > 0 else 0.12)
            col = g

    # edge darkening for a soft terminator / rim (unit-disk radius)
    edge = r2n
    if edge > 0.86:
        col = mix(col, pal.ring, (edge - 0.86) / 0.14 * 0.5)

    # let a little background through near the very rim for "floating" feel
    if edge > 0.94:
        col = mix(col, bg, cfg.space_alpha)

    # composit trace glow on top
    if trace_over is not None:
        tcol, ta = trace_over
        # if the trace point is on the far side (behind globe), dim it
        col = mix(col, tcol, ta)

    return col


def _draw_trace(tr, camera, rx, ry, cx, cy, plot, pal):
    """Plot a great-circle arc that is *always fully visible*, with an
    anti-aliased 3x3 brush for crisp, thick lines and a bright moving head.

    The whole path stays lit at a base level so traces are easy to read even
    when paused; a brighter packet head travels along it."""
    steps = 72
    head_t = tr.phase % 1.0
    color = tr.color
    a = tr.alpha
    if a <= 0.02:
        return

    # brush kernel: centre + 4 edges only (no corners -> crisp, no white halo)
    def brush(px, py, col, base):
        plot(px, py, col, base)
        e = base * 0.5
        plot(px + 1, py, col, e)
        plot(px - 1, py, col, e)
        plot(px, py + 1, col, e)
        plot(px, py - 1, col, e)

    for i in range(steps + 1):
        t = i / steps
        w = tr.point(t, camera)
        depth = w[2]
        px = int(cx + rx * w[0])
        py = int(cy - ry * w[1])

        # distance from the moving head (wraps so the packet loops)
        d = abs(t - head_t)
        d = min(d, 1 - d)

        # dim body + narrow bright moving pulse (traffic)
        base = 0.55 * a
        head_pulse = max(0.0, 1.0 - d * 10.0)
        glow = min(1.0, base + head_pulse * 0.45)

        col = color  # pure trace color (laser-like), no white outline
        # behind the globe: occlude if inside the disk silhouette, else dim
        if depth < 0:
            if w[0] * w[0] + w[1] * w[1] < 1.0:
                continue  # hidden behind the globe -- no show-through
            col = mix(col, pal.trace_far, 0.5)
            glow *= 0.4
        # the bright moving pulse is just full-glow color (no separate hot color)
        brush(px, py, col, glow)


def _line(x0, y0, x1, y1, put):
    """Bresenham; put(x,y) per cell."""
    dx = abs(x1 - x0)
    dy = abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx - dy
    while True:
        put(x0, y0)
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 > -dy:
            err -= dy
            x0 += sx
        if e2 < dx:
            err += dx
            y0 += sy