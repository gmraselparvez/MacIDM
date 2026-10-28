const api = typeof browser !== "undefined" ? browser : chrome;
const $ = (id) => document.getElementById(id);

(async () => {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  const url = tab?.url || "";
  let path = "";
  try { path = new URL(url).pathname; } catch {}
  const onPinterest = /(^|\.)pinterest\.[a-z.]+$/i.test(new URL(url || "about:blank").hostname || "");
  if (onPinterest && path.split("/").filter(Boolean).length >= 1) {
    $("pinterest").classList.remove("hidden");
    $("pinterestLabel").firstChild.textContent = path.startsWith("/pin/") ? "Download this pin" : "Download this board";
  }

  $("images").addEventListener("click", async () => {
    const r = await api.runtime.sendMessage({ type: "openImageGrabberInTab", tabId: tab.id });
    if (r?.ok) window.close();
    else $("status").textContent = "Can't open on this page (browser pages and the Web Store are off-limits).";
  });

  $("pinterest").addEventListener("click", async () => {
    $("status").textContent = "Opening in MacIDM…";
    const r = await api.runtime.sendMessage({ type: "pinterest", url });
    if (r?.ok) window.close();
    else $("status").textContent = "MacIDM isn't connected. Open MacIDM › Settings › Browser.";
  });

  $("options").addEventListener("click", () => { api.runtime.openOptionsPage(); window.close(); });
})();
