// Page shortcuts the user can change in the extension options. Shared by the options page and the
// content scripts (content scripts of one extension share globals, so this loads first).
(() => {
  if (globalThis.MacIDMShortcuts) return;
  const api = typeof browser !== "undefined" ? browser : chrome;

  const DEFAULTS = {
    shortcutPinterest: { code: "KeyP", alt: true, shift: true, ctrl: false, meta: false },
    shortcutGrabber: { code: "KeyI", alt: true, shift: true, ctrl: false, meta: false },
  };

  /// "KeyP" → "P", "Digit5" → "5", "F6" → "F6", "Slash" → "/".
  function keyName(code) {
    if (/^Key[A-Z]$/.test(code)) return code.slice(3);
    if (/^Digit\d$/.test(code)) return code.slice(5);
    const named = { Slash: "/", Period: ".", Comma: ",", Semicolon: ";", Quote: "'", BracketLeft: "[", BracketRight: "]",
      Backslash: "\\", Minus: "-", Equal: "=", Backquote: "`", Space: "Space", Enter: "Return", Backspace: "Delete" };
    return named[code] || code;
  }

  /// macOS-style label: ⌃⌥⇧⌘ then the key.
  function label(s) {
    if (!s) return "None";
    return (s.ctrl ? "⌃" : "") + (s.alt ? "⌥" : "") + (s.shift ? "⇧" : "") + (s.meta ? "⌘" : "") + keyName(s.code);
  }

  /// Uses e.code (the physical key), not e.key: Option changes the typed character (⌥⇧P types "∏").
  function matches(e, s) {
    return !!s && !e.repeat && e.code === s.code && e.altKey === !!s.alt && e.shiftKey === !!s.shift
      && e.ctrlKey === !!s.ctrl && e.metaKey === !!s.meta;
  }

  /// A recorded key press → shortcut, or null if it's only a modifier or has no modifier at all.
  function fromEvent(e) {
    if (["ShiftLeft", "ShiftRight", "AltLeft", "AltRight", "ControlLeft", "ControlRight", "MetaLeft", "MetaRight", "CapsLock"].includes(e.code)) return null;
    const isFunctionKey = /^F\d{1,2}$/.test(e.code);
    if (!isFunctionKey && !(e.altKey || e.ctrlKey || e.metaKey)) return null; // plain letters would fire while typing
    return { code: e.code, alt: e.altKey, shift: e.shiftKey, ctrl: e.ctrlKey, meta: e.metaKey };
  }

  /// Current shortcuts; `onChange` is called again whenever they're edited.
  function watch(onChange) {
    const current = { ...DEFAULTS };
    api.storage.sync.get(DEFAULTS).then((s) => { Object.assign(current, s); onChange(current); });
    api.storage.onChanged.addListener((changes) => {
      let changed = false;
      for (const key of Object.keys(DEFAULTS)) if (changes[key]) { current[key] = changes[key].newValue ?? DEFAULTS[key]; changed = true; }
      if (changed) onChange(current);
    });
    return current;
  }

  globalThis.MacIDMShortcuts = { DEFAULTS, label, matches, fromEvent, watch };
})();
