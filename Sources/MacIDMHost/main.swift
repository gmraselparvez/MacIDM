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
    // --background: start in the menu bar only, without the main window or a Dock icon.
    open.arguments = (containingApp().map { ["-g", $0.path] } ?? ["-g", "-b", appBundleID]) + ["--args", "--background"]
    try? open.run()
    open.waitUntilExit()
}

/// The browser that started us: our parent process is the browser (or one of its helpers).
func callingBrowser() -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
    let path = length > 0 ? String(cString: buffer) : ""
    return ExtensionHeartbeat.browserName(forProcessPath: path) ?? "Google Chrome"
}

let inbox = Inbox()

/// Lists qualities for the on-page menu. The app runs yt-dlp: a process started from here would be part
/// of Chrome's process tree, and macOS then refuses the files yt-dlp unpacks ("Python.framework is damaged").
func formats(for request: BrowserRequest) -> Data {
    func failure(_ message: String) -> Data { (try? JSONEncoder().encode(FormatsResponse(error: message))) ?? Data() }
    guard request.validated() != nil else { return failure("invalid request") }
    var request = request
    let id = UUID().uuidString
    request.requestID = id
    do { try inbox.write(request) } catch { return failure(error.localizedDescription) }
    wakeApp()
    let deadline = Date().addingTimeInterval(90)
    while Date() < deadline {
        if let data = inbox.takeResponse(id: id) { return data }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return failure("MacIDM didn't answer in time. Is it running?")
}

while let header = readExactly(4), let length = NativeMessaging.length(of: header) {
    guard length > 0, length <= NativeMessaging.maxIncoming, let body = readExactly(length) else { break }
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        reply(["ok": false, "error": "invalid JSON"])
        continue
    }
    switch json["type"] as? String {
    case "ping":
        reply(["ok": true, "version": "0.4.0"])
    case "formats":
        guard let request = try? JSONDecoder().decode(BrowserRequest.self, from: body) else {
            reply(["ok": false, "error": "invalid request"])
            continue
        }
        FileHandle.standardOutput.write(NativeMessaging.frame(formats(for: request)))
    case "hello":
        try? ExtensionHeartbeat().record(callingBrowser())
        reply(["ok": true, "version": "0.4.0"])
    case "download", "media", "batch", "pinterest":
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
