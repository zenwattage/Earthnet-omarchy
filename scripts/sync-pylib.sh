#!/usr/bin/env bash
# Re-vendor pylib/earthnet from an Earthnet checkout.
#
#   scripts/sync-pylib.sh [path-to-Earthnet]   copy (default ~/Projects/Earthnet)
#   scripts/sync-pylib.sh --check [path]       report drift, change nothing
#
# Only the modules the sidecar actually imports are copied; see pylib/README.md.
# The banner appended to __init__.py is ignored when comparing, so --check stays
# quiet on a clean tree.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HERE/pylib/earthnet"
MODULES=(__init__.py conntrack.py geo.py globe.py land.py theme.py)

CHECK=0
if [[ "${1:-}" == "--check" ]]; then
  CHECK=1
  shift
fi
SRC="${1:-$HOME/Projects/Earthnet}"
SRC_PKG="$SRC/earthnet"

if [[ ! -d "$SRC_PKG" ]]; then
  echo "error: no earthnet package at $SRC_PKG" >&2
  echo "usage: $(basename "$0") [--check] [path-to-Earthnet-checkout]" >&2
  exit 1
fi

# Compare a vendored file with its upstream original, ignoring the VENDORED COPY
# banner this script appends.
same_as_upstream() {
  python3 - "$1" "$2" <<'PY'
import pathlib, sys

def body(path):
    text = pathlib.Path(path).read_text()
    marker = text.find("# VENDORED COPY")
    if marker != -1:
        start = text.rfind("\n# ---", 0, marker)
        if start != -1:
            text = text[:start + 1]
    return text.rstrip("\n")

sys.exit(0 if body(sys.argv[1]) == body(sys.argv[2]) else 1)
PY
}

drift=0
for m in "${MODULES[@]}"; do
  if [[ ! -f "$SRC_PKG/$m" ]]; then
    echo "error: upstream is missing $m" >&2
    exit 1
  fi
  if ! same_as_upstream "$DEST/$m" "$SRC_PKG/$m"; then
    drift=$((drift + 1))
    echo "  differs: $m"
  fi
done

if (( CHECK )); then
  if (( drift )); then
    echo "$drift vendored module(s) differ from $SRC_PKG"
    exit 1
  fi
  echo "pylib/earthnet is in sync with $SRC_PKG"
  exit 0
fi

for m in "${MODULES[@]}"; do
  cp "$SRC_PKG/$m" "$DEST/$m"
  chmod 644 "$DEST/$m"
done

# Re-attach the vendoring banner that the upstream __init__.py lacks.
if ! grep -q "VENDORED COPY" "$DEST/__init__.py"; then
  cat >> "$DEST/__init__.py" <<'BANNER'

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
BANNER
fi

rm -rf "$DEST/__pycache__"
version="$(python3 - "$SRC_PKG/__init__.py" <<'PY'
import ast, pathlib, sys

tree = ast.parse(pathlib.Path(sys.argv[1]).read_text())
for node in tree.body:
    if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", "") == "__version__":
        print(node.value.value)
        break
else:
    print("unknown")
PY
)"
echo "Vendored ${#MODULES[@]} modules from $SRC_PKG (earthnet $version)"
if (( drift )); then
  echo "$drift file(s) changed -- mention the bump in the plugin README/changelog."
fi
