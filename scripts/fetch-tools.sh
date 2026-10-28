#!/bin/zsh
# Downloads the official yt-dlp macOS build into vendor/ and verifies its SHA-256.
# ffmpeg: drop a static build at vendor/ffmpeg to bundle it; otherwise MacIDM uses
# Homebrew's (/opt/homebrew/bin/ffmpeg) or any ffmpeg on PATH at runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p vendor
BASE=https://github.com/yt-dlp/yt-dlp/releases/latest/download
curl -fsSL -o vendor/yt-dlp.download "$BASE/yt-dlp_macos"
curl -fsSL -o vendor/SHA2-256SUMS "$BASE/SHA2-256SUMS"
EXPECTED=$(grep ' yt-dlp_macos$' vendor/SHA2-256SUMS | cut -d' ' -f1)
ACTUAL=$(shasum -a 256 vendor/yt-dlp.download | cut -d' ' -f1)
if [[ -z "$EXPECTED" || "$EXPECTED" != "$ACTUAL" ]]; then
  echo "Checksum mismatch for yt-dlp_macos" >&2
  rm -f vendor/yt-dlp.download
  exit 1
fi
mv vendor/yt-dlp.download vendor/yt-dlp
chmod +x vendor/yt-dlp
rm -f vendor/SHA2-256SUMS
echo "yt-dlp $(vendor/yt-dlp --version) verified"
