#!/bin/zsh
# Packages build/MacIDM.app into build/MacIDM-<version>.dmg with an Applications shortcut.
# Run scripts/make-app.sh first. To notarize, see docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/MacIDM.app
[[ -d "$APP" ]] || { echo "Build the app first: scripts/make-app.sh" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG=build/MacIDM-$VERSION.dmg
# Stage on the local disk: external volumes add ._ files that would end up in the image.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr "$APP" "$STAGE/MacIDM.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "MacIDM $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null 2>&1
if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
hdiutil verify "$DMG" >/dev/null 2>&1
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
