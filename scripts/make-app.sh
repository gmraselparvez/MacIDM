#!/bin/zsh
# Builds MacIDM.app from the SwiftPM executable (no Xcode required).
#   ./scripts/make-app.sh                 ad-hoc signed, for this Mac
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./scripts/make-app.sh
#                                         hardened runtime + timestamp, ready to notarize
set -euo pipefail
VERSION=${VERSION:-0.5.0}
BUILD_NUMBER=${BUILD_NUMBER:-5}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MacIDM"
OUT=build/MacIDM.app
# Assemble and sign on the local disk: external (non-APFS) volumes add AppleDouble ._ files
# whenever a file gets extended attributes, and those break the bundle signature.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/MacIDM.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
COPYFILE_DISABLE=1 cp "$BIN" "$APP/Contents/MacOS/MacIDM"
COPYFILE_DISABLE=1 cp "$(dirname "$BIN")/MacIDMHost" "$APP/Contents/MacOS/MacIDMHost"
mkdir -p "$APP/Contents/Resources/BrowserExtension"
COPYFILE_DISABLE=1 cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
COPYFILE_DISABLE=1 cp -R BrowserExtension/chrome "$APP/Contents/Resources/BrowserExtension/chrome"
# Media tools from scripts/fetch-tools.sh (optional; MacIDM falls back to Homebrew/PATH).
mkdir -p "$APP/Contents/Resources/bin"
for tool in yt-dlp ffmpeg; do
  if [[ -x vendor/$tool ]]; then COPYFILE_DISABLE=1 cp vendor/$tool "$APP/Contents/Resources/bin/$tool"; fi
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MacIDM</string>
  <key>CFBundleDisplayName</key><string>MacIDM</string>
  <key>CFBundleIdentifier</key><string>com.macidm.app</string>
  <key>CFBundleExecutable</key><string>MacIDM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
find "$APP" -name "._*" -delete
xattr -cr "$APP" 2>/dev/null || true
# Sign nested executables first, then the bundle.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  SIGN_ARGS=(--force --sign -)
else
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
fi
for nested in "$APP/Contents/Resources/bin/"*(N) "$APP/Contents/MacOS/MacIDMHost"; do
  codesign "${SIGN_ARGS[@]}" "$nested"
done
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/MacIDM"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p build
rm -rf "$OUT"
ditto --norsrc --noextattr "$APP" "$OUT"
codesign --verify --deep --strict "$OUT"
echo "Built $OUT ($VERSION, signed: $SIGN_IDENTITY)"
