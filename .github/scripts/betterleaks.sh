#!/usr/bin/env bash
# Scans the whole git history for secrets with Betterleaks (the successor of gitleaks).
# The version and the archive's SHA-256 are pinned: a changed or tampered download fails the job.
set -euo pipefail

VERSION="1.9.0"
SHA256="f8b185a39ffcece2a1ca82bf3a4e7435cd81963ffd16b7a9128daf75f35f6de7"
ARCHIVE="betterleaks_${VERSION}_linux_x64.tar.gz"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL -o "$WORK/$ARCHIVE" "https://github.com/betterleaks/betterleaks/releases/download/v${VERSION}/${ARCHIVE}"
echo "$SHA256  $WORK/$ARCHIVE" | sha256sum -c -
tar -xzf "$WORK/$ARCHIVE" -C "$WORK" betterleaks

# Known false positives are listed in .betterleaksignore; secrets are redacted in the log.
"$WORK/betterleaks" git . --redact --no-banner -v
