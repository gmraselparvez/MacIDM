# Safari Web Extension (requires Xcode)

Safari extensions must ship inside a signed app as an app extension. You need the full Xcode app to build one; the Command Line Tools aren't enough. The JavaScript is shared with the Chrome extension in `../chrome`.

## Setup

1. Install Xcode, then generate the wrapper project from the shared extension:

   ```bash
   xcrun safari-web-extension-converter BrowserExtension/chrome --app-name MacIDM --bundle-identifier com.macidm.app --macos-only --no-open
   ```

2. In the generated project:
   - Replace the generated `SafariWebExtensionHandler.swift` with the one in this folder.
   - Add this repository as a local Swift package and link `MacIDMCore` to the extension target.
   - Turn on the **App Groups** capability with `group.com.macidm.app` for both the extension and the app.
   - In `manifest.json` for Safari, remove the Chrome-only `"key"` field.

3. In MacIDM, the app must also drain `~/Library/Group Containers/group.com.macidm.app/Inbox`. `AppState.drainInbox()` reads only the Application Support inbox today; add the group container directory once the app is signed with the App Group.

4. Build, run, then enable the extension in Safari › Settings › Extensions. For unsigned development builds, first turn on Safari › Develop › Allow Unsigned Extensions.

## Limits compared with Chrome

- Safari's `downloads` API is limited, so auto-capture of browser downloads may not trigger. The context menu works.
- Safari ignores the native host name passed to `sendNativeMessage` and routes the message to the containing app's extension.
