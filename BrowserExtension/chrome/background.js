// MacIDM browser extension (Chrome/Edge/Brave MV3; also used as the Safari Web Extension source).
const HOST = "com.macidm.host";
const api = typeof browser !== "undefined" ? browser : chrome;

const DEFAULTS = {
  autoCapture: false,
  extensions: "zip rar 7z tar gz tgz bz2 xz iso dmg pkg exe msi deb rpm apk mp4 mkv mov avi webm mp3 m4a flac wav pdf epub",
  minSizeMB: 1,
  videoButton: true,
};

async function settings() {
  return { ...DEFAULTS, ...(await api.storage.sync.get(DEFAULTS)) };
}

function sendToHost(message) {
  return new Promise((resolve) => {
    try {
      api.runtime.sendNativeMessage(HOST, message, (response) => {
        if (api.runtime.lastError || !response) {
          resolve({ ok: false, error: api.runtime.lastError?.message || "no response" });
        } else {
          resolve(response);
        }
      });
    } catch (e) {
      resolve({ ok: false, error: String(e) });
    }
  });
}

/// Cookies only for the exact download URL (what the browser itself would send), never in incognito.
async function cookieHeader(url, incognito) {
  if (incognito || !api.cookies) return undefined;
  try {
    const cookies = await api.cookies.getAll({ url });
    return cookies.length ? cookies.map((c) => `${c.name}=${c.value}`).join("; ") : undefined;
  } catch {
    return undefined;
  }
}

async function sendDownload({ url, referrer, incognito, fileName }) {
  if (!/^https?:/i.test(url)) return { ok: false, error: "unsupported URL" };
  return sendToHost({
    type: "download",
    url,
    referrer: referrer && /^https?:/i.test(referrer) ? referrer : undefined,
    cookies: await cookieHeader(url, incognito),
    userAgent: navigator.userAgent,
    fileName: fileName || undefined,
  });
}

/// A video page (YouTube etc.) goes to MacIDM's video grabber, which lets the user pick a quality.
async function sendMedia({ url, title, incognito, choice }) {
  if (!/^https?:/i.test(url)) return { ok: false, error: "unsupported URL" };
  return sendToHost({
    type: "media",
    url,
    cookies: await cookieHeader(url, incognito),
    userAgent: navigator.userAgent,
    fileName: title || undefined,
    choice: choice || undefined,
  });
}

/// Pinterest board or pin → MacIDM's Pinterest window. Your Pinterest cookies go along because Pinterest
/// shows signed-out visitors only part of a board; MacIDM uses them for its Pinterest requests only.
async function sendPinterest(url, incognito) {
  return sendToHost({ type: "pinterest", url, cookies: await cookieHeader(url, incognito), userAgent: navigator.userAgent });
}

// Direct media files can use the fast segmented downloader; anything else (blob:, streams) needs yt-dlp.
const DIRECT_MEDIA = /\.(mp4|m4v|webm|mov|mkv|mp3|m4a|ogg|wav)(\?|#|$)/i;

// Tell MacIDM the extension is installed (shown as "Ready" in its Settings › Browser).
const sayHello = () => sendToHost({ type: "hello", version: api.runtime.getManifest().version });
api.runtime.onStartup.addListener(sayHello);

// Context menu: links and media elements.
api.runtime.onInstalled.addListener(async () => {
  sayHello();
  await api.contextMenus.removeAll(); // reloads keep old entries around
  api.contextMenus.create({
    id: "macidm-download",
    title: "Download with MacIDM",
    contexts: ["link", "video", "audio", "image"],
  });
  api.contextMenus.create({ id: "macidm-images", title: "Grab images from this page…", contexts: ["page", "image"] });
  api.contextMenus.create({
    id: "macidm-pinterest",
    title: "Download this Pinterest board/pin with MacIDM",
    contexts: ["page", "link", "image"],
    documentUrlPatterns: ["*://*.pinterest.com/*", "*://*.pinterest.co.uk/*", "*://*.pinterest.ca/*", "*://*.pinterest.de/*",
      "*://*.pinterest.fr/*", "*://*.pinterest.com.au/*", "*://*.pinterest.jp/*", "*://*.pinterest.es/*", "*://*.pinterest.it/*"],
  });
});

/// Opens the image grabber in a tab, injecting it first into tabs that were open before the extension.
async function openImageGrabber(tabId) {
  try {
    await api.tabs.sendMessage(tabId, { type: "openImageGrabber" });
    return { ok: true };
  } catch {
    try {
      await api.scripting.executeScript({ target: { tabId }, files: ["shortcuts.js", "grabber.js"] });
      await api.tabs.sendMessage(tabId, { type: "openImageGrabber" });
      return { ok: true };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }
}

api.commands?.onCommand.addListener(async (command, tab) => {
  const target = tab ?? (await api.tabs.query({ active: true, currentWindow: true }))[0];
  if (command === "grab-images" && target?.id !== undefined) openImageGrabber(target.id);
  // ⌥⇧P when Chrome has bound it (then the page never sees the key): let the page's Pinterest button
  // handle it, exactly like a click. Fall back to the tab's address if the page script isn't there.
  if (command === "download-pinterest" && target?.id !== undefined) {
    try {
      await api.tabs.sendMessage(target.id, { type: "pinterestShortcut" });
    } catch {
      if (/^https?:\/\/([a-z0-9-]+\.)*pinterest\.[a-z.]+\//i.test(target.url || "")) sendPinterest(target.url, target.incognito);
    }
  }
});

api.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === "macidm-images") {
    if (tab?.id !== undefined) openImageGrabber(tab.id);
    return;
  }
  if (info.menuItemId === "macidm-pinterest") {
    // A pin link or the page itself (board or pin).
    const link = info.linkUrl && /\/pin\/|pinterest\./.test(info.linkUrl) ? info.linkUrl : info.pageUrl;
    sendPinterest(link, tab?.incognito);
    return;
  }
  // On an image/video inside a link, the media file is what the user means, not the link target.
  const url = info.mediaType ? info.srcUrl || info.linkUrl : info.linkUrl || info.srcUrl;
  if (!url) return;
  // Streamed video (blob: source): hand the page to the video grabber instead.
  if ((info.mediaType === "video" || info.mediaType === "audio") && !DIRECT_MEDIA.test(url)) {
    const r = await sendMedia({ url: info.frameUrl || info.pageUrl || tab?.url, title: tab?.title, incognito: tab?.incognito });
    if (!r.ok) console.warn("MacIDM: could not hand off video:", r.error);
    return;
  }
  const result = await sendDownload({ url, referrer: info.pageUrl || tab?.url, incognito: tab?.incognito });
  if (!result.ok) console.warn("MacIDM: could not hand off download:", result.error);
});

// Optional auto-capture of browser downloads by file type.
function extensionOf(path) {
  const clean = (path || "").split(/[?#]/)[0];
  const name = clean.substring(clean.lastIndexOf("/") + 1);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.substring(dot + 1).toLowerCase() : "";
}

if (api.downloads?.onCreated) {
  api.downloads.onCreated.addListener(async (item) => {
    const s = await settings();
    if (!s.autoCapture || item.byExtensionId === api.runtime.id) return;
    const url = item.finalUrl || item.url;
    if (!/^https?:/i.test(url)) return; // blob:/data: can't be fetched by MacIDM
    const exts = s.extensions.toLowerCase().split(/[\s,]+/).filter(Boolean);
    const ext = extensionOf(item.filename) || extensionOf(url);
    if (!exts.includes(ext)) return;
    if (item.totalBytes > 0 && item.totalBytes < s.minSizeMB * 1024 * 1024) return;

    const result = await sendDownload({
      url,
      referrer: item.referrer,
      incognito: item.incognito,
      fileName: item.filename ? item.filename.split(/[\\/]/).pop() : undefined,
    });
    // Only take over if MacIDM accepted it; otherwise let the browser finish normally.
    if (result.ok) {
      try {
        await api.downloads.cancel(item.id);
        await api.downloads.erase({ id: item.id });
      } catch {}
    }
  });
}

// Lets the options page test the connection.
api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "ping") {
    sayHello();
    sendToHost({ type: "ping" }).then(sendResponse);
    return true;
  }
  // From the "Download this video" button (overlay.js).
  if (message?.type === "grabVideo") {
    const incognito = _sender.tab?.incognito;
    const direct = /^https?:/i.test(message.src) && DIRECT_MEDIA.test(message.src);
    const sent = direct
      ? sendDownload({ url: message.src, referrer: message.pageUrl, incognito })
      : sendMedia({ url: message.pageUrl, title: message.title, incognito, choice: message.choice });
    sent.then(sendResponse);
    return true;
  }
  if (message?.type === "openImageGrabberInTab") {
    openImageGrabber(message.tabId).then(sendResponse);
    return true;
  }
  // Images picked in the grabber.
  if (message?.type === "downloadBatch") {
    sendToHost({ type: "batch", url: message.pageUrl, urls: message.urls, referrer: message.pageUrl }).then(sendResponse);
    return true;
  }
  if (message?.type === "pinterest") {
    sendPinterest(message.url, _sender.tab?.incognito).then(sendResponse);
    return true;
  }
  // Qualities for the on-page menu; MacIDM's helper asks yt-dlp.
  if (message?.type === "videoFormats") {
    (async () => {
      if (!/^https?:/i.test(message.pageUrl)) return { ok: false, error: "unsupported URL" };
      return sendToHost({
        type: "formats",
        url: message.pageUrl,
        cookies: await cookieHeader(message.pageUrl, _sender.tab?.incognito),
        userAgent: navigator.userAgent,
      });
    })().then(sendResponse);
    return true;
  }
});
