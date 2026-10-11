"""earthnet: a translucent 3D Earth globe for the terminal with live
internet-connection trace arcs. Pure stdlib, runs in Foot (or any truecolor
terminal)."""
__version__ = "0.1.0"
# ---------------------------------------------------------------------------
# VENDORED COPY -- do not edit here.
#
# This is the subset of the earthnet package that the Earthnet Omarchy plugin's
# sidecar imports, copied verbatim from https://github.com/zenwattage/Earthnet
# (canonical upstream: earthnet/conntrack.py, geo.py, globe.py, land.py,
# theme.py). The TUI-only modules (app.py, hd.py, __main__.py, _render_test.py)
# are deliberately not vendored -- they need a terminal or numpy/Pillow.
#
# Re-sync after upstream changes with:  scripts/sync-pylib.sh [path-to-earthnet]
# ---------------------------------------------------------------------------
