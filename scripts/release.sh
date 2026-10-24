#!/bin/bash
# Cuts a release: bumps the build number, builds, zips, writes the update feed and the DMG into dist/.
# A running Pane watching dist/latest.json shows its "Update" button within seconds.
# Usage: scripts/release.sh "What changed"   (add PUBLISH=0 to skip the upload)
set -euo pipefail
cd "$(dirname "$0")/.."
NOTES="${1:-Improvements and fixes.}"
VERSION=$(cat VERSION)
BUILD=$(( $(cat BUILD_NUMBER) + 1 ))
echo "$BUILD" > BUILD_NUMBER

# Release builds go to build/release so a Pane you are running from build/ is left alone (it updates itself).
export PANE_APP_OUT="$PWD/build/release/Pane.app"
./scripts/build.sh release
if [ "${SMOKE:-1}" = "1" ]; then ./scripts/smoke_test.sh "$PANE_APP_OUT" || { echo "Smoke test failed — not publishing. (SMOKE=0 to skip)"; exit 1; }; fi
mkdir -p dist
ZIP="Pane-$VERSION-$BUILD.zip"
rm -f "dist/$ZIP"
ditto -c -k --keepParent "$PANE_APP_OUT" "dist/$ZIP"
SHA=$(shasum -a 256 "dist/$ZIP" | cut -d' ' -f1)

# Write the feed last and atomically, so the app never sees a half-published release.
python3 -I - "$VERSION" "$BUILD" "$ZIP" "$SHA" "$NOTES" <<'PY' > dist/latest.json.tmp
import json, sys
v, b, z, s, n = sys.argv[1:6]
print(json.dumps({"version": v, "build": int(b), "url": z, "sha256": s, "notes": n}, indent=2, ensure_ascii=False))
PY
mv dist/latest.json.tmp dist/latest.json

./scripts/make_dmg.sh "$PANE_APP_OUT" "dist/Pane-$VERSION.dmg" || echo "warning: DMG step failed" >&2

# Keep only the three newest update archives.
ls -t dist/Pane-*.zip 2>/dev/null | tail -n +4 | xargs -I{} rm -f {}
echo "Built $VERSION (build $BUILD): dist/$ZIP"
[ "${PUBLISH:-1}" = "1" ] && ./scripts/publish.sh
