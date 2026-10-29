#!/usr/bin/env bash
# Selects the newest stable Xcode on a GitHub macOS runner. Runners ship several versions, and the
# default is not always the newest; Clipsody needs Swift 6 and xcstringstool from full Xcode.
set -euo pipefail

CANDIDATES=()
for app in /Applications/Xcode_[0-9]*.app; do
    # Only plain version numbers (Xcode_27.1.app, Xcode_26.6.0.app): betas and release candidates
    # carry a suffix, spelled in many ways (_beta, _RC, _Release_Candidate). The runners also have
    # plain-named symlinks to them (Xcode_27.2.app -> Xcode_27.2_Release_Candidate.app), so the
    # real folder's name counts, not the link's.
    real="$(cd "$app" && pwd -P)"
    if [[ "$(basename "$app")" =~ ^Xcode_[0-9]+(\.[0-9]+)*\.app$ ]] &&
        [[ "$(basename "$real")" =~ ^Xcode_[0-9]+(\.[0-9]+)*\.app$ ]]; then
        CANDIDATES+=("$app")
    fi
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
