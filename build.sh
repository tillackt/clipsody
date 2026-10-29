#!/usr/bin/env bash
# Builds Clipsody.app (universal: Apple Silicon + Intel) into ./build.
#   ./build.sh           build the app bundle
#   ./build.sh test      run the unit tests
#   ./build.sh install   run the tests, build, copy to /Applications and restart
#   ./build.sh release   run the tests and build build/Clipsody.dmg with checksums; needs the signing certificate and a clean tree
#   ./build.sh strings   add new texts from the code to Resources/Localizable.xcstrings
#   ./build.sh check-strings  fail if code and Resources/Localizable.xcstrings disagree (CI)
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="io.github.tillackt.clipsody"
# Keychain name of the self-signed certificate, from before the app was renamed to Clipsody;
# renaming it would mean a new certificate, a new fingerprint and new permissions for everyone.
IDENTITY="Clippboard Signing"
APP="build/Clipsody.app"
ARCHS=(--arch arm64 --arch x86_64)
# CI sets WARNINGS_AS_ERRORS=1: the code builds without warnings, and a new one fails the build there.
# Local builds stay lenient, so a newer Xcode with new warnings does not block an install.
STRICT=()
if [[ "${WARNINGS_AS_ERRORS:-0}" == "1" ]]; then STRICT=(-Xswiftc -warnings-as-errors); fi

if [[ "${1:-}" == "test" ]]; then
    swift test ${STRICT[@]+"${STRICT[@]}"}
    exit
fi
# The translations are compiled with xcstringstool, which only full Xcode has; fail before a long build.
if ! xcrun --find xcstringstool >/dev/null 2>&1; then
    echo "Full Xcode is required (xcstringstool missing); install it and run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi
if [[ "${1:-}" == "release" ]] && [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    # A release must match a commit exactly, or its version cannot be traced back to the source.
    echo "Release builds need a clean working tree; commit or stash first" >&2
    exit 1
fi
if [[ "${1:-}" == "strings" || "${1:-}" == "check-strings" ]]; then
    # The compiler lists every String(localized:) it sees; sync adds new keys to the catalog
    # and marks keys that are no longer used as stale.
    STRINGS_TMP="$(mktemp -d)"
    trap 'rm -rf "$STRINGS_TMP"' EXIT
    swift build --scratch-path "$STRINGS_TMP/build" \
        -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGS_TMP/strings"
    STRINGS_DATA=("$STRINGS_TMP"/strings/*.stringsdata)
    if [[ ! -e "${STRINGS_DATA[0]}" ]]; then
        echo "The compiler produced no .stringsdata files; nothing to sync" >&2
        exit 1
    fi
    if [[ "${1:-}" == "strings" ]]; then
        xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "${STRINGS_DATA[@]}"
        echo "Synced Resources/Localizable.xcstrings; translate new entries before the next release"
        exit
    fi
    # check-strings (CI): sync a copy and fail if the code and the catalog disagree, without
    # touching the real file. The copy keeps its name: the table name comes from it.
    mkdir "$STRINGS_TMP/catalog"
    cp Resources/Localizable.xcstrings "$STRINGS_TMP/catalog/"
    xcrun xcstringstool sync "$STRINGS_TMP/catalog/Localizable.xcstrings" --stringsdata "${STRINGS_DATA[@]}"
    python3 - "$STRINGS_TMP/catalog/Localizable.xcstrings" <<'PYTHON'
import json, sys
strings = json.load(open(sys.argv[1]))["strings"]
new = sorted(k for k, v in strings.items() if not v.get("localizations", {}).keys() - {"en"})
stale = sorted(k for k, v in strings.items() if v.get("extractionState") == "stale")
for key in new:
    print(f"Not in the catalog yet (run ./build.sh strings and translate): {key}")
for key in stale:
    print(f"No longer used in the code (run ./build.sh strings and remove): {key}")
sys.exit(1 if new or stale else 0)
PYTHON
    echo "Localizable.xcstrings matches the code"
    exit
fi
if [[ "${1:-}" == "install" || "${1:-}" == "release" ]]; then
    # Never install or ship a build whose tests fail.
    swift test ${STRICT[@]+"${STRICT[@]}"}
fi

swift build -c release "${ARCHS[@]}" ${STRICT[@]+"${STRICT[@]}"}
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Clipsody" "$APP/Contents/MacOS/Clipsody"
# Local symbols are not needed at runtime and only enlarge the download.
strip -x "$APP/Contents/MacOS/Clipsody"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# One <language>.lproj per translation; English is the source language and the fallback.
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources" \
    --serialization-format binary
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
# Build number = commit count, plus the commit itself; "+" marks uncommitted changes.
# Outside a git checkout (e.g. a source download) there is no history to count.
if COMMIT="$(git rev-parse --short HEAD 2>/dev/null)"; then
    BUILD_NUMBER="$(git rev-list --count HEAD)"
    # Untracked files count too: a new source file is part of the build.
    if [[ -n "$(git status --porcelain)" ]]; then COMMIT="$COMMIT+"; fi
else
    BUILD_NUMBER=0
    COMMIT=unknown
fi
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -replace ClipsodyCommit -string "$COMMIT" "$APP/Contents/Info.plist"

# Sandboxed XPC service that decodes clipboard images and reads screenshots (see README).
DECODER_ID="$BUNDLE_ID.decoder"
XPC="$APP/Contents/XPCServices/ClipsodyDecoder.xpc"
mkdir -p "$XPC/Contents/MacOS"
cp "$BIN_DIR/ClipsodyDecoder" "$XPC/Contents/MacOS/ClipsodyDecoder"
strip -x "$XPC/Contents/MacOS/ClipsodyDecoder"
cp Resources/ClipsodyDecoder-Info.plist "$XPC/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$DECODER_ID" "$XPC/Contents/Info.plist"
# Same version as the app, so crash reports of the service match a build.
plutil -replace CFBundleShortVersionString -string "$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)" \
    "$XPC/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$XPC/Contents/Info.plist"

# Hardened runtime: no code injection (DYLD_INSERT_LIBRARIES etc.) into a process that holds
# the Accessibility permission. A stable signing identity keeps that permission across rebuilds.
# Without the "Clippboard Signing" certificate the build falls back to an ad-hoc
# signature, and the permission must be granted again after every rebuild.
# Not `security … | grep -q`: under pipefail grep's early exit can make the pipe "fail" and the
# certificate look missing, which would silently sign ad-hoc.
IDENTITIES="$(security find-identity -p codesigning)"
if [[ "$IDENTITIES" == *"\"$IDENTITY\""* ]]; then
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
sign "$XPC" "$DECODER_ID" Resources/ClipsodyDecoder.entitlements
sign "$APP" "$BUNDLE_ID"
codesign --verify --strict --deep "$APP"
echo "Built and verified $APP (signed as \"$SIGN_AS\")"

if [[ "${1:-}" == "release" ]]; then
    # Disk image to download: the app plus a link to /Applications to drag it onto.
    DMG="build/Clipsody.dmg"
    RELEASE_TMP="$(mktemp -d)"
    trap 'rm -rf "$RELEASE_TMP"' EXIT
    mkdir "$RELEASE_TMP/dmg" "$RELEASE_TMP/cert"
    ditto "$APP" "$RELEASE_TMP/dmg/Clipsody.app"
    ln -s /Applications "$RELEASE_TMP/dmg/Applications"
    rm -f "$DMG"
    # ULFO (LZFSE) opens on every supported macOS (13+) and is smaller than zlib.
    hdiutil create -quiet -volname Clipsody -srcfolder "$RELEASE_TMP/dmg" -fs HFS+ -format ULFO "$DMG"
    # Signed like the app, so a tampered image shows up in `codesign --verify`.
    codesign --force --sign "$SIGN_AS" --identifier "$BUNDLE_ID.dmg" "$DMG"
    codesign --verify --strict "$DMG"
    hdiutil verify -quiet "$DMG"

    # What the download page and the release notes publish, so recipients can check their copy.
    DMG_SHA="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
    codesign -d --extract-certificates="$RELEASE_TMP/cert/cert" "$APP" 2>/dev/null
    CERT_SHA="$(shasum -a 256 "$RELEASE_TMP/cert/cert0" | cut -d ' ' -f 1)"
    VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
    echo "$DMG_SHA  Clipsody.dmg" > "$DMG.sha256"
    cat > build/release-notes.txt <<EOF
Clipsody $VERSION (Build $BUILD_NUMBER, $COMMIT)

SHA-256 Clipsody.dmg:       $DMG_SHA
SHA-256 signing certificate:  $CERT_SHA

Check:  shasum -a 256 ~/Downloads/Clipsody.dmg
EOF
    cat build/release-notes.txt
fi

if [[ "${1:-}" == "install" ]]; then
    TARGET="/Applications/Clipsody.app"
    # Earlier versions installed per user, and before that under the old name Clippboard; two
    # copies would confuse Spotlight and the login item.
    OLD_TARGETS=("$HOME/Applications/Clipsody.app" "$HOME/Applications/Clippboard.app" "/Applications/Clippboard.app")
    LEGACY_BUNDLE_ID="local.thorsten.clippboard"
    # Checked before anything is quit or removed: a failed copy must not leave the user without an app.
    if [[ ! -w /Applications ]]; then
        echo "/Applications is not writable for $(whoami); install aborted, nothing changed" >&2
        exit 1
    fi
    STAGED="/Applications/.Clipsody.app.installing"
    rm -rf "$STAGED"
    # ditto keeps bundle metadata (extended attributes, permissions) as code signing expects.
    ditto "$APP" "$STAGED"
    codesign --verify --strict --deep "$STAGED"
    # The old Clippboard must be gone too: the new app moves its data folder at first launch.
    pkill -x Clipsody || true
    pkill -x Clippboard || true
    # Wait until the old instances are gone (at most 10 s), otherwise `open` fails with error -600.
    for _ in $(seq 50); do
        pgrep -x Clipsody >/dev/null || pgrep -x Clippboard >/dev/null || break
        sleep 0.2
    done
    if pgrep -x Clipsody >/dev/null || pgrep -x Clippboard >/dev/null; then
        rm -rf "$STAGED"
        echo "Clipsody (or the old Clippboard) did not quit; install aborted" >&2
        exit 1
    fi
    # LaunchServices needs a moment after the process is gone.
    sleep 1
    # Same volume: the swap is a rename, and the old per-user copy goes only once the new one is in place.
    rm -rf "$TARGET"
    mv "$STAGED" "$TARGET"
    for OLD in "${OLD_TARGETS[@]}"; do
        if [[ -e "$OLD" ]]; then
            rm -rf "$OLD"
            echo "Removed $OLD"
        fi
    done
    # Permissions granted to the old bundle ID are useless now (the new app asks again); a no-op
    # when there are none.
    tccutil reset All "$LEGACY_BUNDLE_ID" >/dev/null 2>&1 || true
    open "$TARGET"
    echo "Installed and started $TARGET"
fi
