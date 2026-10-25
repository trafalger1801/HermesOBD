#!/bin/zsh
# Builds "Mustang OBD Monitor.app" into ./dist (release build, ad-hoc signed for local use).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product OBDMonitor -j 1
BIN="$(swift build -c release --show-bin-path)/OBDMonitor"
APP="dist/Mustang OBD Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OBDMonitor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
