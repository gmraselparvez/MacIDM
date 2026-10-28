# Releasing MacIDM

## 1. Build

```bash
swift test
./scripts/fetch-tools.sh                     # yt-dlp into vendor/ (checksum-verified)
VERSION=0.5.0 BUILD_NUMBER=5 ./scripts/make-app.sh
./scripts/make-dmg.sh
```

Without `SIGN_IDENTITY` the app is ad-hoc signed. It runs on the Mac that built it, but other Macs block it with Gatekeeper.

## 2. Sign with Developer ID

You need a paid Apple Developer account and a **Developer ID Application** certificate in your keychain. `security find-identity -v -p codesigning` lists the ones you have.

```bash
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./scripts/make-app.sh && ./scripts/make-dmg.sh
```

`make-app.sh` signs `yt-dlp`, `ffmpeg` (if bundled) and `MacIDMHost` first, then the app, using the hardened runtime and a secure timestamp. Notarization requires both. No extra entitlements are needed: the app isn't sandboxed and doesn't use JIT.

## 3. Notarize and staple

Store an app-specific password once (create it at appleid.apple.com):

```bash
xcrun notarytool store-credentials macidm --apple-id you@example.com --team-id TEAMID
```

Then, for each release:

```bash
xcrun notarytool submit build/MacIDM-0.5.0.dmg --keychain-profile macidm --wait
xcrun stapler staple build/MacIDM-0.5.0.dmg
spctl --assess --type open --context context:primary-signature -v build/MacIDM-0.5.0.dmg
```

If notarization fails, `xcrun notarytool log <submission-id> --keychain-profile macidm` shows why. The usual causes are an unsigned nested binary or a missing `--options runtime`.

`notarytool` and `stapler` ship with Xcode, not the Command Line Tools.

## Notes

- **ffmpeg**: Homebrew's ffmpeg links to Homebrew libraries and won't run on other Macs. To bundle one, put a static, self-contained build at `vendor/ffmpeg`. Check its license (GPL builds bring GPL obligations).
- **yt-dlp** is Unlicense (public domain). The bundled copy is only a starting point: users update it from Settings › Media, which writes to `~/Library/Application Support/MacIDM/bin`, outside the signed bundle.
- **Browser helper**: after installing to `/Applications`, users click **Install** again in Settings › Browser so the helper registration points at the new location.
- **Sandboxing / Mac App Store** isn't supported as-is: the native messaging helper, writing to other browsers' folders, and running yt-dlp all need an unsandboxed app.
