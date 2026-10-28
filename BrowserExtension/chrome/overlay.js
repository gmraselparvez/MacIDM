// "Download this video" button over videos, with an IDM-style quality menu.
// Runs in every frame, so embedded players (YouTube iframes etc.) get it too.
(() => {
  if (window.__macidmOverlay) return;
  // Only HTML pages: SVG/XML documents (e.g. badge images opened directly) can't host a shadow root.
  if (!(document.documentElement instanceof HTMLElement) || !document.contentType?.includes("html")) return;
  window.__macidmOverlay = true;
  const api = typeof browser !== "undefined" ? browser : chrome;

  // DRM streaming services: MacIDM won't download these, so don't offer.
  const DRM = ["netflix.com", "disneyplus.com", "hulu.com", "primevideo.com", "max.com", "hbomax.com",
    "peacocktv.com", "paramountplus.com", "tv.apple.com", "spotify.com", "crunchyroll.com", "hotstar.com"];
  const host = location.hostname;
  if (DRM.some((d) => host === d || host.endsWith("." + d))) return;

  // ⌥⇧P on Pinterest: download this board or pin. Handled here as well as by the extension command,
  // because Chrome only binds suggested shortcuts on first install, not when an update adds one.
  if (window === top && /(^|\.)pinterest\.[a-z.]+$/i.test(host)) {
    document.addEventListener("keydown", (e) => {
      // e.code, not e.key: Option changes the typed character (⌥⇧P types "∏").
      if (e.code !== "KeyP" || !e.altKey || !e.shiftKey || e.metaKey || e.ctrlKey || e.repeat) return;
      e.preventDefault();
      e.stopPropagation();
      const toast = document.createElement("div");
      toast.textContent = "Opening in MacIDM…";
      toast.style.cssText = "position:fixed;z-index:2147483647;left:50%;bottom:28px;transform:translateX(-50%);" +
        "padding:9px 16px;border-radius:9px;background:rgba(22,110,240,.95);color:#fff;" +
        "font:600 13px -apple-system,system-ui,sans-serif;box-shadow:0 4px 16px rgba(0,0,0,.35)";
      document.documentElement.appendChild(toast);
      api.runtime.sendMessage({ type: "pinterest", url: location.href }).then((r) => {
        if (!r?.ok) toast.textContent = "MacIDM isn't connected";
      }).catch(() => { toast.textContent = "MacIDM isn't connected"; });
      setTimeout(() => toast.remove(), 2200);
    }, true);
  }

  // Direct media files go straight to the segmented downloader; no menu needed.
  const DIRECT_MEDIA = /\.(mp4|m4v|webm|mov|mkv|mp3|m4a|ogg|wav)(\?|#|$)/i;

  let enabled = true;
  api.storage.sync.get({ videoButton: true }).then((s) => { enabled = s.videoButton; });
  api.storage.onChanged.addListener((changes) => {
    if (changes.videoButton) {
      enabled = changes.videoButton.newValue;
      if (!enabled) hide(true);
    }
  });

  // Closed shadow root keeps page CSS from restyling the button and the page from reading it.
  const hostEl = document.createElement("macidm-overlay");
  const shadow = hostEl.attachShadow({ mode: "closed" });
  shadow.innerHTML = `<style>
    .wrap { position: fixed; z-index: 2147483647; display: none; flex-direction: column; align-items: flex-end; font: 12px -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
    .btn { all: initial; display: flex; white-space: nowrap; align-items: center; gap: 6px; padding: 6px 11px; border-radius: 8px;
      background: rgba(22, 110, 240, .93); color: #fff; cursor: pointer; font: 600 12px -apple-system, system-ui, sans-serif;
      box-shadow: 0 2px 10px rgba(0,0,0,.35); }
    .btn:hover { background: rgb(22, 110, 240); }
    .btn.done { background: rgba(40, 150, 70, .95); }
    .btn.err { background: rgba(200, 50, 40, .95); }
    .btn svg { width: 14px; height: 14px; fill: #fff; }
    .caret { margin-left: 2px; opacity: .85; }
    .menu { display: none; margin-top: 4px; min-width: 250px; max-width: 340px; padding: 4px; border-radius: 10px;
      background: rgba(32, 32, 36, .97); color: #f2f2f2; box-shadow: 0 6px 24px rgba(0,0,0,.45); }
    .item { all: initial; display: flex; justify-content: space-between; gap: 14px; box-sizing: border-box; width: 100%;
      padding: 7px 10px; border-radius: 6px; color: #f2f2f2; cursor: pointer; font: 12px -apple-system, system-ui, sans-serif; }
    .item:hover { background: rgb(22, 110, 240); color: #fff; }
    .item .size { opacity: .65; }
    .item:hover .size { opacity: .9; }
    .note { padding: 8px 10px; opacity: .8; line-height: 1.35; }
    .title { padding: 6px 10px 4px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; opacity: .9; }
    .pending { display: inline-block; width: 46px; height: 9px; border-radius: 5px; vertical-align: middle;
      background: linear-gradient(90deg, rgba(255,255,255,.08), rgba(255,255,255,.28), rgba(255,255,255,.08));
      background-size: 200% 100%; animation: shimmer 1.1s linear infinite; }
    .status { display: flex; align-items: center; gap: 7px; padding: 2px 10px 6px; font-size: 11px; opacity: .65; }
    .spin { width: 10px; height: 10px; border: 2px solid rgba(255,255,255,.25); border-top-color: #fff;
      border-radius: 50%; animation: spin .8s linear infinite; }
    @keyframes shimmer { from { background-position: 200% 0; } to { background-position: -200% 0; } }
    @keyframes spin { to { transform: rotate(360deg); } }
    hr { border: 0; border-top: 1px solid rgba(255,255,255,.12); margin: 4px 6px; }
  </style>
  <div class="wrap">
    <button class="btn" title="Download with MacIDM"><svg viewBox="0 0 16 16"><path d="M7 1h2v7h3l-4 4-4-4h3zM2 13h12v2H2z"/></svg><span class="label">Download this video</span><span class="caret">▾</span></button>
    <div class="menu"></div>
  </div>`;
  const wrap = shadow.querySelector(".wrap");
  const button = shadow.querySelector(".btn");
  const label = shadow.querySelector(".label");
  const caret = shadow.querySelector(".caret");
  const menu = shadow.querySelector(".menu");

  let current = null;
  let hideTimer = null;
  let menuOpen = false;
  let busy = false;
  let frameQueued = false;
  // page URL -> { promise, result }. `result` is set once the host answers.
  const formatCache = new Map();
  let prefetchTimer = null;

  // The usual choices, offered instantly while the real list loads. yt-dlp picks the best
  // stream up to each height, so these work even before we know exactly what exists.
  const PROVISIONAL = [
    { code: "best", label: "MP4 · best quality" },
    { code: "video:1080", label: "MP4 · 1080p HD" },
    { code: "video:720", label: "MP4 · 720p HD" },
    { code: "video:480", label: "MP4 · 480p" },
    { code: "video:360", label: "MP4 · 360p" },
    { code: "audio:mp3", label: "MP3 · audio only" },
    { code: "audio:m4a", label: "M4A · audio only" },
  ];

  function lookup(pageUrl) {
    let entry = formatCache.get(pageUrl);
    if (!entry) {
      entry = { promise: null, result: null };
      entry.promise = send({ type: "videoFormats", pageUrl }).then((r) => {
        entry.result = r;
        if (!r?.ok) setTimeout(() => formatCache.delete(pageUrl), 5000); // allow a retry later
        return r;
      });
      formatCache.set(pageUrl, entry);
    }
    return entry;
  }

  function attach() {
    // In fullscreen only the fullscreen element is visible, so the button has to live inside it.
    const parent = document.fullscreenElement || document.documentElement;
    if (hostEl.parentNode !== parent) parent.appendChild(hostEl);
  }

  function hide(force = false) {
    if (!force && (busy || menuOpen)) return;
    closeMenu();
    wrap.style.display = "none";
    current = null;
  }

  function videoAt(x, y) {
    for (const v of document.querySelectorAll("video")) {
      const r = v.getBoundingClientRect();
      if (r.width < 200 || r.height < 110) continue; // skip thumbnails and tiny previews
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return v;
    }
    return null;
  }

  // Pinned by its right edge to the video's top-right corner, so the button never moves when
  // its label changes or the (wider) menu opens; the menu hangs below, right-aligned to it.
  function place(v) {
    const r = v.getBoundingClientRect();
    wrap.style.top = Math.max(r.top + 10, 4) + "px";
    wrap.style.left = "auto";
    wrap.style.right = Math.max(innerWidth - r.right + 10, 4) + "px";
  }

  // On feeds (Facebook, Instagram, X, Reddit…) the page URL isn't the video's own page.
  // Look around the video for a link to its post, which the video grabber can use.
  const PERMALINK = /\/(videos?|reels?|watch|status|shorts|p|comments)\/|[?&]v=|\/watch\/?\?/i;
  function permalinkFor(video) {
    if (PERMALINK.test(location.pathname + location.search)) return location.href;
    let node = video;
    for (let depth = 0; node && depth < 20; depth++, node = node.parentElement) {
      for (const a of node.querySelectorAll?.("a[href]") ?? []) {
        try {
          const url = new URL(a.href, location.href);
          const sameSite = url.hostname.split(".").slice(-2).join(".") === location.hostname.split(".").slice(-2).join(".");
          if (sameSite && PERMALINK.test(url.pathname + url.search)) return url.href;
        } catch {}
      }
    }
    return location.href;
  }

  // The most visible large video on screen.
  function largestVisible() {
    let best = null;
    let bestArea = 0;
    for (const v of document.querySelectorAll("video")) {
      const r = v.getBoundingClientRect();
      if (r.width < 200 || r.height < 110) continue;
      const w = Math.min(r.right, innerWidth) - Math.max(r.left, 0);
      const h = Math.min(r.bottom, innerHeight) - Math.max(r.top, 0);
      const area = w > 0 && h > 0 ? w * h : 0;
      if (area > bestArea) { bestArea = area; best = v; }
    }
    return best;
  }

  // Always shown (no hover needed): on the video under the mouse, otherwise the most visible one.
  let lastMouse = null;
  function update() {
    frameQueued = false;
    if (!enabled) { hide(true); return; }
    if (menuOpen || busy) {
      if (current?.isConnected) place(current);
      return;
    }
    const v = (lastMouse && videoAt(lastMouse.x, lastMouse.y)) || largestVisible();
    if (!v) { hide(true); return; }
    if (v !== current) {
      current = v;
      const direct = DIRECT_MEDIA.test(v.currentSrc || v.src || "");
      caret.style.display = direct ? "none" : "";
      clearTimeout(prefetchTimer);
      if (!direct) prefetchTimer = setTimeout(() => { if (current === v) lookup(permalinkFor(v)); }, 800);
    }
    attach();
    wrap.style.display = "flex";
    place(v);
  }
  function scheduleUpdate() {
    if (frameQueued) return;
    frameQueued = true;
    requestAnimationFrame(update);
  }

  document.addEventListener("mousemove", (e) => {
    lastMouse = { x: e.clientX, y: e.clientY };
    scheduleUpdate();
  }, { passive: true, capture: true });
  document.addEventListener("mouseleave", () => { lastMouse = null; scheduleUpdate(); });
  addEventListener("scroll", scheduleUpdate, { passive: true, capture: true });
  addEventListener("resize", scheduleUpdate, { passive: true });
  document.addEventListener("fullscreenchange", scheduleUpdate);
  // Pages add, move and resize players at any time (YouTube navigates without reloading).
  setInterval(scheduleUpdate, 500);

  // Clicking anywhere outside the menu closes it.
  document.addEventListener("mousedown", (e) => { if (menuOpen && !e.composedPath().includes(hostEl)) hide(true); }, true);
  document.addEventListener("keydown", (e) => { if (menuOpen && e.key === "Escape") hide(true); }, true);

  function flash(ok, text) {
    busy = true;
    closeMenu();
    button.className = "btn " + (ok ? "done" : "err");
    label.textContent = text;
    setTimeout(() => {
      button.className = "btn";
      label.textContent = "Download this video";
      busy = false;
      hide(true);
    }, ok ? 1800 : 3500);
  }

  function closeMenu() {
    menuOpen = false;
    menu.style.display = "none";
    menu.replaceChildren();
  }

  function note(text) {
    const div = document.createElement("div");
    div.className = "note";
    div.textContent = text;
    return div;
  }

  function item(text, size, onClick) {
    const b = document.createElement("button");
    b.className = "item";
    const l = document.createElement("span");
    l.textContent = text;
    b.append(l);
    if (size) {
      const s = document.createElement("span");
      s.className = "size";
      s.textContent = size;
      b.append(s);
    }
    b.addEventListener("click", (e) => { e.preventDefault(); e.stopPropagation(); onClick(); }, true);
    return b;
  }

  function formatSize(bytes) {
    if (!bytes) return "";
    const units = ["B", "KB", "MB", "GB"];
    let i = 0;
    while (bytes >= 1000 && i < units.length - 1) { bytes /= 1000; i++; }
    return (i < 2 ? Math.round(bytes) : bytes.toFixed(1)) + " " + units[i];
  }

  async function send(message) {
    try {
      return await api.runtime.sendMessage(message);
    } catch (err) {
      return { ok: false, error: String(err) };
    }
  }

  function choiceRow(c, pageUrl, title) {
    const size = c.size === undefined ? null : formatSize(c.size);
    const row = item(c.label, size, async () => {
      const r = await send({ type: "grabVideo", pageUrl, title: title || document.title, choice: c.code });
      flash(r?.ok, r?.ok ? "Opened in MacIDM" : "MacIDM isn't connected");
    });
    if (c.size === undefined) {
      const ph = document.createElement("span");
      ph.className = "pending";
      row.append(ph);
    }
    return row;
  }

  function renderMenu(pageUrl, result) {
    const rows = [];
    const header = document.createElement("div");
    header.className = "title";
    header.textContent = result?.ok ? result.title : document.title.replace(/ - YouTube$/, "");
    rows.push(header);
    if (result && !result.ok) {
      rows.push(note(result.error || "MacIDM isn't connected. Open MacIDM › Settings › Browser."));
    } else {
      if (!result) {
        const status = document.createElement("div");
        status.className = "status";
        const spin = document.createElement("span");
        spin.className = "spin";
        const text = document.createElement("span");
        text.textContent = "Checking sizes — you can pick now";
        status.append(spin, text);
        rows.push(status);
      }
      const choices = result?.choices ?? PROVISIONAL.map((c) => ({ ...c, size: undefined }));
      for (const c of choices) rows.push(choiceRow(c, pageUrl, result?.title));
    }
    rows.push(document.createElement("hr"));
    rows.push(item("More options in MacIDM…", "", async () => {
      const r = await send({ type: "grabVideo", pageUrl, title: document.title });
      flash(r?.ok, r?.ok ? "Opened in MacIDM" : "MacIDM isn't connected");
    }));
    menu.replaceChildren(...rows);
    place(current);
  }

  async function openMenu() {
    const pageUrl = permalinkFor(current);
    menuOpen = true;
    clearTimeout(hideTimer);
    clearTimeout(prefetchTimer);
    menu.style.display = "block";
    const entry = lookup(pageUrl);
    // Show at once: the real list if it's already in, otherwise the usual choices with loading sizes.
    renderMenu(pageUrl, entry.result);
    if (entry.result) return;
    const result = await entry.promise;
    if (menuOpen) renderMenu(pageUrl, result);
  }

  button.addEventListener("click", async (e) => {
    e.preventDefault();
    e.stopPropagation();
    if (!current || busy) return;
    if (menuOpen) { closeMenu(); return; }
    const src = current.currentSrc || current.src || "";
    if (/^https?:/i.test(src) && DIRECT_MEDIA.test(src)) {
      const r = await send({ type: "grabVideo", pageUrl: location.href, src, title: document.title });
      flash(r?.ok, r?.ok ? "Sent to MacIDM" : "MacIDM isn't connected");
      return;
    }
    openMenu();
  }, true);
})();
