#!/usr/bin/env bash
# Selects the newest stable Xcode on a GitHub macOS runner. Runners ship several versions, and the
# default is not always the newest; Clipsody needs Swift 6 and xcstringstool from full Xcode.
set -euo pipefail

XCODE="$(ls -d /Applications/Xcode_[0-9]*.app | grep -v -i -E 'beta|rc' | sort -V | tail -n 1)"
if [[ -z "$XCODE" ]]; then
    echo "No stable Xcode found in /Applications" >&2
    exit 1
fi
sudo xcode-select -s "$XCODE"
echo "Using $XCODE"
xcodebuild -version
swift --version
