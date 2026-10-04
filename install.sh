#!/usr/bin/env bash
# Install the Earthnet Omarchy shell plugin into ~/.config/omarchy/plugins/.
#
# Two modes:
#   ./install.sh            symlink (default) -- ideal while developing from the
#                           Earthnet checkout; edits take effect immediately.
#   ./install.sh --copy     copy the plugin plus the Python modules it needs, so
#                           the install is self-contained and survives moving or
#                           deleting the checkout.
#
# In both cases the plugin lands as ~/.config/omarchy/plugins/earthnet.globe and
# the bar widget is enabled, placed after omarchy.workspaces.
set -euo pipefail

PLUGIN_ID="earthnet.globe"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SRC/.." && pwd)"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
MODE="${1:-symlink}"

echo "Installing $PLUGIN_ID from $SRC ($MODE)"

rm -rf "$DEST"

if [[ "$MODE" == "--copy" ]]; then
  mkdir -p "$DEST"
  # Plugin sources.
  cp -a "$SRC/." "$DEST/"
  rm -rf "$DEST/tools" "$DEST/install.sh" "$DEST/.git"
  # The sidecar imports the earthnet package. Vendor it so there is no
  # dependency on the checkout or a pip install.
  mkdir -p "$DEST/pylib"
  cp -a "$REPO/earthnet" "$DEST/pylib/earthnet"
  rm -rf "$DEST/pylib/earthnet/__pycache__"
  echo "Copied plugin + vendored earthnet package."
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
