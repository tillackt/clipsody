#!/usr/bin/env bash
# Selects the newest stable Xcode on a GitHub macOS runner. Runners ship several versions, and the
# default is not always the newest; Clipsody needs Swift 6 and xcstringstool from full Xcode.
set -euo pipefail

CANDIDATES=()
for app in /Applications/Xcode_[0-9]*.app; do
    # Release candidates and betas are named like Xcode_26.7_beta.app or Xcode_26.7_RC.app.
    case "$app" in
        *[Bb]eta* | *[Rr][Cc]*) ;;
        *) CANDIDATES+=("$app") ;;
    esac
done
XCODE=""
if [[ ${#CANDIDATES[@]} -gt 0 ]]; then
    XCODE="$(printf '%s\n' "${CANDIDATES[@]}" | sort -V | tail -n 1)"
fi
if [[ -z "$XCODE" ]]; then
    echo "No stable Xcode found in /Applications" >&2
    exit 1
fi
sudo xcode-select -s "$XCODE"
echo "Using $XCODE"
xcodebuild -version
swift --version
