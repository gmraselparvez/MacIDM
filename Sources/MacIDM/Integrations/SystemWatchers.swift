import AppKit
import Network
import UserNotifications

/// Polls the pasteboard for newly copied download links.
@MainActor
final class ClipboardWatcher {
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    var onLink: ((String) -> Void)?

    func setEnabled(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        lastChangeCount = NSPasteboard.general.changeCount // ignore whatever was copied before
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        if let text = pb.string(forType: .string) { onLink?(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

/// Reports when the network comes back after being down.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private var wasSatisfied = true
    var onRestored: (@MainActor () -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let restored = satisfied && !self.wasSatisfied
            self.wasSatisfied = satisfied
            if restored, let handler = self.onRestored {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { handler() } }
            }
        }
        monitor.start(queue: DispatchQueue(label: "MacIDM.network"))
    }
}

/// macOS notifications; silently disabled when running outside an .app bundle.
final class Notifier {
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

enum Power {
    static func sleepNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        try? p.run()
    }
}
