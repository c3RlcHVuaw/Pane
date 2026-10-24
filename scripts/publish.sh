#!/bin/bash
# Uploads dist/ to the update server: archive first, feed last, so clients never see a half-published release.
# Set PUBLISH_DMG=1 to also refresh the installer (Pane.dmg). Needs the SSH key from DEPLOY.local.md.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${PANE_SERVER:-root@2.26.86.13}"
KEY="${PANE_SSH_KEY:-$HOME/.ssh/clip_tracker_play2go}"
DIR=/opt/pane-updates
URL="https://pane.2-26-86-13.sslip.io"
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 "$HOST")

upload() { # local remote-name   (one connection, written under a temp name, then renamed)
  "${SSH[@]}" "cat > '$DIR/$2.part' && mv '$DIR/$2.part' '$DIR/$2'" < "$1"
}

if [ "${ONLY_DMG:-0}" = "1" ]; then
  echo "Uploading installer…"
  upload "dist/Pane-$(cat VERSION).dmg" "Pane.dmg"
  echo "Installer: $URL/Pane.dmg"
  exit 0
fi
ZIP=$(python3 -I -c 'import json;print(json.load(open("dist/latest.json"))["url"])')
echo "Uploading $ZIP ($(du -h "dist/$ZIP" | cut -f1))…"
upload "dist/$ZIP" "$ZIP"
if [ "${PUBLISH_DMG:-0}" = "1" ]; then
  echo "Uploading installer…"
  upload "dist/Pane-$(cat VERSION).dmg" "Pane.dmg"
fi
[ -f dist/releases.json ] && upload dist/releases.json releases.json
upload dist/latest.json latest.json
"${SSH[@]}" "cd '$DIR' && ls -t Pane-*.zip | tail -n +3 | xargs -r rm -f"

# Make sure what the clients will fetch is really what we meant to publish.
REMOTE_SHA=$(curl -fsS "$URL/latest.json" | python3 -I -c 'import json,sys;print(json.load(sys.stdin)["sha256"])')
LOCAL_SHA=$(python3 -I -c 'import json;print(json.load(open("dist/latest.json"))["sha256"])')
[ "$REMOTE_SHA" = "$LOCAL_SHA" ] || { echo "Published feed does not match the local one!" >&2; exit 1; }
echo "Published: $URL/latest.json (installer: $URL/Pane.dmg)"
