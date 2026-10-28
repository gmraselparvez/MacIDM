const api = typeof browser !== "undefined" ? browser : chrome;
const DEFAULTS = {
  autoCapture: false,
  extensions: "zip rar 7z tar gz tgz bz2 xz iso dmg pkg exe msi deb rpm apk mp4 mkv mov avi webm mp3 m4a flac wav pdf epub",
  minSizeMB: 1,
  videoButton: true,
};
const $ = (id) => document.getElementById(id);

api.storage.sync.get(DEFAULTS).then((s) => {
  $("autoCapture").checked = s.autoCapture;
  $("extensions").value = s.extensions;
  $("minSizeMB").value = s.minSizeMB;
  $("videoButton").checked = s.videoButton;
});

function save() {
  api.storage.sync.set({
    autoCapture: $("autoCapture").checked,
    extensions: $("extensions").value,
    minSizeMB: Number($("minSizeMB").value) || 0,
    videoButton: $("videoButton").checked,
  });
}
["autoCapture", "extensions", "minSizeMB", "videoButton"].forEach((id) => $(id).addEventListener("change", save));

$("test").addEventListener("click", async () => {
  $("status").className = "";
  $("status").textContent = "Checking…";
  const r = await api.runtime.sendMessage({ type: "ping" });
  if (r?.ok) {
    $("status").textContent = `Connected to MacIDM ${r.version || ""}`;
    $("status").className = "ok";
  } else {
    $("status").textContent = "Not connected. In MacIDM, open Settings › Browser and click Install. " + (r?.error || "");
    $("status").className = "bad";
  }
});

// Shortcuts: click Change, press the keys; Esc cancels.
const S = globalThis.MacIDMShortcuts;
let shortcuts = S.watch((current) => {
  for (const key of Object.keys(S.DEFAULTS)) $("keys-" + key).textContent = S.label(current[key]);
});
let recording = null;
for (const b of document.querySelectorAll("[data-record]")) {
  b.addEventListener("click", () => {
    recording = b.dataset.record;
    const box = $("keys-" + recording);
    box.textContent = "Press keys…";
    box.classList.add("recording");
    $("shortcutHint").textContent = "Press the new shortcut, or Esc to cancel.";
  });
}
for (const b of document.querySelectorAll("[data-reset]")) {
  b.addEventListener("click", () => api.storage.sync.set({ [b.dataset.reset]: S.DEFAULTS[b.dataset.reset] }));
}
document.addEventListener("keydown", (e) => {
  if (!recording) return;
  e.preventDefault();
  const key = recording;
  const box = $("keys-" + key);
  if (e.code === "Escape") {
    recording = null;
    box.classList.remove("recording");
    box.textContent = S.label(shortcuts[key]);
    $("shortcutHint").textContent = "Cancelled.";
    return;
  }
  const s = S.fromEvent(e);
  if (!s) {
    // Show what the browser reported, so problems with a key are visible.
    $("shortcutHint").textContent = `Got "${e.code}"${e.altKey ? " + Option" : ""}${e.shiftKey ? " + Shift" : ""}. Add ⌥, ⌃ or ⌘ (or use an F-key).`;
    return;
  }
  recording = null;
  box.classList.remove("recording");
  api.storage.sync.set({ [key]: s });
  $("shortcutHint").textContent = `Saved ${S.label(s)}. Refresh open tabs to use it there.`;
}, true);
$("chromeShortcuts").addEventListener("click", (e) => {
  e.preventDefault();
  api.tabs.create({ url: "chrome://extensions/shortcuts" });
});
