import AppKit
import SwiftUI

@main
struct MacIDMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("MacIDM", id: "main") {
            MainWindow()
                .environmentObject(state)
                .frame(minWidth: 820, minHeight: 440)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add URL…") { NotificationCenter.default.post(name: .showAddDownload, object: nil) }
                    .keyboardShortcut("n")
                Button("Grab Video…") { NotificationCenter.default.post(name: .showGrabVideo, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Batch Download…") { DownloadCommand.batch.post() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                // ⌥⌘B ("board"); ⌥⌘P is Chrome's Print shortcut, so avoid it.
                Button("Download from Pinterest…") { DownloadCommand.pinterest.post() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Divider()
                Button("Import List…") { DownloadCommand.importList.post() }
                    .keyboardShortcut("o")
                Button("Export List…") { DownloadCommand.exportList.post() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Downloads") {
                Button("Resume") { DownloadCommand.resume.post() }.keyboardShortcut("r")
                Button("Pause") { DownloadCommand.pause.post() }.keyboardShortcut(".")
                Button("Stop") { DownloadCommand.stop.post() }.keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Start Now") { DownloadCommand.startNow.post() }.keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Resume All") { DownloadCommand.resumeAll.post() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Pause All") { DownloadCommand.pauseAll.post() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Open") { DownloadCommand.open.post() }.keyboardShortcut(.downArrow)
                Button("Show in Finder") { DownloadCommand.reveal.post() }.keyboardShortcut("f", modifiers: [.command, .option])
            }
        }

        MenuBarExtra {
            MenuBarView().environmentObject(state)
        } label: {
            Image(systemName: state.activeItems.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Started by the browser helper (--background) or as a login item: stay in the menu bar only.
    private var launchedInBackground = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        launchedInBackground = loginItem || CommandLine.arguments.contains("--background")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Dock icon follows the windows: shown while one is open, hidden otherwise (menu bar icon stays).
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // After the close/open has finished, so the window list is up to date.
                DispatchQueue.main.async { self?.updateDockIcon() }
            }
        }
        if launchedInBackground {
            DispatchQueue.main.async {
                for window in NSApp.windows where Self.isAppWindow(window) { window.close() }
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Regular titled windows (main window, download windows, dialogs, Settings) — not the menu bar panel.
    static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
            && !String(describing: type(of: window)).contains("StatusBar")
    }

    private func updateDockIcon() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && Self.isAppWindow($0) }
        let wanted: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false } // keep running in the menu bar
}

/// Menu commands that act on the main window's selection.
enum DownloadCommand: String {
    case batch, pinterest, importList, exportList, resume, pause, stop, startNow, resumeAll, pauseAll, open, reveal

    func post() { NotificationCenter.default.post(name: .downloadCommand, object: rawValue) }
}

extension Notification.Name {
    static let downloadCommand = Notification.Name("MacIDM.downloadCommand")
    static let showAddDownload = Notification.Name("MacIDM.showAddDownload")
    static let showGrabVideo = Notification.Name("MacIDM.showGrabVideo")
}
