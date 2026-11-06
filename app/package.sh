#!/bin/bash
# Packages Jarvis.app into build/Jarvis.dmg (drag to Applications).
# First launch opens the one-time setup window, which installs everything else.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
STAGE=build/dmg
rm -rf "$STAGE" build/Jarvis.dmg
mkdir -p "$STAGE"
cp -R build/Jarvis.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Jarvis" -srcfolder "$STAGE" -ov -format UDZO build/Jarvis.dmg >/dev/null
rm -rf "$STAGE"
echo "Packaged $(pwd)/build/Jarvis.dmg"
