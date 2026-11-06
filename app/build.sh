#!/bin/bash
# Builds Jarvis.app into ./build and signs it.
#
# A stable signing identity lets macOS remember Microphone / Speech / Automation permissions across
# rebuilds. Use a local self-signed certificate named "Jarvis Local Signing" (Keychain Access →
# Certificate Assistant → Create a Certificate…, Certificate Type: Code Signing). Without it the
# app is ad-hoc signed and macOS asks for permissions again after each rebuild.
#
# Don't sign with an Apple Development certificate that may be revoked: macOS then treats the app
# as malware and moves it to the Trash.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Jarvis.app
rm -rf "$APP" build/VoiceBrowser.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VoiceBrowser "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp ../tts/server.py "$APP/Contents/Resources/"

# App icon, rendered from code.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift tools/make_icon.swift build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

SIGN_ID="${SIGN_ID:-Jarvis Local Signing}"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  codesign --force --sign "$SIGN_ID" "$APP"
else
  echo "note: no \"$SIGN_ID\" certificate; ad-hoc signing (macOS will re-ask for permissions after rebuilds)"
  codesign --force --sign - "$APP"
fi
echo "Built $(pwd)/$APP"
