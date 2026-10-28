import AppKit
import SwiftUI

/// Opens standalone windows (save dialog, progress, video grabber) from anywhere, even when
/// the main window is closed and the app is only in the menu bar.
@MainActor
final class WindowPresenter {
    private var windows: [String: NSWindow] = [:]
    /// Marks windows opened for a request (Pinterest, save dialogs, progress) so a background
    /// launch doesn't close them along with the main window.
    static let identifier = NSUserInterfaceItemIdentifier("MacIDM.presented")
    private var cascadePoint = NSPoint.zero

    /// Shows the window for `key`, creating it with `content` if needed. `content` gets a closure that closes it.
    func show<Content: View>(key: String, title: String, floating: Bool = false,
                             @ViewBuilder content: (@escaping () -> Void) -> Content) {
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: content { [weak self] in self?.close(key) })
        controller.sizingOptions = .preferredContentSize // window follows the view, e.g. Show/Hide details
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = title
        window.identifier = WindowPresenter.identifier
        window.isReleasedWhenClosed = false
        if floating { window.level = .floating }
        if windows.isEmpty { window.center(); cascadePoint = NSPoint(x: window.frame.minX, y: window.frame.maxY) }
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        windows[key] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows[key] = nil }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(_ key: String) {
        windows[key]?.close()
        windows[key] = nil
    }

    func isOpen(_ key: String) -> Bool { windows[key] != nil }

    func setTitle(_ key: String, _ title: String) {
        if windows[key]?.title != title { windows[key]?.title = title }
    }
}
