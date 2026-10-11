#!/usr/bin/env bash
# Install the Earthnet Omarchy shell plugin into ~/.config/omarchy/plugins/.
#
# Two modes:
#   ./install.sh            symlink (default) -- ideal while developing from this
#                           checkout; edits take effect immediately.
#   ./install.sh --copy     copy the plugin, so the install is self-contained and
#                           survives moving or deleting this checkout.
#
# Either way the plugin lands as ~/.config/omarchy/plugins/earthnet.globe and the
# bar widget is enabled, placed after omarchy.workspaces.
#
# This repo is a standalone checkout: the earthnet modules the Python sidecar
# imports are vendored in pylib/ (see pylib/README.md), so there is no sibling
# checkout to reach into and nothing to pip install.
set -euo pipefail

PLUGIN_ID="earthnet.globe"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
MODE="${1:-symlink}"

echo "Installing $PLUGIN_ID from $SRC ($MODE)"

rm -rf "$DEST"

if [[ "$MODE" == "--copy" ]]; then
  mkdir -p "$DEST"
  # Everything the shell needs at runtime, and nothing else: the manifest, the
  # QML sources, the sidecar, its cached geometry and the vendored earthnet
  # modules. README/demo media/install.sh stay behind.
  cp -a "$SRC/manifest.json" "$SRC"/*.qml "$SRC/earthnet-omarchy" \
        "$SRC/assets" "$SRC/pylib" "$DEST/"
  [[ -f "$SRC/LICENSE" ]] && cp -a "$SRC/LICENSE" "$DEST/"
  rm -rf "$DEST/pylib/earthnet/__pycache__"
  echo "Copied plugin + vendored earthnet modules."
else
  ln -s "$SRC" "$DEST"
  echo "Symlinked $DEST -> $SRC"
fi

chmod +x "$DEST/earthnet-omarchy" 2>/dev/null || true

# Make the shell notice and enable the widget.
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
sleep 0.5
omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || omarchy plugin enable "$PLUGIN_ID" || true

echo
echo "Done. The Earthnet globe should now be live in your bar."
echo "  - left-click  opens the full panel"
echo "  - right-click toggles live/demo"
echo "  - toggle with: omarchy-shell shell toggle $PLUGIN_ID"
echo
echo "If it does not appear, restart the shell: omarchy restart shell"
