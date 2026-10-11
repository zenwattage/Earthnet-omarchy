#!/usr/bin/env bash
# Install / update the Earthnet Omarchy shell plugin in ~/.config/omarchy/plugins/.
#
#   ./install.sh            copy (default) -- the guide-compliant mode. The plugin
#                           lands as a real directory with no symlinks anywhere in
#                           it, and survives moving or deleting this checkout.
#   ./install.sh --link     symlink this checkout in place instead. Handy while
#                           developing (edits are live immediately), but the
#                           installed folder is then a symlink and
#                           `omarchy plugin validate` refuses it.
#
# Either way the plugin lands as ~/.config/omarchy/plugins/earthnet.globe and the
# bar widget is enabled, placed after omarchy.workspaces. The manifest and the
# QML are validated first, as the development guide prescribes.
#
# This repo is a standalone checkout: the earthnet modules the Python sidecar
# imports are vendored in pylib/ (see pylib/README.md), so there is no sibling
# checkout to reach into and nothing to pip install.
#
# Marketplace users do not need this script at all:
#   omarchy plugin add https://github.com/zenwattage/Earthnet-omarchy.git --enable
set -euo pipefail

PLUGIN_ID="earthnet.globe"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
MODE="${1:-copy}"

case "$MODE" in
--copy | copy) MODE=copy ;;
--link | --symlink | symlink) MODE=link ;;
*)
  echo "usage: $0 [--copy|--link]" >&2
  exit 2
  ;;
esac

# Validate before installing. A manifest the shell would reject should fail here
# with a readable message, not silently in the bar.
if command -v omarchy >/dev/null 2>&1; then
  echo "Validating manifest..."
  omarchy plugin validate "$SRC"
  if command -v qmllint >/dev/null 2>&1; then
    echo "Linting QML..."
    qmllint -I "${OMARCHY_PATH:-/usr/share/omarchy}/shell" "$SRC"/*.qml
  fi
else
  echo "note: omarchy not on PATH; skipping validation" >&2
fi

echo "Installing $PLUGIN_ID from $SRC ($MODE)"
rm -rf "$DEST"

if [[ $MODE == copy ]]; then
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
  echo "note: symlinked installs fail 'omarchy plugin validate'; use --copy to publish." >&2
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
