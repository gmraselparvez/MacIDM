#!/bin/zsh
# Packages build/MacIDM.app into build/MacIDM-<version>.dmg with an Applications shortcut, the browser
# extension folder and an install guide. Also writes build/MacIDM-Extension-<version>.zip for the release.
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
ditto --norsrc --noextattr BrowserExtension/chrome "$STAGE/MacIDM Browser Extension"
find "$STAGE" -name "._*" -delete # the external drive's metadata files, copied as plain files
cp docs/INSTALL.md "$STAGE/How to Install.txt"
# The extension on its own, for people who only need to update it.
EXT_VERSION=$(/usr/bin/python3 -c 'import json;print(json.load(open("BrowserExtension/chrome/manifest.json"))["version"])')
EXT_ZIP=build/MacIDM-Extension-$EXT_VERSION.zip
rm -f "$EXT_ZIP"
(cd "$STAGE" && ditto -c -k --norsrc --noextattr --keepParent "MacIDM Browser Extension" "$OLDPWD/$EXT_ZIP")
rm -f "$DMG"
hdiutil create -volname "MacIDM $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null 2>&1
if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
hdiutil verify "$DMG" >/dev/null 2>&1
echo "Built $DMG ($(du -h "$DMG" | cut -f1)) and $EXT_ZIP"
