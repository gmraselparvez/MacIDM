import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut stored in UserDefaults: a key code plus Cocoa modifier flags.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt // NSEvent.ModifierFlags raw value (device-independent part)
    var key: String     // what to show, e.g. "P"

    static let pinterestDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_P),
                                           modifiers: NSEvent.ModifierFlags([.option, .shift]).rawValue, key: "P")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// macOS-style label, e.g. "⌥⇧P".
    var label: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// From a key press while recording; nil for a bare letter (it would fire while typing) or a lone modifier.
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let fKeys: [Int: String] = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        let functionKey = fKeys[Int(event.keyCode)]
        guard functionKey != nil || !mods.intersection([.command, .option, .control]).isEmpty else { return nil }
        let name: String
        if let functionKey {
            name = functionKey
        } else {
            // Ignores Option, so ⌥⇧P shows "P" rather than "∏".
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            name = chars.uppercased()
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods.rawValue, key: name)
    }

    init(keyCode: UInt32, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// System-wide shortcuts (work whichever app is in front), via Carbon hot keys.
@MainActor
final class GlobalShortcuts {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    /// Registers (or replaces) the shortcut `id`. Returns false if another app already owns that combination.
    @discardableResult
    func register(id: UInt32, combo: KeyCombo?, action: @escaping () -> Void) -> Bool {
        Self.installHandler()
        if let old = refs.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        Self.actions[id] = action
        guard let combo else { return true }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D49444D) /* "MIDM" */, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalShortcuts.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// The address of the tab you're looking at in a browser, asked via AppleScript (macOS asks permission once).
enum BrowserTab {
    private static let chromium: Set<String> = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
                                                "org.chromium.Chromium", "company.thebrowser.Browser", "com.vivaldi.Vivaldi"]

    private static func isBrowser(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return chromium.contains(id) || id == "com.apple.Safari"
    }

    /// The browser you used last (running apps aren't listed in order of use, so this is tracked).
    nonisolated(unsafe) private static var lastBrowserPID: pid_t?

    /// Call once at launch: remembers each browser as it comes to the front.
    static func startTracking() {
        if let front = NSWorkspace.shared.frontmostApplication, isBrowser(front) { lastBrowserPID = front.processIdentifier }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, isBrowser(app) {
                lastBrowserPID = app.processIdentifier
            }
        }
    }

    /// The browser in front, else the one used last, else any running browser.
    static func currentBrowser() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, isBrowser(front) { return front }
        if let pid = lastBrowserPID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated { return app }
        return NSWorkspace.shared.runningApplications.first(where: isBrowser)
    }

    enum Failure: Error { case noBrowser, notAllowed(String), noWindow }

    static func currentURL() -> Result<URL, Failure> {
        guard let app = currentBrowser(), let id = app.bundleIdentifier else { return .failure(.noBrowser) }
        let source = id == "com.apple.Safari"
            ? "tell application id \"\(id)\" to return URL of current tab of front window"
            : "tell application id \"\(id)\" to return URL of active tab of front window"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743: the user hasn't allowed MacIDM to control this browser.
            return .failure(code == -1743 ? .notAllowed(app.localizedName ?? "the browser") : .noWindow)
        }
        guard let s = result?.stringValue, let url = URL(string: s) else { return .failure(.noWindow) }
        return .success(url)
    }
}
