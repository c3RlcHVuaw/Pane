#!/bin/bash
# Downloads and unpacks the pinned CEF build into third_party/cef.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="156.0.7+g47dbc1d+chromium-156.0.8078.17"
SHA1="038a6ce70a814181f6a507d40155c81e80b328e3"
NAME="cef_binary_${VERSION}_macosarm64_minimal"
DEST="third_party/cef"
if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$VERSION" ]; then echo "CEF $VERSION already present"; exit 0; fi
mkdir -p third_party/.dl && cd third_party/.dl
[ -f "$NAME.tar.bz2" ] || curl -fL --progress-bar -o "$NAME.tar.bz2" "https://cef-builds.spotifycdn.com/${NAME//+/%2B}.tar.bz2"
echo "$SHA1  $NAME.tar.bz2" | shasum -a 1 -c -
rm -rf "$NAME"; tar xjf "$NAME.tar.bz2"
cd ../..; rm -rf "$DEST"; mv "third_party/.dl/$NAME" "$DEST"
echo "$VERSION" > "$DEST/.version"
echo "CEF ready in $DEST"
