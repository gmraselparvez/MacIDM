// Image grabber: lists every image on the page — even where right-click is disabled — and sends the
// chosen ones to MacIDM. Opened from the toolbar button, ⌥⇧I, or the page's right-click menu.
(() => {
  if (window.__macidmGrabber) return;
  // Only HTML pages: SVG/XML documents (e.g. badge images opened directly) can't host a shadow root.
  if (!(document.documentElement instanceof HTMLElement) || !document.contentType?.includes("html")) return;
  window.__macidmGrabber = true;
  const api = typeof browser !== "undefined" ? browser : chrome;

  const IMAGE_EXT = /\.(jpe?g|png|gif|webp|avif|bmp|svg|heic|tiff?)(\?|#|$)/i;
  const LAZY_ATTRS = ["data-src", "data-original", "data-lazy-src", "data-full", "data-hi-res-src", "data-zoom-image", "data-large"];

  /// Swap known thumbnail URLs for bigger versions.
  function upgrade(url) {
    try {
      const u = new URL(url);
      // Pinterest: every pin has a 736px version (originals can have another extension, so use the board downloader for those).
      if (u.hostname === "i.pinimg.com") u.pathname = u.pathname.replace(/^\/(\d+x\d*|\d+x)\//, "/736x/");
      // X / Twitter: ask for the original size.
      if (u.hostname === "pbs.twimg.com" && u.searchParams.has("name")) u.searchParams.set("name", "orig");
      return u.href;
    } catch {
      return url;
    }
  }

  /// The largest candidate in a srcset ("a.jpg 320w, b.jpg 1280w" or "a.jpg 1x, b.jpg 2x").
  function largestFromSrcset(srcset) {
    if (!srcset) return null;
    let best = null;
    let bestScore = -1;
    for (const part of srcset.split(",")) {
      const [url, size = "1x"] = part.trim().split(/\s+/);
      if (!url) continue;
      const score = parseFloat(size) * (size.endsWith("w") ? 1 : 1000);
      if (score > bestScore) { bestScore = score; best = url; }
    }
    return best;
  }

  function collect() {
    const found = new Map();
    const add = (raw, w = 0, h = 0) => {
      if (!raw) return;
      try {
        const u = new URL(raw, location.href);
        if (u.protocol !== "https:" && u.protocol !== "http:") return; // skip data:/blob: images
        const url = upgrade(u.href);
        const prev = found.get(url);
        if (!prev || w * h > prev.w * prev.h) found.set(url, { url, w, h });
      } catch {}
    };
    for (const img of document.querySelectorAll("img")) {
      add(img.currentSrc || img.src, img.naturalWidth, img.naturalHeight);
      add(largestFromSrcset(img.getAttribute("srcset") || img.getAttribute("data-srcset")));
      for (const a of LAZY_ATTRS) add(img.getAttribute(a));
    }
    for (const s of document.querySelectorAll("picture source[srcset]")) add(largestFromSrcset(s.getAttribute("srcset")));
    for (const v of document.querySelectorAll("video[poster]")) add(v.poster);
    for (const m of document.querySelectorAll('meta[property="og:image"], meta[name="twitter:image"]')) add(m.content);
    for (const a of document.querySelectorAll("a[href]")) if (IMAGE_EXT.test(a.href)) add(a.href);
    // CSS background images (a bounded scan so huge pages stay responsive).
    let scanned = 0;
    for (const el of document.querySelectorAll("body *")) {
      if (++scanned > 6000) break;
      if (el.offsetWidth < 80 || el.offsetHeight < 80) continue;
      const bg = getComputedStyle(el).backgroundImage;
      if (!bg || bg === "none") continue;
      for (const m of bg.matchAll(/url\(["']?([^"')]+)["']?\)/g)) add(m[1], el.offsetWidth, el.offsetHeight);
    }
    return [...found.values()];
  }

  let host = null;

  function close() {
    host?.remove();
    host = null;
    document.removeEventListener("keydown", onKey, true);
  }

  function onKey(e) {
    if (e.key === "Escape") { e.stopPropagation(); close(); }
  }

  function open() {
    if (host) return;
    const images = collect();
    host = document.createElement("macidm-grabber");
    const shadow = host.attachShadow({ mode: "closed" });
    shadow.innerHTML = `<style>
      :host { all: initial; }
      .backdrop { position: fixed; inset: 0; z-index: 2147483647; background: rgba(0,0,0,.45);
        display: flex; align-items: center; justify-content: center; font: 13px -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
      .card { width: min(920px, 94vw); height: min(680px, 88vh); display: flex; flex-direction: column; border-radius: 14px;
        background: #1f1f23; color: #f2f2f2; box-shadow: 0 20px 60px rgba(0,0,0,.5); overflow: hidden; }
      header, footer { display: flex; align-items: center; gap: 10px; padding: 12px 16px; background: #26262b; }
      header { border-bottom: 1px solid rgba(255,255,255,.08); flex-wrap: wrap; row-gap: 8px; }
      footer { border-top: 1px solid rgba(255,255,255,.08); }
      h1 { all: unset; font-size: 15px; font-weight: 600; }
      .muted { opacity: .6; }
      .spacer { flex: 1; }
      button, select { all: unset; cursor: pointer; padding: 6px 12px; border-radius: 7px; background: rgba(255,255,255,.1); font-size: 12px; }
      button:hover, select:hover { background: rgba(255,255,255,.16); }
      button.primary { background: rgb(22,110,240); color: #fff; font-weight: 600; }
      button.primary:hover { background: rgb(40,125,250); }
      button[disabled] { opacity: .4; pointer-events: none; }
      .close { padding: 4px 9px; font-size: 15px; }
      .grid { flex: 1; overflow: auto; padding: 14px; display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 10px; align-content: start; }
      .tile { position: relative; aspect-ratio: 1; border-radius: 9px; overflow: hidden; background: #2c2c32; cursor: pointer; outline: 2px solid transparent; }
      .tile.on { outline-color: rgb(22,110,240); }
      .tile img { width: 100%; height: 100%; object-fit: cover; display: block; }
      .tile .check { position: absolute; top: 7px; left: 7px; width: 20px; height: 20px; border-radius: 50%; background: rgba(0,0,0,.45);
        border: 2px solid rgba(255,255,255,.85); box-sizing: border-box; }
      .tile.on .check { background: rgb(22,110,240); border-color: #fff; }
      .tile.on .check::after { content: "✓"; position: absolute; inset: 0; display: grid; place-items: center; font-size: 12px; color: #fff; font-weight: 700; }
      .tile .dims { position: absolute; bottom: 6px; right: 6px; padding: 1px 6px; border-radius: 5px; background: rgba(0,0,0,.6); font-size: 10.5px; }
      .tile.hidden { display: none; }
      .empty { grid-column: 1 / -1; text-align: center; padding: 60px 0; opacity: .6; }
      .status { font-size: 12px; }
    </style>
    <div class="backdrop">
      <div class="card">
        <header>
          <h1>Images on this page</h1><span class="muted count"></span>
          <span class="spacer"></span>
          <select class="size">
            <option value="0">Any size</option>
            <option value="200" selected>200 px or larger</option>
            <option value="500">500 px or larger</option>
            <option value="1000">1000 px or larger</option>
          </select>
          <button class="all">Select all</button><button class="none">Select none</button>
          <button class="close" title="Close (Esc)">✕</button>
        </header>
        <div class="grid"></div>
        <footer>
          <span class="status muted"></span>
          <span class="spacer"></span>
          <button class="cancel">Cancel</button>
          <button class="primary go">Download</button>
        </footer>
      </div>
    </div>`;
    const $ = (s) => shadow.querySelector(s);
    const grid = $(".grid");
    const sizeSelect = $(".size");
    const go = $(".go");
    const tiles = [];

    for (const img of images) {
      const tile = document.createElement("div");
      tile.className = "tile on";
      const el = document.createElement("img");
      el.loading = "lazy";
      el.referrerPolicy = "no-referrer-when-downgrade";
      el.src = img.url;
      const dims = document.createElement("span");
      dims.className = "dims";
      const check = document.createElement("span");
      check.className = "check";
      tile.append(el, check, dims);
      const entry = { tile, url: img.url, w: img.w, h: img.h };
      const showDims = () => { dims.textContent = entry.w && entry.h ? `${entry.w}×${entry.h}` : ""; };
      el.addEventListener("load", () => {
        entry.w = Math.max(entry.w, el.naturalWidth);
        entry.h = Math.max(entry.h, el.naturalHeight);
        showDims();
        applyFilter();
      });
      el.addEventListener("error", () => { entry.broken = true; tile.classList.add("hidden"); update(); });
      showDims();
      tile.addEventListener("click", () => { tile.classList.toggle("on"); update(); });
      grid.append(tile);
      tiles.push(entry);
    }
    if (!tiles.length) {
      const empty = document.createElement("div");
      empty.className = "empty";
      empty.textContent = "No images found on this page.";
      grid.append(empty);
    }

    function visible() { return tiles.filter((t) => !t.tile.classList.contains("hidden")); }
    function selected() { return visible().filter((t) => t.tile.classList.contains("on")); }

    function applyFilter() {
      const min = Number(sizeSelect.value);
      for (const t of tiles) {
        // Unknown sizes stay visible until the image loads and we know.
        const known = t.w > 0 && t.h > 0;
        t.tile.classList.toggle("hidden", !!t.broken || (known && Math.max(t.w, t.h) < min));
      }
      update();
    }

    function update() {
      const n = selected().length;
      $(".count").textContent = `${visible().length} found`;
      go.textContent = n ? `Download ${n} image${n === 1 ? "" : "s"}` : "Download";
      go.disabled = n === 0;
    }

    sizeSelect.addEventListener("change", applyFilter);
    $(".all").addEventListener("click", () => { visible().forEach((t) => t.tile.classList.add("on")); update(); });
    $(".none").addEventListener("click", () => { tiles.forEach((t) => t.tile.classList.remove("on")); update(); });
    $(".close").addEventListener("click", close);
    $(".cancel").addEventListener("click", close);
    $(".backdrop").addEventListener("click", (e) => { if (e.target === $(".backdrop")) close(); });
    go.addEventListener("click", async () => {
      const urls = selected().map((t) => t.url);
      go.disabled = true;
      $(".status").textContent = "Sending to MacIDM…";
      let r;
      try { r = await api.runtime.sendMessage({ type: "downloadBatch", pageUrl: location.href, urls }); } catch (e) { r = { ok: false, error: String(e) }; }
      if (r?.ok) {
        $(".status").textContent = `Sent ${urls.length} to MacIDM`;
        setTimeout(close, 900);
      } else {
        $(".status").textContent = "MacIDM isn't connected. Open MacIDM › Settings › Browser.";
        go.disabled = false;
      }
    });

    document.addEventListener("keydown", onKey, true);
    (document.fullscreenElement || document.documentElement).appendChild(host);
    applyFilter();
  }

  api.runtime.onMessage.addListener((message) => {
    if (message?.type === "openImageGrabber") open();
  });
})();
