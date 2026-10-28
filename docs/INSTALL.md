How to install MacIDM
=====================

1. Install the app
------------------
Drag MacIDM into the Applications folder (in this window).

The first time you open it:
  - Right-click (or Control-click) MacIDM in Applications and choose Open, then click Open.
  - If macOS says MacIDM "Not Opened" or "can't be opened": open
    System Settings > Privacy & Security, scroll down to Security, and click Open Anyway
    next to "MacIDM was blocked". Confirm with your password or Touch ID.

MacIDM isn't notarized by Apple yet, so macOS asks this once.

2. Add the browser extension (Chrome, Brave, Edge)
--------------------------------------------------
The "MacIDM Browser Extension" folder in this window is the extension. It works in
Google Chrome, Brave, Microsoft Edge, Chromium, Vivaldi and Arc.

Easiest: open MacIDM > Settings > Browser and click Set Up next to your browser.
MacIDM connects itself to that browser, opens its extensions page, and copies the
extension folder path for you. Then in the browser:

  1. Turn on Developer mode (top right of the extensions page).
  2. Click Load unpacked.
  3. Press Shift-Command-G, paste (Command-V), press Return, then click Select.

The extensions page is chrome://extensions in Chrome, brave://extensions in Brave and
edge://extensions in Edge.

When it's done, MacIDM > Settings > Browser shows your browser as Ready.

Tip: you can also load this folder directly from the disk image, but Set Up keeps a copy
in MacIDM's own folder that stays put after you eject the disk image. Use Set Up.

3. Permissions macOS may ask for
--------------------------------
  - "MacIDM wants to control Google Chrome" (or Brave, Edge, Safari): click Allow.
    This lets the Pinterest shortcut read the page you're on. You can change it later in
    System Settings > Privacy & Security > Automation.
  - Notifications: allow them to be told when downloads finish.
    System Settings > Notifications > MacIDM.
  - Open at login is optional: MacIDM > Settings > General > Startup.

4. Optional: HD video and MP3
-----------------------------
For HD video (which arrives as separate picture and sound) and MP3/M4A conversion,
install ffmpeg with Homebrew (https://brew.sh):

    brew install ffmpeg

Help and updates: https://github.com/gmraselparvez/MacIDM
