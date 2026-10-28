const api = typeof browser !== "undefined" ? browser : chrome;
const DEFAULTS = {
  autoCapture: false,
  extensions: "zip rar 7z tar gz tgz bz2 xz iso dmg pkg exe msi deb rpm apk mp4 mkv mov avi webm mp3 m4a flac wav pdf epub",
  minSizeMB: 1,
};
const $ = (id) => document.getElementById(id);

api.storage.sync.get(DEFAULTS).then((s) => {
  $("autoCapture").checked = s.autoCapture;
  $("extensions").value = s.extensions;
  $("minSizeMB").value = s.minSizeMB;
});

function save() {
  api.storage.sync.set({
    autoCapture: $("autoCapture").checked,
    extensions: $("extensions").value,
    minSizeMB: Number($("minSizeMB").value) || 0,
  });
}
["autoCapture", "extensions", "minSizeMB"].forEach((id) => $(id).addEventListener("change", save));

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
