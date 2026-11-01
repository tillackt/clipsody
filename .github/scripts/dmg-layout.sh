#!/usr/bin/env bash
# Records how Finder shows the disk image window (size, background, icon positions) in
# Resources/dmg/DS_Store, which ./build.sh release copies into every image. Finder alone writes this
# file, so the layout is made once in a scratch image and kept; run again only after changing the
# window or the background (macOS asks once for permission to control Finder):
#   .github/scripts/dmg-layout.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

VOLUME="Clipsody"
if [[ -e "/Volumes/$VOLUME" ]]; then
    echo "/Volumes/$VOLUME exists; eject it first" >&2
    exit 1
fi
WORK="$(mktemp -d)"
# The scratch image is deleted only once it is no longer mounted.
cleanup() {
    if [[ -e "/Volumes/$VOLUME" ]] && ! hdiutil detach -quiet "/Volumes/$VOLUME"; then
        echo "/Volumes/$VOLUME is still mounted; left $WORK in place" >&2
        return
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# Same names as in the real image; the positions are stored per name.
mkdir -p "$WORK/src/Clipsody.app" "$WORK/src/.background"
ln -s /Applications "$WORK/src/Applications"
cp Resources/dmg/background.png "$WORK/src/.background/background.png"
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$WORK/src" -fs HFS+ -format UDRW "$WORK/layout.dmg"
hdiutil attach -quiet -noautoopen "$WORK/layout.dmg"

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- 600 × 380 points of content, plus the title bar.
        set the bounds of container window to {200, 120, 800, 528}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Clipsody.app" of container window to {150, 175}
        set position of item "Applications" of container window to {450, 175}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Finder writes .DS_Store when the window closes.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "/Volumes/$VOLUME/.DS_Store" ]] && break
    sleep 0.5
done
cp "/Volumes/$VOLUME/.DS_Store" Resources/dmg/DS_Store
echo "wrote Resources/dmg/DS_Store"
