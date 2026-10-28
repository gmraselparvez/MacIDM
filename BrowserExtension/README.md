# MacIDM browser extension

| Folder | Browsers |
|---|---|
| [`chrome/`](chrome) | **Google Chrome, Brave, Microsoft Edge, Chromium, Vivaldi, Arc** and other Chromium-based browsers. They all use the same extension, so there's one folder for all of them. |
| [`safari/`](safari) | Safari. Needs to be built in Xcode; see [safari/README.md](safari/README.md). |

## Install in Chrome, Brave or Edge

The easiest way is from the app: **MacIDM › Settings › Browser**, then **Set Up** next to your browser. MacIDM registers its helper for that browser, opens its extensions page, and copies the extension folder path for you.

Then in the browser:

1. Open the extensions page: `chrome://extensions` (Chrome), `brave://extensions` (Brave) or `edge://extensions` (Edge).
2. Turn on **Developer mode**.
3. Click **Load unpacked**, press **⇧⌘G**, paste the folder path, and click **Select**.

MacIDM's Settings › Browser then shows the browser as **Ready**.

## What it adds

- A **Download this video** button on videos, with an on-page quality menu
- **Grab images from this page** (toolbar button or ⌥⇧I), including on sites that block right-click
- A **Download board** button on Pinterest boards and pins
- **Download with MacIDM** in the right-click menu, and optional automatic capture of downloads by file type

The extension talks only to the MacIDM app on your Mac, through its native-messaging helper. It sends the page address and only the cookies needed for the file or Pinterest board you're downloading, and nothing from private windows.
