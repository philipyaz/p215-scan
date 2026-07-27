#!/bin/bash
# Regenerate Resources/AppIcon.icns (and docs/icon.png) from makeicon.swift.
set -euo pipefail
cd "$(dirname "$0")"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET" Resources ../docs

swift makeicon.swift "$ICONSET" ../docs/icon.png
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns

echo "wrote Resources/AppIcon.icns and docs/icon.png"
