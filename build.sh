#!/usr/bin/env bash
# Builds Clippboard.app into ./build. "./build.sh install" also copies it to ~/Applications and restarts it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Clippboard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
    -o "$APP/Contents/MacOS/Clippboard" Sources/*.swift
cp Resources/Info.plist "$APP/Contents/Info.plist"

# A stable signing identity keeps the Accessibility permission across rebuilds.
# Without the "Clippboard Signing" certificate the build falls back to an ad-hoc
# signature, and the permission must be granted again after every rebuild.
IDENTITY="Clippboard Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier local.thorsten.clippboard "$APP"
    echo "Signed with \"$IDENTITY\""
else
    codesign --force --sign - --identifier local.thorsten.clippboard "$APP"
    echo "Signed ad-hoc (no \"$IDENTITY\" certificate found, see README)"
fi
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    TARGET="$HOME/Applications/Clippboard.app"
    pkill -x Clippboard || true
    # Wait until the old instance is gone, otherwise `open` fails with error -600.
    while pgrep -x Clippboard >/dev/null; do sleep 0.2; done
    sleep 1
    mkdir -p "$HOME/Applications"
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
    open "$TARGET"
    echo "Installed and started $TARGET"
fi
