import AppKit
import Foundation
import MacIDMCore

// Native messaging host launched by Chrome/Edge/Brave. Reads framed JSON on stdin,
// drops each download into the app's inbox, wakes or launches the app, and replies.

let appBundleID = "com.macidm.app"

func readExactly(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        let chunk = FileHandle.standardInput.readData(ofLength: count - data.count)
        if chunk.isEmpty { return nil }
        data.append(chunk)
    }
    return data
}

func reply(_ object: [String: Any]) {
    guard let json = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(NativeMessaging.frame(json))
}

/// The app bundle this host lives in (MacIDM.app/Contents/MacOS/MacIDMHost), if any.
func containingApp() -> URL? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
}

func wakeApp() {
    if !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Inbox.notificationName), object: nil, userInfo: nil, deliverImmediately: true)
        return
    }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // -g: don't steal focus from the browser. The app drains the inbox on launch.
    open.arguments = containingApp().map { ["-g", $0.path] } ?? ["-g", "-b", appBundleID]
    try? open.run()
    open.waitUntilExit()
}

let inbox = Inbox()
while let header = readExactly(4), let length = NativeMessaging.length(of: header) {
    guard length > 0, length <= NativeMessaging.maxIncoming, let body = readExactly(length) else { break }
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        reply(["ok": false, "error": "invalid JSON"])
        continue
    }
    switch json["type"] as? String {
    case "ping":
        reply(["ok": true, "version": "0.3.0"])
    case "download":
        guard let request = try? JSONDecoder().decode(BrowserRequest.self, from: body), request.validated() != nil else {
            reply(["ok": false, "error": "invalid download request"])
            continue
        }
        do {
            try inbox.write(request)
            wakeApp()
            reply(["ok": true])
        } catch {
            reply(["ok": false, "error": error.localizedDescription])
        }
    default:
        reply(["ok": false, "error": "unknown message type"])
    }
}
