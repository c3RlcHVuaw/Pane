#!/bin/bash
# Builds Resources/Pane.icns from scripts/make_icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d); SET="$TMP/Pane.iconset"; mkdir -p "$SET"
swift scripts/make_icon.swift "$TMP/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/Pane.icns
cp "$TMP/icon.png" Resources/icon-1024.png
rm -rf "$TMP"; echo "Resources/Pane.icns ready"
