import Foundation
import SafariServices

// Native side of the Safari Web Extension. Safari routes `browser.runtime.sendNativeMessage`
// from background.js here. The extension is sandboxed, so it hands requests to MacIDM through
// the shared App Group container instead of ~/Library/Application Support.
//
// Not part of the SwiftPM build: add it to the Safari extension target Xcode generates
// (see README.md in this folder), together with the MacIDMCore package dependency.

import MacIDMCore

let appGroup = "group.com.macidm.app"

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        var response: [String: Any] = ["ok": false, "error": "unknown message type"]

        switch message["type"] as? String {
        case "ping":
            response = ["ok": true, "version": "0.3.0"]
        case "download":
            if let data = try? JSONSerialization.data(withJSONObject: message),
               let request = try? JSONDecoder().decode(BrowserRequest.self, from: data),
               request.validated() != nil,
               let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
                do {
                    try Inbox(dir: container.appendingPathComponent("Inbox", isDirectory: true)).write(request)
                    DistributedNotificationCenter.default().postNotificationName(
                        Notification.Name(Inbox.notificationName), object: nil, userInfo: nil, deliverImmediately: true)
                    response = ["ok": true]
                } catch {
                    response = ["ok": false, "error": error.localizedDescription]
                }
            } else {
                response = ["ok": false, "error": "invalid download request"]
            }
        default:
            break
        }

        let reply = NSExtensionItem()
        reply.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [reply], completionHandler: nil)
    }
}
