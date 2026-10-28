import AppKit
import MacIDMCore
import SwiftUI

struct BrowserSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var refresh = 0
    @State private var error: String?
    @State private var guideFor: NativeHostInstaller.Browser?
    private let installer = NativeHostInstaller()
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Text("Adds “Download with MacIDM” to the right-click menu, a “Download this video” button on videos, and optional automatic capture of downloads.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Browsers") {
                if let hostPath = state.hostPath {
                    ForEach(NativeHostInstaller.browsers) { browser in
                        browserRow(browser, hostPath: hostPath)
                    }
                    .id(refresh)
                } else {
                    Text("The MacIDMHost helper is missing from the app. Rebuild it with scripts/make-app.sh.")
                        .foregroundStyle(.red)
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }
            if let browser = guideFor {
                Section("Finish in \(browser.name)") { guide(browser) }
            }
            Section {
                Text("Browsers only add extensions on their own from their web store, so the last step is a click in the browser. MacIDM opens the right page and copies the folder path for you.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Privacy: the extension sends the page address and only the cookies for the file being downloaded. Nothing is sent from private windows.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onReceive(poll) { _ in
            // Notice when the user finishes adding the extension.
            if let browser = guideFor, extensionReady(browser) { guideFor = nil }
            refresh += 1
        }
    }

    @ViewBuilder
    private func browserRow(_ browser: NativeHostInstaller.Browser, hostPath: URL) -> some View {
        let present = installer.isBrowserPresent(browser)
        let helper = installer.isInstalled(browser, hostPath: hostPath)
        let ext = extensionReady(browser)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(browser.name)
                Group {
                    if !present { Text("Not installed on this Mac") }
                    else if helper && ext { Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else if helper { Text("Extension not added yet").foregroundStyle(.orange) }
                    else { Text("Not set up") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if present {
                if helper && ext {
                    Button("Remove") { run { try installer.uninstall(browser) } }
                } else {
                    Button(helper ? "Add Extension…" : "Set Up") {
                        run {
                            try state.setUpBrowser(browser)
                            guideFor = browser
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func guide(_ browser: NativeHostInstaller.Browser) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(browser.name) has opened its Extensions page. There:")
            Label("Turn on **Developer mode** (top right).", systemImage: "1.circle.fill")
            Label("Click **Load unpacked**.", systemImage: "2.circle.fill")
            Label("Press **⇧⌘G**, then **⌘V** to paste the folder path (already copied), press Return, then click **Select**.",
                  systemImage: "3.circle.fill")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppState.installedExtensionFolder])
                }
                Button("Copy Path Again") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppState.installedExtensionFolder.path, forType: .string)
                }
                Spacer()
                ProgressView().controlSize(.small)
                Text("Waiting for the extension…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func extensionReady(_ browser: NativeHostInstaller.Browser) -> Bool {
        ExtensionHeartbeat().lastSeen(browser.name) != nil || installer.isExtensionInstalled(browser)
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
        refresh += 1
    }
}
