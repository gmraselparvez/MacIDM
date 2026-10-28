#!/bin/zsh
# Downloads yt-dlp's official unpacked macOS build (yt-dlp_macos.zip) to vendor/ and verifies it
# against the release's SHA2-256SUMS. It stays zipped: it contains symlinks that some external
# drives (exFAT) can't store; make-app.sh unpacks it on the internal disk while building. The unpacked build starts in a fraction of a
# second and never extracts Python into temporary folders.
# ffmpeg: drop a static build at vendor/ffmpeg to bundle it; otherwise MacIDM uses
# Homebrew's (/opt/homebrew/bin/ffmpeg) or any ffmpeg on PATH at runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p vendor
BASE=https://github.com/yt-dlp/yt-dlp/releases/latest/download
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/yt-dlp_macos.zip" "$BASE/yt-dlp_macos.zip"
curl -fsSL -o "$TMP/SHA2-256SUMS" "$BASE/SHA2-256SUMS"
EXPECTED=$(grep ' yt-dlp_macos.zip$' "$TMP/SHA2-256SUMS" | cut -d' ' -f1)
ACTUAL=$(shasum -a 256 "$TMP/yt-dlp_macos.zip" | cut -d' ' -f1)
if [[ -z "$EXPECTED" || "$EXPECTED" != "$ACTUAL" ]]; then
  echo "Checksum mismatch for yt-dlp_macos.zip" >&2
  exit 1
fi
rm -rf vendor/yt-dlp vendor/yt-dlp_macos.zip
mv "$TMP/yt-dlp_macos.zip" vendor/yt-dlp_macos.zip
echo "yt-dlp_macos.zip verified ($(du -h vendor/yt-dlp_macos.zip | cut -f1))"
