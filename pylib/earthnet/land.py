"""Land-mask acquisition and rasterization.

Downloads Natural Earth 110m land GeoJSON once, rasterizes it into an
equiangular land/sea grid (cached to disk so later runs are instant), and falls
back to a graticule-only empty mask when offline.

Pure stdlib (urllib + json).
"""
from __future__ import annotations

import json
import os
import urllib.request
from pathlib import Path

from .globe import LandMask, empty_landmask

CACHE_DIR = Path(os.environ.get(
    "XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "earthnet"

MASK_CACHE = CACHE_DIR / "landmask.bin"
GEOJSON_CACHE = CACHE_DIR / "ne_110m_land.json"

MIRRORS = [
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/"
    "master/geojson/ne_110m_land.json",
    "https://raw.githubusercontent.com/martynafford/natural-earth-geojson/"
    "master/110m/physical/ne_110m_land.json",
]

DEFAULT_NLAT = 720
DEFAULT_NLON = 1440


def _download(url: str, dest: Path, timeout: float = 30.0) -> bool:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "earthnet/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read()
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        return True
    except Exception as e:
        print(f"[land] download failed: {url}: {e}", flush=True)
        return False


def _fetch_geojson() -> dict | None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    if GEOJSON_CACHE.exists() and GEOJSON_CACHE.stat().st_size > 1000:
        try:
            return json.loads(GEOJSON_CACHE.read_text())
        except Exception:
            pass
    for url in MIRRORS:
        if _download(url, GEOJSON_CACHE):
            try:
                return json.loads(GEOJSON_CACHE.read_text())
            except Exception as e:
                print(f"[land] cached geojson unreadable: {e}", flush=True)
    return None


def _rings_from_geojson(gj: dict) -> list[list[tuple[float, float]]]:
    """Return list of rings, each ring a list of (lon, lat). Handles
    FeatureCollection, Feature, and GeometryCollection."""
    rings: list[list[tuple[float, float]]] = []

    def add_geom(geom):
        if geom is None:
            return
        t = geom.get("type")
        c = geom.get("coordinates")
        if t == "Polygon":
            for r in c:
                rings.append([(p[0], p[1]) for p in r])
        elif t == "MultiPolygon":
            for poly in c:
                for r in poly:
                    rings.append([(p[0], p[1]) for p in r])

    feats = []
    if gj.get("type") == "FeatureCollection":
        feats = gj.get("features", [])
    elif gj.get("type") == "Feature":
        feats = [gj]
    elif "coordinates" in gj:
        add_geom(gj)
    for f in feats:
        add_geom(f.get("geometry"))
    return rings


def _fill_binary(edges_all, n_lat, n_lon, data):
    """Scanline even-odd fill of polygon rings into a binary bytearray."""
    for li in range(n_lat):
        y = 90.0 - (li + 0.5) * 180.0 / n_lat
        spans: list[float] = []
        for edges in edges_all:
            xs = []
            for la_a, lo_a, dlon, la_b in edges:
                if la_a <= y < la_b:
                    xs.append(lo_a + (y - la_a) * dlon)
            if not xs:
                continue
            xs.sort()
            for k in range(0, len(xs) - 1, 2):
                spans.append((xs[k], xs[k + 1]))
        if not spans:
            continue
        spans.sort()
        merged = []
        cs, ce = spans[0]
        for s, e in spans[1:]:
            if s <= ce:
                if e > ce:
                    ce = e
            else:
                merged.append((cs, ce))
                cs, ce = s, e
        merged.append((cs, ce))
        row_off = li * n_lon
        for s, e in merged:
            if e < -180 or s > 180:
                continue
            s = max(-180.0, s)
            e = min(180.0, e)
            j0 = int((s + 180.0) / 360.0 * n_lon)
            j1 = int((e + 180.0) / 360.0 * n_lon)
            if j1 < j0:
                j1 = j0
            if j0 < 0:
                j0 = 0
            if j1 >= n_lon:
                j1 = n_lon - 1
            for j in range(j0, j1 + 1):
                data[row_off + j] = 1


def rasterize(rings, n_lat: int, n_lon: int, ss: int = 4) -> LandMask:
    """Scanline-rasterize rings, supersampled ``ss``x, then downsample to a
    0..255 land-coverage mask (anti-aliased coastlines). lat row 0 = +90."""
    # Precompute per-ring edge lists as (lat0, lon0, dlon_dlat, lat1).
    edges_all: list[list[tuple[float, float, float, float]]] = []
    for ring in rings:
        edges = []
        n = len(ring)
        for i in range(n):
            lon0, lat0 = ring[i]
            lon1, lat1 = ring[(i + 1) % n]
            if lat0 == lat1:
                continue
            if lat0 < lat1:
                lo_a, la_a, lo_b, la_b = lon0, lat0, lon1, lat1
            else:
                lo_a, la_a, lo_b, la_b = lon1, lat1, lon0, lat0
            edges.append((la_a, lo_a, (lo_b - lo_a) / (la_b - la_a), la_b))
        edges_all.append(edges)

    hi_lat, hi_lon = n_lat * ss, n_lon * ss
    hi = bytearray(hi_lat * hi_lon)
    _fill_binary(edges_all, hi_lat, hi_lon, hi)

    # downsample: average ss*ss block -> coverage 0..255
    out = empty_landmask(n_lat, n_lon)
    data = out.data
    inv_ss2 = 255.0 / (ss * ss)
    for li in range(n_lat):
        row_off = li * n_lon
        hli = li * ss
        for lo in range(n_lon):
            hlo = lo * ss
            s = 0
            for dy in range(ss):
                base = (hli + dy) * hi_lon + hlo
                for dx in range(ss):
                    s += hi[base + dx]
            data[row_off + lo] = int(s * inv_ss2 + 0.5)
    return out


def load_landmask(n_lat: int = DEFAULT_NLAT, n_lon: int = DEFAULT_NLON,
                  force_refresh: bool = False, ss: int = 4) -> LandMask:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    sig = MASK_CACHE.with_suffix(f".{n_lat}x{n_lon}.sig")
    sig_expect = f"{n_lat}x{n_lon}-cov{ss}"
    if not force_refresh and MASK_CACHE.exists() and sig.exists():
        try:
            if sig.read_text().strip() == sig_expect:
                data = MASK_CACHE.read_bytes()
                if len(data) == n_lat * n_lon:
                    return LandMask(n_lat, n_lon, bytearray(data))
        except Exception:
            pass

    gj = _fetch_geojson()
    if gj is None:
        print("[land] no land data available; rendering graticule-only globe.",
              flush=True)
        return empty_landmask(n_lat, n_lon)
    rings = _rings_from_geojson(gj)
    print(f"[land] rasterizing {len(rings)} rings ({ss}x supersample) "
          f"into {n_lat}x{n_lon} coverage mask...", flush=True)
    mask = rasterize(rings, n_lat, n_lon, ss)
    MASK_CACHE.write_bytes(bytes(mask.data))
    sig.write_text(sig_expect)
    print(f"[land] cached coverage landmask -> {MASK_CACHE}", flush=True)
    return mask


if __name__ == "__main__":
    m = load_landmask()
    cov = m.data
    land = sum(1 for v in cov if v > 127)
    partial = sum(1 for v in cov if 0 < v <= 250)
    print(f"land cells: {land} / {len(cov)} "
          f"({100.0 * land / len(cov):.1f}%), anti-aliased edges: {partial}")