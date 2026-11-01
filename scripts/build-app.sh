#!/bin/bash
# Assembles GlassIsland.app from the SPM release build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/GlassIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GlassIsland "$APP/Contents/MacOS/GlassIsland"
cp Info.plist "$APP/Contents/Info.plist"

# SPM copies our Resources folder into a bundle; reuse its contents.
BUNDLE=".build/release/GlassIsland_GlassIsland.bundle"
if [ -d "$BUNDLE/Contents/Resources" ]; then
    cp -R "$BUNDLE/Contents/Resources/." "$APP/Contents/Resources/"
elif [ -d "$BUNDLE" ]; then
    cp -R "$BUNDLE/." "$APP/Contents/Resources/"
fi

codesign --force --sign - "$APP"
echo "Built $APP"
echo "Run with: open $APP"
