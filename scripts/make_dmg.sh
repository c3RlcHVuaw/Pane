#!/bin/bash
# Builds a styled drag-to-Applications installer. Usage: scripts/make_dmg.sh path/to/Pane.app out.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$1"; OUT="$2"; VOL="Pane"
TMP=$(mktemp -d)
trap 'hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true

swift scripts/dmg_background.swift "$TMP/bg.png"
[ -f Resources/Pane.icns ] || ./scripts/make_icon.sh
SIZE=$(( $(du -sm "$APP" | cut -f1) + 120 ))
hdiutil create -size ${SIZE}m -fs HFS+ -volname "$VOL" -ov "$TMP/rw.dmg" >/dev/null
hdiutil attach "$TMP/rw.dmg" -readwrite -noverify -noautoopen -mountpoint "/Volumes/$VOL" >/dev/null

ditto "$APP" "/Volumes/$VOL/Pane.app"
ln -s /Applications "/Volumes/$VOL/Applications"
mkdir "/Volumes/$VOL/.background"
cp "$TMP/bg.png" "/Volumes/$VOL/.background/bg.png"
cp Resources/Pane.icns "/Volumes/$VOL/.VolumeIcon.icns"
SetFile -c icnC "/Volumes/$VOL/.VolumeIcon.icns" 2>/dev/null || true
SetFile -a C "/Volumes/$VOL" 2>/dev/null || true

# Window size, icon positions and background are stored by Finder; ask it to lay the window out.
if ! osascript <<A 2>/dev/null
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:bg.png"
    set position of item "Pane.app" of container window to {180, 190}
    set position of item "Applications" of container window to {480, 190}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
A
then
  echo "warning: Finder layout was skipped (allow Automation for Finder to get the styled window)" >&2
fi

sync
hdiutil detach "/Volumes/$VOL" >/dev/null
rm -f "$OUT"
hdiutil convert "$TMP/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
