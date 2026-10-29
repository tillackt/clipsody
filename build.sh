#!/usr/bin/env bash
# Builds Clippboard.app (universal: Apple Silicon + Intel) into ./build.
#   ./build.sh           build the app bundle
#   ./build.sh test      run the unit tests
#   ./build.sh install   build, copy to ~/Applications and restart
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="local.thorsten.clippboard"
IDENTITY="Clippboard Signing"
APP="build/Clippboard.app"
ARCHS=(--arch arm64 --arch x86_64)

if [[ "${1:-}" == "test" ]]; then
    swift test
    exit
fi

swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Clippboard" "$APP/Contents/MacOS/Clippboard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"

# Hardened runtime: no code injection (DYLD_INSERT_LIBRARIES etc.) into a process that holds
# the Accessibility permission. A stable signing identity keeps that permission across rebuilds.
# Without the "Clippboard Signing" certificate the build falls back to an ad-hoc
# signature, and the permission must be granted again after every rebuild.
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --options runtime --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
    echo "Signed with \"$IDENTITY\""
else
    codesign --force --options runtime --sign - --identifier "$BUNDLE_ID" "$APP"
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
