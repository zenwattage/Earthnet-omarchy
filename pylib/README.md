# pylib/ — vendored earthnet modules

The Python sidecar (`earthnet-omarchy`) does the data half of this plugin. It
uses the terminal app's `earthnet` package for connection capture, GeoIP, land
geometry and theme parsing, so a copy of those modules is vendored here instead
of pulling in the app as a dependency.

## What's here

`pylib/earthnet/` — copied verbatim from
[zenwattage/Earthnet](https://github.com/zenwattage/Earthnet):

| module | used for |
|--------|----------|
| `conntrack.py` | flow capture (`conntrack -L` → `/proc/net/nf_conntrack` → `ss`) |
| `geo.py` | endpoint resolution: ip-api.com or a GeoLite2 `.mmdb`, plus its MMDB reader |
| `land.py` | Natural Earth coastline acquisition and cache |
| `theme.py` | Omarchy theme → palette |
| `globe.py` | shared geometry helpers (`land.py` and `theme.py` import it) |

All five are pure standard library. The TUI-only modules (`app.py`, `hd.py`,
`__main__.py`, `_render_test.py`) are deliberately **not** vendored — they need a
terminal or numpy/Pillow.

The sidecar puts `pylib/` first on `sys.path`, so this copy always wins over an
`earthnet` that happens to be installed in site-packages. That keeps the
plugin's behaviour pinned to the version it shipped with.

## Re-syncing after an upstream change

```bash
scripts/sync-pylib.sh                       # from ~/Projects/Earthnet (default)
scripts/sync-pylib.sh /path/to/Earthnet     # or an explicit checkout
EARTHNET_PYLIB=/path/to/Earthnet earthnet-omarchy   # or just test against one
```

The script copies the modules, refuses to sync if `--check` finds a drift, and
prints the upstream version it copied.
