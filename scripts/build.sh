#!/bin/bash
# Builds Pane.app into build/. Usage: scripts/build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
VERSION=$(cat VERSION)
BUILD=$(cat BUILD_NUMBER)
# Where the running app looks for updates. Override with PANE_UPDATE_FEED=file://$PWD/dist/latest.json for a local loop.
FEED="${PANE_UPDATE_FEED:-https://pane.2-26-86-13.sslip.io/latest.json}"
[ -d third_party/cef/Release ] || ./scripts/fetch_cef.sh
swift build -c "$CONFIG"
BIN=".build/$CONFIG"
APP="${PANE_APP_OUT:-build/Pane.app}"
FW="$APP/Contents/Frameworks"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$FW"

plist() { # name bundle-id executable extra-keys
cat <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$1</string>
<key>CFBundleDisplayName</key><string>$1</string>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>$3</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
$4
</dict></plist>
P
}

plist "Pane" "com.pane.browser" "Pane" "<key>NSPrincipalClass</key><string>PCApplication</string>
<key>CFBundleIconFile</key><string>Pane</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
<key>PaneUpdateFeed</key><string>$FEED</string>
<key>NSCameraUsageDescription</key><string>Web pages can ask to use the camera.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Web pages can ask for your location.</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Web address</string><key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array></dict></array>
<key>CFBundleDocumentTypes</key><array>
<dict><key>CFBundleTypeName</key><string>HTML document</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSItemContentTypes</key><array><string>public.html</string><string>public.xhtml</string></array></dict>
<dict><key>CFBundleTypeName</key><string>PDF document</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array></dict>
</array>
<key>NSMicrophoneUsageDescription</key><string>Pane uses the microphone for dictation in the assistant, and when a web page asks to.</string><key>NSSpeechRecognitionUsageDescription</key><string>Pane turns your speech into text for the assistant.</string><key>NSBluetoothAlwaysUsageDescription</key><string>Websites can use your phone or a security key over Bluetooth to sign you in (for example with a passkey).</string><key>NSBluetoothPeripheralUsageDescription</key><string>Websites can use your phone or a security key over Bluetooth to sign you in (for example with a passkey).</string><key>NSLocalNetworkUsageDescription</key><string>Web pages can talk to devices on your local network, such as calls and printers.</string>" > "$APP/Contents/Info.plist"
cp "$BIN/Pane" "$APP/Contents/MacOS/Pane"
mkdir -p "$APP/Contents/Resources"
[ -f Resources/Pane.icns ] || ./scripts/make_icon.sh
cp Resources/Pane.icns "$APP/Contents/Resources/Pane.icns"
# Translations: scripts/strings_ru.py is the source; this writes Resources/ru.lproj and copies every .lproj in.
python3 -I scripts/strings_ru.py write >/dev/null
for l in Resources/*.lproj; do cp -R "$l" "$APP/Contents/Resources/"; done
cp -R "third_party/cef/Release/Chromium Embedded Framework.framework" "$FW/"

for variant in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  name="Pane Helper$variant"
  suffix=$(echo "$variant" | tr -d ' ()')
  id="com.pane.browser.helper${suffix:+.$suffix}"
  h="$FW/$name.app/Contents"
  mkdir -p "$h/MacOS"
  plist "$name" "$id" "$name" "<key>LSUIElement</key><true/>" > "$h/Info.plist"
  cp "$BIN/PaneHelper" "$h/MacOS/$name"
done

# A stable signing identity keeps the app's "designated requirement" the same from build to build, so the Keychain
# stops asking for the password after every update. Without one we fall back to ad-hoc signing.
SIGN="${PANE_SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | grep -m1 "Apple Development" | awk '{print $2}')}"
codesign --force --deep --sign "${SIGN:--}" "$APP" 2>&1 | tail -1 || true
echo "Built $APP ($VERSION build $BUILD)"
