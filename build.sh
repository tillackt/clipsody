#!/usr/bin/env bash
# Builds Clipsody.app (universal: Apple Silicon + Intel) into ./build.
#   ./build.sh           build the app bundle
#   ./build.sh test      run the unit tests
#   ./build.sh coverage  run the unit tests with line coverage; fails below COVERAGE_MIN (default 88) percent
#   ./build.sh install   run the tests, build, copy to /Applications and restart
#   ./build.sh release   run the tests and build build/Clipsody.dmg with checksums and release notes; needs the
#                        signing certificate, a clean tree on origin/main and a CHANGELOG.md entry;
#                        PUBLISH=1 also creates the GitHub release and checks the uploaded file
#   ./build.sh strings   add new texts from the code to Resources/Localizable.xcstrings
#   ./build.sh check-strings  fail if code and Resources/Localizable.xcstrings disagree (CI)
set -euo pipefail
cd "$(dirname "$0")"

# A mistyped mode ("relase") must not silently fall back to a plain build without the release checks.
case "${1:-}" in
    "" | test | coverage | install | release | strings | check-strings) ;;
    *)
        echo "Unknown mode \"$1\"; use test, coverage, install, release, strings, check-strings or nothing" >&2
        exit 2
        ;;
esac

BUNDLE_ID="io.github.tillackt.clipsody"
# Keychain name of the self-signed certificate, from before the app was renamed to Clipsody;
# renaming it would mean a new certificate, a new fingerprint and new permissions for everyone.
IDENTITY="Clippboard Signing"
# SHA-256 of that certificate, as published on the website and in every release. Releases must carry
# exactly this one: a different certificate (even one with the same name) would cost every user the
# permissions they granted.
RELEASE_CERT_SHA256="4d175a00dff7276c393a30bc11f2c9ec29cd17da08946cfada661e16b1f9a9d6"
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
if [[ "${1:-}" == "coverage" ]]; then
    # Line coverage of the tested modules (core, services, decoder kit); the AppKit app target has
    # no unit tests. Below COVERAGE_MIN percent the run fails, so coverage cannot quietly erode.
    COVERAGE_MIN="${COVERAGE_MIN:-88}"
    swift test --enable-code-coverage ${STRICT[@]+"${STRICT[@]}"}
    TEST_BIN_DIR="$(swift build --show-bin-path)"
    REPORT="$(xcrun llvm-cov report \
        "$TEST_BIN_DIR/ClipsodyPackageTests.xctest/Contents/MacOS/ClipsodyPackageTests" \
        -instr-profile "$TEST_BIN_DIR/codecov/default.profdata" \
        -ignore-filename-regex='(\.build|Tests)/')"
    # Column 10 of llvm-cov's report is the line coverage.
    TOTAL="$(awk '/^TOTAL/ { sub("%", "", $10); print $10 }' <<<"$REPORT")"
    awk 'NR > 2 && !/^-/ { printf "%-55s %s\n", $1, $10 }' <<<"$REPORT"
    echo "Line coverage: $TOTAL% (minimum $COVERAGE_MIN%)"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            echo "### Test coverage: $TOTAL% of lines (minimum $COVERAGE_MIN%)"
            echo
            echo "Core, services and decoder kit; the AppKit app target has no unit tests."
            echo
            echo "| File | Lines |"
            echo "|---|---:|"
            awk 'NR > 2 && !/^-/ && !/^TOTAL/ { printf "| %s | %s |\n", $1, $10 }' <<<"$REPORT"
        } >> "$GITHUB_STEP_SUMMARY"
    fi
    if awk -v total="$TOTAL" -v min="$COVERAGE_MIN" 'BEGIN { exit !(total + 0 < min + 0) }'; then
        echo "Line coverage $TOTAL% is below the minimum of $COVERAGE_MIN%" >&2
        exit 1
    fi
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
if [[ "${1:-}" == "release" ]]; then
    # Semantic Versioning (README "Versioning"): MAJOR.MINOR.PATCH without leading zeros, released once.
    RELEASE_VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
    if [[ ! "$RELEASE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        echo "Version \"$RELEASE_VERSION\" in Resources/Info.plist is not MAJOR.MINOR.PATCH" >&2
        exit 1
    fi
    # The checks below need the remote's tags and main; without them they would pass by mistake.
    if ! git fetch -q --tags origin main; then
        echo "Could not fetch tags and main from origin; release aborted" >&2
        exit 1
    fi
    if ! git merge-base --is-ancestor HEAD origin/main; then
        echo "Release from a commit on origin/main: merge the release pull request and pull first" >&2
        exit 1
    fi
    TAG_COMMIT="$(git rev-parse -q --verify "refs/tags/v$RELEASE_VERSION^{commit}" || true)"
    if [[ -n "$TAG_COMMIT" && "$TAG_COMMIT" != "$(git rev-parse HEAD)" ]]; then
        echo "v$RELEASE_VERSION was already released from another commit; raise the version first" >&2
        exit 1
    fi
    LATEST_RELEASED="$(git tag -l 'v[0-9]*' | sed 's/^v//' | sort -V | tail -n 1)"
    if [[ -n "$LATEST_RELEASED" && "$LATEST_RELEASED" != "$RELEASE_VERSION" ]] &&
        [[ "$(printf '%s\n%s\n' "$LATEST_RELEASED" "$RELEASE_VERSION" | sort -V | tail -n 1)" != "$RELEASE_VERSION" ]]; then
        echo "Version $RELEASE_VERSION is not newer than the latest release $LATEST_RELEASED" >&2
        exit 1
    fi
    if ! grep -q "^## $RELEASE_VERSION " CHANGELOG.md; then
        echo "CHANGELOG.md has no section \"## $RELEASE_VERSION …\" for this release" >&2
        exit 1
    fi
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
# Rendered from website/assets/logo.svg by .github/scripts/app-artwork.swift.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
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
    RELEASE_TMP="$(mktemp -d)"
    MOUNT="$RELEASE_TMP/mnt"
    # Deletes the scratch files only once nothing of them is mounted any more: removing the backing
    # file of a mounted (writable) image would leave a broken volume behind.
    release_cleanup() {
        if mount | grep -q " on $MOUNT "; then
            if ! hdiutil detach -quiet "$MOUNT" && ! hdiutil detach -quiet -force "$MOUNT"; then
                echo "$MOUNT is still mounted; left $RELEASE_TMP in place" >&2
                return
            fi
        fi
        rm -rf "$RELEASE_TMP"
    }
    trap release_cleanup EXIT
    mkdir "$RELEASE_TMP/dmg" "$RELEASE_TMP/cert" "$MOUNT"

    # Only the published certificate may sign a release.
    codesign -d --extract-certificates="$RELEASE_TMP/cert/cert" "$APP" 2>/dev/null
    CERT_SHA="$(shasum -a 256 "$RELEASE_TMP/cert/cert0" | cut -d ' ' -f 1)"
    if [[ "$CERT_SHA" != "$RELEASE_CERT_SHA256" ]]; then
        echo "The app is signed with certificate $CERT_SHA, not the published $RELEASE_CERT_SHA256; release aborted" >&2
        exit 1
    fi

    # Disk image to download: the app plus a link to /Applications to drag it onto, in a window with
    # an arrow between the two (layout recorded by .github/scripts/dmg-layout.sh) and the app icon
    # as the volume icon.
    DMG="build/Clipsody.dmg"
    ditto "$APP" "$RELEASE_TMP/dmg/Clipsody.app"
    ln -s /Applications "$RELEASE_TMP/dmg/Applications"
    mkdir "$RELEASE_TMP/dmg/.background"
    cp Resources/dmg/background.png "$RELEASE_TMP/dmg/.background/background.png"
    cp Resources/dmg/DS_Store "$RELEASE_TMP/dmg/.DS_Store"
    cp Resources/AppIcon.icns "$RELEASE_TMP/dmg/.VolumeIcon.icns"
    # The custom-icon flag must sit on the volume root, so the image is made writable first.
    hdiutil create -quiet -volname Clipsody -srcfolder "$RELEASE_TMP/dmg" -fs HFS+ -format UDRW "$RELEASE_TMP/rw.dmg"
    hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" "$RELEASE_TMP/rw.dmg"
    xcrun SetFile -a C "$MOUNT"
    hdiutil detach -quiet "$MOUNT"
    rm -f "$DMG"
    # ULFO (LZFSE) opens on every supported macOS (13+) and is smaller than zlib.
    hdiutil convert -quiet "$RELEASE_TMP/rw.dmg" -format ULFO -o "$DMG"
    # Signed like the app, so a tampered image shows up in `codesign --verify`.
    codesign --force --sign "$SIGN_AS" --identifier "$BUNDLE_ID.dmg" "$DMG"
    codesign --verify --strict "$DMG"
    hdiutil verify -quiet "$DMG"

    # What users get: the app inside the image, checked like they would.
    VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
    hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
    codesign --verify --strict --deep "$MOUNT/Clipsody.app"
    if [[ "$(plutil -extract CFBundleShortVersionString raw "$MOUNT/Clipsody.app/Contents/Info.plist")" != "$VERSION" ]]; then
        echo "The app in the disk image is not version $VERSION; release aborted" >&2
        exit 1
    fi
    hdiutil detach -quiet "$MOUNT"

    # Checksums and release notes: the notes come from .github/release-notes.md and this version's
    # section of CHANGELOG.md.
    DMG_SHA="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
    echo "$DMG_SHA  Clipsody.dmg" > "$DMG.sha256"
    awk -v version="$VERSION" '
        index($0, "## " version " ") == 1 { inside = 1; next }
        inside && /^## / { exit }
        inside { print }
    ' CHANGELOG.md > "$RELEASE_TMP/changes.md"
    awk -v changes="$RELEASE_TMP/changes.md" '
        $0 == "{{CHANGES}}" { while ((getline line < changes) > 0) print line; next }
        { print }
    ' .github/release-notes.md |
        sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{BUILD}}/$BUILD_NUMBER/g" -e "s/{{COMMIT}}/$COMMIT/g" \
            -e "s/{{DMG_SHA}}/$DMG_SHA/g" -e "s/{{CERT_SHA}}/$CERT_SHA/g" > build/release-notes.md
    echo "Clipsody $VERSION (Build $BUILD_NUMBER, $COMMIT)"
    echo "SHA-256 Clipsody.dmg:          $DMG_SHA"
    echo "SHA-256 signing certificate:   $CERT_SHA"
    echo "Release notes: build/release-notes.md"

    if [[ "${PUBLISH:-0}" == "1" ]]; then
        # Nothing may swap the image between building and uploading.
        if [[ "$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)" != "$DMG_SHA" ]]; then
            echo "build/Clipsody.dmg changed after it was built; release aborted" >&2
            exit 1
        fi
        gh release create "v$VERSION" "$DMG" "$DMG.sha256" --target "$(git rev-parse HEAD)" \
            --title "Clipsody $VERSION" --notes-file build/release-notes.md
        # GitHub's own checksum of the uploaded file must be the one the notes announce.
        UPLOADED="$(gh release view "v$VERSION" --json assets -q '.assets[] | select(.name == "Clipsody.dmg") | .digest')"
        if [[ "$UPLOADED" != "sha256:$DMG_SHA" ]]; then
            echo "GitHub reports $UPLOADED for the uploaded Clipsody.dmg, expected sha256:$DMG_SHA" >&2
            exit 1
        fi
        echo "Published https://github.com/tillackt/clipsody/releases/tag/v$VERSION"
    else
        echo "Not published. Publish with: PUBLISH=1 ./build.sh release"
    fi
fi

if [[ "${1:-}" == "install" ]]; then
    TARGET="/Applications/Clipsody.app"
    # Checked before anything is quit or removed: a failed copy must not leave the user without an app.
    if [[ ! -w /Applications ]]; then
        echo "/Applications is not writable for $(whoami); install aborted, nothing changed" >&2
        exit 1
    fi
    # One install at a time: two would delete each other's freshly installed app.
    LOCK="/Applications/.Clipsody.install.lock"
    if ! mkdir "$LOCK" 2>/dev/null; then
        echo "Another install is running (if not, remove $LOCK); install aborted, nothing changed" >&2
        exit 1
    fi
    STAGE_DIR="$(mktemp -d /Applications/.Clipsody.install.XXXXXX)"
    trap 'rm -rf "$STAGE_DIR" "$LOCK"' EXIT
    STAGED="$STAGE_DIR/Clipsody.app"
    # ditto keeps bundle metadata (extended attributes, permissions) as code signing expects.
    ditto "$APP" "$STAGED"
    codesign --verify --strict --deep "$STAGED"
    pkill -x Clipsody || true
    # Wait until the old instance is gone (at most 10 s), otherwise `open` fails with error -600.
    for _ in $(seq 50); do
        pgrep -x Clipsody >/dev/null || break
        sleep 0.2
    done
    if pgrep -x Clipsody >/dev/null; then
        echo "Clipsody did not quit; install aborted" >&2
        exit 1
    fi
    # LaunchServices needs a moment after the process is gone.
    sleep 1
    # Same volume: the swap is a rename.
    rm -rf "$TARGET"
    mv "$STAGED" "$TARGET"
    open "$TARGET"
    echo "Installed and started $TARGET"
fi
