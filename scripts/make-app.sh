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
cp Sources/Tacit/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Gesture preview assets (Task 8 delivers these; graceful no-op until then — GesturePreviewView
# falls back to the constellation renderer when this directory is absent).
if [ -d Sources/Tacit/Resources/previews ]; then
    cp -R Sources/Tacit/Resources/previews "$APP/Contents/Resources/previews"
fi
# --- Code signing identity -------------------------------------------------
# WHY THIS MATTERS: TCC (macOS's Accessibility/Camera permission database) keys
# grants on the app's *designated requirement*, which is derived from the
# signing identity's certificate. Ad-hoc signing (`codesign --sign -`) has no
# certificate, so each build gets a fresh, unique cdhash — to TCC that looks
# like a brand-new app every time, and it silently drops the Accessibility
# (and Camera) grant on every rebuild. Signing with a stable identity (an
# Apple Development or Developer ID certificate) keeps the designated
# requirement constant across rebuilds, so grants persist.
#
# NOTE: switching identities (e.g. ad-hoc -> real identity, or swapping
# certificates) still requires a one-time re-grant of Accessibility (and
# possibly Camera) in System Settings > Privacy & Security, since that changes
# the designated requirement once.
if [ -n "${TACIT_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$TACIT_SIGN_IDENTITY"
else
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -E '"(Apple Development|Developer ID Application):' \
        | head -n 1 \
        | sed -E 's/^[[:space:]]*[0-9]+\) [0-9A-F]+ "(.*)"$/\1/')
fi

if [ -n "$IDENTITY" ]; then
    echo "Signing with identity: $IDENTITY"
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
    echo "WARNING: no Apple Development / Developer ID codesigning identity found." >&2
    echo "WARNING: falling back to ad-hoc signing. TCC grants (Accessibility, Camera)" >&2
    echo "WARNING: will NOT survive rebuilds — you'll need to re-grant them every time." >&2
    IDENTITY="-"
    codesign --force --sign - --entitlements /dev/null "$APP" 2>/dev/null || codesign --force --sign - "$APP"
fi

SIGN_INFO=$(codesign -dv --verbose=2 "$APP" 2>&1)
echo "$SIGN_INFO" | grep -E "Identifier|TeamIdentifier|Signature"

if [ "$IDENTITY" != "-" ] && echo "$SIGN_INFO" | grep -q "TeamIdentifier=not set"; then
    echo "ERROR: requested identity '$IDENTITY' but resulting signature has no TeamIdentifier." >&2
    exit 1
fi

echo "Built $APP"
