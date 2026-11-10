#!/bin/sh
# Build Release, install to /Applications, relaunch.
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null 2>&1
xcodebuild -project Undertow.xcodeproj -scheme Undertow -configuration Release -derivedDataPath build/dd build 2>&1 | grep -E "error|BUILD" | sed 's|.*/Sources/|Sources/|' | sort -u
pkill -x Undertow 2>/dev/null || true
sleep 1
rm -rf /Applications/Undertow.app
cp -R build/dd/Build/Products/Release/Undertow.app /Applications/
open /Applications/Undertow.app
