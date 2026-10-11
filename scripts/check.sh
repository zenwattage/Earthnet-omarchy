#!/usr/bin/env bash
# The Omarchy development guide's validation step, in one command:
#
#   scripts/check.sh
#
# Runs the manifest/schema check the shell itself enforces, then lints the QML
# against the installed shell imports. Both must exit clean before publishing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"

echo "== omarchy plugin validate =="
omarchy plugin validate "$HERE"

echo "== qmllint -I $OMARCHY_PATH/shell =="
qmllint -I "$OMARCHY_PATH/shell" \
  "$HERE/BarWidget.qml" \
  "$HERE/Panel.qml" \
  "$HERE/Globe.qml" \
  "$HERE/PythonSidecar.qml"

echo
echo "OK: manifest and QML follow the Omarchy plugin contract."
echo "Remaining manual checks from the guide: click, Escape, summon/hide,"
echo "disable, re-enable, shell restart, and removal."
