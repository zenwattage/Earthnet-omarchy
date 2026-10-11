"""Theme integration: derive earthnet's palette from the active Omarchy theme.

Reads the current theme's ``colors.toml`` (preferred) or ``foot.ini`` from
``~/.local/state/omarchy/current/theme/`` and maps it onto a globe ``Palette``.
Falls back to the built-in default palette when no theme is found, so the app
still works outside Omarchy.

Pure stdlib (tomllib + configparser).
"""
from __future__ import annotations

import configparser
import os
import tomllib
from pathlib import Path

from .globe import Palette, darken, hex_rgb, mix

OMARCHY_THEME_DIR = Path.home() / ".local/state/omarchy/current/theme"


def _all_colors(d: dict) -> list[tuple]:
    """16-entry palette as (r,g,b) tuples from a color0..color15 dict."""
    out = []
    for i in range(16):
        v = d.get(f"color{i}")
        out.append(hex_rgb(v) if v else (0, 0, 0))
    return out


def _pick(colors: list[tuple], score, fallback):
    best = None
    best_s = -1e9
    for c in colors:
        s = score(c)
        if s > best_s:
            best_s = s
            best = c
    return best if best is not None and best_s > 0 else fallback


def _greenest(cs):
    return _pick(cs, lambda c: (c[1] - c[0]) + (c[1] - c[2]), (90, 170, 100))


def _cyanest(cs):
    return _pick(cs, lambda c: (c[2] - c[0]), (90, 220, 255))


def _orangest(cs):
    return _pick(cs, lambda c: (c[0] + c[1]) - 2 * c[2], (255, 200, 90))


def _magentast(cs):
    return _pick(cs, lambda c: (c[0] + c[2]) - 2 * c[1], (220, 130, 200))


def _from_colors_toml(path: Path) -> dict | None:
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except Exception:
        return None


def _from_foot_ini(path: Path) -> dict | None:
    try:
        cp = configparser.ConfigParser()
        cp.read(path)
    except Exception:
        return None
    # foot uses [colors] and/or [colors-dark]/[colors-light]
    sec = None
    for name in ("colors-dark", "colors-light", "colors"):
        if cp.has_section(name):
            sec = cp[name]
            break
    if sec is None:
        return None
    d = {}
    for k in ("foreground", "background", "cursor"):
        if k in sec:
            # foot cursor is "bg fg"; take the first for cursor-bg, but we want
            # the visible cursor color -> second token
            parts = sec[k].split()
            d[k] = parts[-1]
    for i in range(8):
        if f"regular{i}" in sec:
            d[f"color{i}"] = sec[f"regular{i}"]
        if f"bright{i}" in sec:
            d[f"color{i + 8}"] = sec[f"bright{i}"]
    # accent: foot has none; derive from regular4 if present
    if "regular4" in sec:
        d["accent"] = sec["regular4"]
    return d


def load_theme_colors() -> dict | None:
    if not OMARCHY_THEME_DIR.exists():
        return None
    d = _from_colors_toml(OMARCHY_THEME_DIR / "colors.toml")
    if d is None:
        d = _from_foot_ini(OMARCHY_THEME_DIR / "foot.ini")
    return d


def build_palette(d: dict | None) -> Palette:
    if not d:
        return Palette()
    try:
        bg = hex_rgb(d["background"])
        fg = hex_rgb(d["foreground"])
    except Exception:
        return Palette()
    accent = hex_rgb(d["accent"]) if "accent" in d else fg
    cursor = hex_rgb(d["cursor"]) if "cursor" in d else None
    cs = _all_colors(d)

    land = _greenest(cs)
    trace = _cyanest(cs)
    udp_c = _orangest(cs)
    icmp_c = _magentast(cs)
    hot = cursor if cursor is not None else udp_c

    # ocean: a deep, slightly-accented tint of the background
    ocean = darken(mix(bg, accent, 0.18), 0.92)

    return Palette(
        space=bg,
        ocean=ocean,
        land=darken(land, 0.85),
        land_hi=mix(land, fg, 0.25),
        grid=mix(fg, trace, 0.35),
        ring=mix(accent, fg, 0.2),
        star=darken(fg, 0.45),
        trace=trace,
        trace_hot=hot,
        trace_far=darken(trace, 0.32),
        proto_tcp=trace,
        proto_udp=udp_c,
        proto_icmp=icmp_c,
        hud_dim=darken(fg, 0.55),
        hud_bright=fg,
        hud_accent=accent,
    )


def load_palette() -> Palette:
    return build_palette(load_theme_colors())


def load_theme_alpha() -> float:
    """Return the terminal background alpha the active theme calls for, in
    0..1 (1 = fully opaque). Reads ``background-alpha`` from the theme's
    shell.toml, then foot's ``[colors] alpha`` if present. Defaults to 1.0."""
    alpha = 1.0
    # Omarchy shell.toml
    p = OMARCHY_THEME_DIR / "shell.toml"
    try:
        with open(p, "rb") as f:
            d = tomllib.load(f)
        if "background-alpha" in d:
            alpha = float(d["background-alpha"])
    except Exception:
        pass
    # foot.ini [colors] alpha (overrides if set)
    try:
        cp = configparser.ConfigParser()
        cp.read(Path.home() / ".config/foot/foot.ini")
        for sec in ("colors", "colors-dark", "colors-light"):
            if cp.has_option(sec, "alpha"):
                alpha = float(cp.get(sec, "alpha"))
                break
    except Exception:
        pass
    return max(0.0, min(1.0, alpha))


if __name__ == "__main__":
    d = load_theme_colors()
    print("theme dir:", OMARCHY_THEME_DIR)
    print("theme colors:", d)
    p = build_palette(d)
    for f in ("space", "ocean", "land", "grid", "ring", "star",
              "trace", "trace_hot", "proto_tcp", "proto_udp", "proto_icmp",
              "hud_bright", "hud_accent"):
        v = getattr(p, f)
        print(f"  {f:12} #{v[0]:02X}{v[1]:02X}{v[2]:02X}")