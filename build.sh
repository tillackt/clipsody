#!/usr/bin/env bash
# Builds Clippboard.app (universal: Apple Silicon + Intel) into ./build.
#   ./build.sh           build the app bundle
#   ./build.sh test      run the unit tests
#   ./build.sh install   run the tests, build, copy to ~/Applications and restart
#   ./build.sh release   run the tests and build; fails without the signing certificate
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
if [[ "${1:-}" == "install" || "${1:-}" == "release" ]]; then
    # Never install or ship a build whose tests fail.
    swift test
fi

swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Clippboard" "$APP/Contents/MacOS/Clippboard"
# Local symbols are not needed at runtime and only enlarge the download.
strip -x "$APP/Contents/MacOS/Clippboard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
# Build number = commit count, plus the commit itself; "+" marks uncommitted changes.
# Outside a git checkout (e.g. a source download) there is no history to count.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
COMMIT="$( (git rev-parse --short HEAD 2>/dev/null || echo unknown); git diff --quiet HEAD 2>/dev/null || echo +)"
COMMIT="${COMMIT//$'\n'/}"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -replace ClippboardCommit -string "$COMMIT" "$APP/Contents/Info.plist"

# Sandboxed XPC service that decodes clipboard images and reads screenshots (see README).
DECODER_ID="$BUNDLE_ID.decoder"
XPC="$APP/Contents/XPCServices/ClippboardDecoder.xpc"
mkdir -p "$XPC/Contents/MacOS"
cp "$BIN_DIR/ClippboardDecoder" "$XPC/Contents/MacOS/ClippboardDecoder"
strip -x "$XPC/Contents/MacOS/ClippboardDecoder"
cp Resources/ClippboardDecoder-Info.plist "$XPC/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$DECODER_ID" "$XPC/Contents/Info.plist"
# Same version as the app, so crash reports of the service match a build.
plutil -replace CFBundleShortVersionString -string "$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)" \
    "$XPC/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$XPC/Contents/Info.plist"

# Hardened runtime: no code injection (DYLD_INSERT_LIBRARIES etc.) into a process that holds
# the Accessibility permission. A stable signing identity keeps that permission across rebuilds.
# Without the "Clippboard Signing" certificate the build falls back to an ad-hoc
# signature, and the permission must be granted again after every rebuild.
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    SIGN_AS="$IDENTITY"
else
    if [[ "${1:-}" == "release" ]]; then
        # Recipients keep their Accessibility permission across updates only with the same certificate.
        echo "Release builds need the \"$IDENTITY\" certificate; none found" >&2
        exit 1
    fi
    SIGN_AS="-"
    echo "No \"$IDENTITY\" certificate found, signing ad-hoc (see README)"
fi

# sign <path> <identifier> [entitlements]
sign() {
    local entitlements=()
    if [[ -n "${3:-}" ]]; then entitlements=(--entitlements "$3"); fi
    # ${a[@]+...}: macOS ships bash 3.2, where an empty array is "unbound" under set -u.
    codesign --force --options runtime --sign "$SIGN_AS" --identifier "$2" ${entitlements[@]+"${entitlements[@]}"} "$1"
}

# Inside out: the embedded service first, then the app that seals it.
sign "$XPC" "$DECODER_ID" Resources/ClippboardDecoder.entitlements
sign "$APP" "$BUNDLE_ID"
codesign --verify --strict --deep "$APP"
echo "Built and verified $APP (signed as \"$SIGN_AS\")"

if [[ "${1:-}" == "install" ]]; then
    TARGET="$HOME/Applications/Clippboard.app"
    pkill -x Clippboard || true
    # Wait until the old instance is gone (at most 10 s), otherwise `open` fails with error -600.
    for _ in $(seq 50); do
        pgrep -x Clippboard >/dev/null || break
        sleep 0.2
    done
    if pgrep -x Clippboard >/dev/null; then
        echo "Clippboard did not quit; install aborted" >&2
        exit 1
    fi
    # LaunchServices needs a moment after the process is gone.
    sleep 1
    mkdir -p "$HOME/Applications"
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
    open "$TARGET"
    echo "Installed and started $TARGET"
fi
