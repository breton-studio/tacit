#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release
APP=build/Tacit.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tacit "$APP/Contents/MacOS/Tacit"
cp Sources/Tacit/Resources/Info.plist "$APP/Contents/Info.plist"
# Gesture preview assets (Task 8 delivers these; graceful no-op until then — GesturePreviewView
# falls back to the constellation renderer when this directory is absent).
if [ -d Sources/Tacit/Resources/previews ]; then
    cp -R Sources/Tacit/Resources/previews "$APP/Contents/Resources/previews"
fi
codesign --force --sign - --entitlements /dev/null "$APP" 2>/dev/null || codesign --force --sign - "$APP"
echo "Built $APP"
