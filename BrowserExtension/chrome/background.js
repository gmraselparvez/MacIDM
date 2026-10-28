// MacIDM browser extension (Chrome/Edge/Brave MV3; also used as the Safari Web Extension source).
const HOST = "com.macidm.host";
const api = typeof browser !== "undefined" ? browser : chrome;

const DEFAULTS = {
  autoCapture: false,
  extensions: "zip rar 7z tar gz tgz bz2 xz iso dmg pkg exe msi deb rpm apk mp4 mkv mov avi webm mp3 m4a flac wav pdf epub",
  minSizeMB: 1,
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

// Context menu: links and media elements.
api.runtime.onInstalled.addListener(() => {
  api.contextMenus.create({
    id: "macidm-download",
    title: "Download with MacIDM",
    contexts: ["link", "video", "audio", "image"],
  });
});

api.contextMenus.onClicked.addListener(async (info, tab) => {
  // On an image/video inside a link, the media file is what the user means, not the link target.
  const url = info.mediaType ? info.srcUrl || info.linkUrl : info.linkUrl || info.srcUrl;
  if (!url) return;
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
    sendToHost({ type: "ping" }).then(sendResponse);
    return true;
  }
});
