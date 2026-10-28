# MacIDM — Project Spec for Claude Code

> A native macOS download manager inspired by Internet Download Manager (IDM).
> Hand this file to Claude Code and say: **"Read MacIDM-SPEC.md and build Phase 1. Ask me before moving to the next phase."**

---

## 1. Goal

Build a fast, native macOS download manager that:
- Speeds up downloads by splitting files into parallel segments
- Pauses/resumes reliably (even after quit, sleep, or network loss)
- Captures links from the browser and clipboard
- Grabs videos from sites that allow it (via `yt-dlp`)

**Out of scope (do not build):** anything that bypasses DRM, paywalls, logins the user doesn't own, or site protections.

---

## 2. Tech Stack

| Layer | Choice |
|---|---|
| Language | Swift 5.9+ |
| UI | SwiftUI (macOS 13 Ventura+) |
| Networking | `URLSession` with HTTP `Range` requests |
| Concurrency | Swift Concurrency (`async/await`, actors) |
| Persistence | SwiftData (or SQLite via GRDB if simpler) |
| Video engine | Bundled `yt-dlp` + `ffmpeg` binaries, invoked via `Process` |
| Browser bridge | Chrome/Firefox WebExtension + Native Messaging host; Safari Web Extension |
| Build | Xcode project, SPM for dependencies |

---

## 3. Architecture

```
MacIDM/
├── App/
│   ├── MacIDMApp.swift          # App entry, menu bar extra, windows
│   └── AppState.swift           # Global observable state
├── Core/
│   ├── DownloadEngine.swift     # Actor: manages all active downloads
│   ├── SegmentedDownloader.swift# Splits file, downloads ranges in parallel
│   ├── Segment.swift            # Range start/end, bytes done, state
│   ├── FileMerger.swift         # Joins segment parts into final file
│   ├── ProbeService.swift       # HEAD request: size, Accept-Ranges, filename
│   ├── SpeedLimiter.swift       # Token-bucket bandwidth throttling
│   ├── QueueManager.swift       # Max concurrent downloads, ordering
│   └── Scheduler.swift          # Start/stop at set times
├── Models/
│   ├── DownloadItem.swift       # URL, file name, size, status, category, segments
│   └── Category.swift           # Video, Music, Documents, Archives, Programs, Other
├── Persistence/
│   └── Store.swift              # Save/restore downloads and segment progress
├── Integrations/
│   ├── ClipboardWatcher.swift   # Polls NSPasteboard for downloadable URLs
│   ├── NativeMessagingHost/     # Receives links from browser extension
│   └── YTDLPService.swift       # Wraps yt-dlp: list formats, download, progress
├── UI/
│   ├── MainWindow.swift         # Table of downloads, sidebar of categories
│   ├── AddDownloadSheet.swift   # Paste URL, pick folder, segments, start
│   ├── DownloadRow.swift        # Progress bar, speed, ETA, segment visualizer
│   ├── SettingsView.swift       # Segments, folders, speed limit, schedule
│   └── MenuBarView.swift        # Quick status in the menu bar
└── BrowserExtension/
    ├── chrome/                  # manifest.json (MV3), background.js, context menu
    └── safari/                  # Safari Web Extension target
```

---

## 4. Core Download Logic (most important part)

1. **Probe** — send `HEAD` (fall back to `GET` with `Range: bytes=0-0`):
   - Read `Content-Length`, `Accept-Ranges`, `Content-Disposition`, `ETag`, `Last-Modified`.
   - Follow redirects; use the final URL.
2. **Decide segments**:
   - If server supports ranges and size is known → split into N segments (default 8, max 32).
   - Otherwise → single-stream download (no resume guarantee; warn the user).
3. **Download segments in parallel**:
   - Each segment writes to `<file>.part<i>` in a temp folder.
   - Use `URLSession` bytes streaming; update progress every ~250 ms.
   - Retry each segment up to 5 times with exponential backoff.
4. **Dynamic segmentation (IDM's trick)**:
   - When a segment finishes early, split the largest remaining segment in half and start a new connection on the second half.
5. **Merge**:
   - Concatenate parts in order into the final file, verify total size, delete parts.
   - Optional: verify checksum if the user provides one (MD5/SHA-256).
6. **Resume**:
   - Persist every segment's `start`, `end`, `downloaded` to the store.
   - On resume, check `ETag`/`Last-Modified`; if it changed, restart from zero.
   - Resume automatically after the network comes back (`NWPathMonitor`) and after wake from sleep.
7. **Speed limit**: shared token bucket across all segments/downloads.
8. **Naming**: `Content-Disposition` → URL path → fallback `download-<timestamp>`. Avoid overwriting: add ` (1)`, ` (2)`.
9. **Auto-categorize** by extension into `~/Downloads/MacIDM/<Category>/`.

---

## 5. Features by Phase

### Phase 1 — Core app (MVP)
- [ ] Xcode project, SwiftUI main window + Settings
- [ ] Add download by pasting URL
- [ ] Probe + segmented parallel download + merge
- [ ] Pause / resume / cancel / retry
- [ ] Progress, speed, ETA, per-segment progress bar
- [ ] Persistence: downloads survive app restart
- [ ] Auto-categorize into folders
- [ ] Unit tests for: range splitting, merging, resume math, filename parsing

### Phase 2 — Productivity
- [ ] Queue with max concurrent downloads
- [ ] Global speed limiter
- [ ] Scheduler (start/stop at time; optional "sleep Mac when done")
- [ ] Clipboard watcher (toggle in settings) with "Download this?" prompt
- [ ] Menu bar extra with active downloads
- [ ] macOS notifications on complete/fail
- [ ] Drag-and-drop URLs/links into the window

### Phase 3 — Browser integration
- [ ] Chrome/Edge/Brave MV3 extension: right-click "Download with MacIDM", optional auto-capture of downloads by file type
- [ ] Native Messaging host + installer step that registers it
- [ ] Safari Web Extension target in the same Xcode project
- [ ] Pass cookies/referer **only for the page the user is on**, so normal logged-in downloads work

### Phase 4 — Video grabber
- [ ] Bundle `yt-dlp` and `ffmpeg` (with an "Update yt-dlp" button)
- [ ] Paste a page URL → list available formats/qualities → download
- [ ] Parse yt-dlp progress output into the same UI
- [ ] Audio-only (MP3/M4A) option
- [ ] Clear message when a site is unsupported or DRM-protected (do not attempt bypass)

### Phase 5 — Polish
- [ ] Dark/light mode, app icon, keyboard shortcuts
- [ ] Import/export download list
- [ ] Batch download (list of URLs, or numbered pattern like `file[001-100].jpg`)
- [ ] Code signing + notarization notes, DMG packaging script

---

## 6. UI Notes

- Main window: sidebar (All, Downloading, Completed, Queued, categories) + table (Name, Size, Progress, Speed, ETA, Status).
- Row expands to show the segment bar (colored blocks like IDM).
- Toolbar: Add URL, Resume, Pause, Stop, Delete, Settings.
- Respect system appearance; keep it clean and native.

---

## 7. Settings Defaults

| Setting | Default |
|---|---|
| Segments per download | 8 |
| Max concurrent downloads | 3 |
| Download folder | `~/Downloads/MacIDM` |
| Speed limit | Off |
| Clipboard watcher | Off |
| Retries per segment | 5 |
| User-Agent | Standard Safari UA string |

---

## 8. Edge Cases to Handle

- Server ignores `Range` (returns 200 instead of 206) → fall back to single stream
- Unknown size (chunked transfer) → single stream, indeterminate progress
- File changed on server mid-download (ETag mismatch) → restart
- Disk full → pause with clear error
- Expired links (403/410) → let user paste a refreshed URL and keep progress if the file is identical
- Very large files (>4 GB) → use 64-bit offsets everywhere
- Sandboxing: request access to the downloads folder via security-scoped bookmarks

---

## 9. Instructions for Claude Code

1. Build **one phase at a time**. After each phase: build, run tests, and summarize what works.
2. Keep the download engine UI-independent (testable on its own).
3. Use `actor` for shared download state to avoid race conditions.
4. Write tests for the core engine before wiring up the UI.
5. Test with public files, e.g. Linux ISO mirrors or `https://speed.hetzner.de/100MB.bin`-style test files.
6. Never add features that bypass DRM, captchas, paywalls, or authentication.

**Start command:**
> Read `MacIDM-SPEC.md`. Create the Xcode project and build Phase 1. Ask me before starting Phase 2.
