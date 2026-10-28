import AppKit
import MacIDMCore
import SwiftUI

struct BrowserSettings: View {
    @State private var refresh = 0
    @State private var error: String?
    private let installer = NativeHostInstaller()

    /// The host sits next to the app executable (inside the .app, or in the SwiftPM build folder).
    private var hostPath: URL? {
        let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MacIDMHost")
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    private var extensionFolder: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension/chrome"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return nil
    }

    var body: some View {
        Form {
            Section("1. Connect MacIDM to your browsers") {
                if let hostPath {
                    ForEach(NativeHostInstaller.browsers) { browser in
                        browserRow(browser, hostPath: hostPath)
                    }
                    .id(refresh)
                    Text("Re-install after moving MacIDM.app to another folder.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The MacIDMHost helper wasn't found next to the app. Build with scripts/make-app.sh.")
                        .foregroundStyle(.red)
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }
            Section("2. Add the extension") {
                Text("In Chrome, Edge or Brave: open the extensions page, turn on Developer mode, click “Load unpacked” and choose the extension folder.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show Extension Folder") {
                        if let extensionFolder { NSWorkspace.shared.activateFileViewerSelecting([extensionFolder]) }
                    }
                    .disabled(extensionFolder == nil)
                    Button("Copy chrome://extensions") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("chrome://extensions", forType: .string)
                    }
                }
                Text("Then right-click any link and choose “Download with MacIDM”. Automatic capture by file type can be turned on in the extension’s options.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("The extension sends the page address (Referer) and only the cookies for the file you’re downloading, so normal logged-in downloads work. Nothing is sent from private windows. Cookies are deleted once the download finishes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func browserRow(_ browser: NativeHostInstaller.Browser, hostPath: URL) -> some View {
        let present = installer.isBrowserPresent(browser)
        let installed = installer.isInstalled(browser, hostPath: hostPath)
        HStack {
            Text(browser.name)
            if !present { Text("not found").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if installed {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Remove") { run { try installer.uninstall(browser) } }
            } else {
                Button("Install") { run { try installer.install(browser, hostPath: hostPath) } }
                    .disabled(!present)
            }
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
        refresh += 1
    }
}
