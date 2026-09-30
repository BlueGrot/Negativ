#!/bin/bash
# Builds Negativ.app into ./build
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Negativ.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Negativ "$APP/Contents/MacOS/Negativ"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
