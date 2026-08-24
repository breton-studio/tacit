#!/bin/bash
# Generates Sources/Tacit/Resources/AppIcon.icns from code: background #111111, Lucide `hand`
# glyph in #f9f9f9, reusing the SVG-path interpreter and `hand` path data already transcribed in
# Sources/Tacit/LucideGlyphs.swift (see scripts/make-icon/main.swift for the reuse strategy).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

BIN="$WORKDIR/make-icon"
ICONSET="$WORKDIR/AppIcon.iconset"
MASTER="${TACIT_ICON_MASTER_OUT:-$WORKDIR/AppIcon-1024.png}"

echo "Compiling icon generator..."
swiftc \
    -O \
    Sources/Tacit/LucideGlyphs.swift \
    scripts/make-icon/main.swift \
    -o "$BIN"

echo "Rendering icon artwork..."
"$BIN" "$MASTER" "$ICONSET"

echo "Building AppIcon.icns..."
mkdir -p Sources/Tacit/Resources
iconutil -c icns "$ICONSET" -o Sources/Tacit/Resources/AppIcon.icns

echo "Wrote Sources/Tacit/Resources/AppIcon.icns"
echo "Master PNG: $MASTER"
