import AppKit
import MacIDMCore
import SwiftUI

/// Paste a Pinterest pin, board or pin.it link → choose images and/or videos → queue them all.
struct PinterestView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let onClose: (() -> Void)?
    let autoFetch: Bool
    /// Cookies and user agent from the browser, when opened from there.
    let browserHeaders: [String: String]
    @State private var urlString: String
    @State private var collection: PinterestService.Collection?
    @State private var loading = false
    @State private var error: String?
    @State private var includeImages = true
    @State private var includeVideos = true
    @State private var folder: URL?

    init(initialURL: String = "", autoFetch: Bool = false, browserHeaders: [String: String] = [:], onClose: (() -> Void)? = nil) {
        _urlString = State(initialValue: initialURL)
        self.autoFetch = autoFetch
        self.browserHeaders = browserHeaders
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download from Pinterest").font(.title2.bold())
            HStack {
                TextField("Pin, board or pin.it link", text: $urlString,
                          prompt: Text("https://www.pinterest.com/username/board-name/"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(fetch)
                Button(loading ? "Loading…" : "Fetch", action: fetch).disabled(loading || link == nil)
            }
            if loading { ProgressView().controlSize(.small) }
            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let c = collection {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(c.isBoard ? "Board" : "Pin", systemImage: c.isBoard ? "square.grid.3x3" : "pin")
                                .foregroundStyle(.secondary)
                            Text(c.title).font(.headline).lineLimit(1)
                        }
                        Toggle("Images (\(c.images.count)) — original resolution", isOn: $includeImages)
                            .disabled(c.images.isEmpty)
                        Toggle("Videos (\(c.videos.count))", isOn: $includeVideos)
                            .disabled(c.videos.isEmpty)
                        LabeledContent("Save to") {
                            HStack {
                                Text(targetFolder(c).path).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Button("Choose…") { chooseFolder(c) }
                            }
                        }
                    }
                    .padding(6)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: finish).keyboardShortcut(.cancelAction)
                Button("Add to Queue") { start(now: false) }.disabled(selectedCount == 0)
                Button(selectedCount > 0 ? "Download \(selectedCount)" : "Download") { start(now: true) }
                    .keyboardShortcut(.defaultAction).disabled(selectedCount == 0)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            if autoFetch { fetch(); return }
            if urlString.isEmpty, let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: clip), PinterestService.isPinterest(url) {
                urlString = clip
            }
        }
        .onChange(of: urlString) { _ in collection = nil; error = nil }
    }

    private var link: URL? {
        URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { PinterestService.isPinterest($0) ? $0 : nil }
    }

    private var selectedCount: Int {
        guard let c = collection else { return 0 }
        return (includeImages ? c.images.count : 0) + (includeVideos ? c.videos.count : 0)
    }

    /// Boards get their own folder: <downloads>/Pinterest/<board name>.
    private func targetFolder(_ c: PinterestService.Collection) -> URL {
        if let folder { return folder }
        let root = AppState.currentConfig().downloadsRoot.appendingPathComponent("Pinterest", isDirectory: true)
        return c.isBoard ? root.appendingPathComponent(FileNaming.sanitize(c.title), isDirectory: true) : root
    }

    private func fetch() {
        guard let url = link else {
            error = "Paste a Pinterest pin, board or pin.it link."
            return
        }
        loading = true
        error = nil
        collection = nil
        Task {
            do {
                // Signed in (cookies from the browser) when we have them: Pinterest shows signed-out
                // visitors only part of a board. Keep the browser's user agent with its cookies.
                let service = PinterestService(userAgent: browserHeaders["User-Agent"] ?? AppState.currentConfig().userAgent,
                                               cookie: browserHeaders["Cookie"])
                collection = try await service.fetch(url)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func chooseFolder(_ c: PinterestService.Collection) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = targetFolder(c)
        panel.prompt = "Save Here"
        if panel.runModal() == .OK { folder = panel.url }
    }

    private func start(now: Bool) {
        guard let c = collection else { return }
        state.addPinterest(c, images: includeImages, videos: includeVideos, folder: targetFolder(c), startNow: now)
        finish()
    }

    private func finish() {
        if let onClose { onClose() } else { dismiss() }
    }
}

/// Confirms a batch of files picked in the browser (e.g. the image grabber), then queues them.
struct ConfirmBatchView: View {
    @EnvironmentObject private var state: AppState
    let urls: [URL]
    let pageURL: URL
    let close: () -> Void
    @State private var folder: URL?

    private var defaultFolder: URL {
        AppState.categoryFolder(.images).appendingPathComponent(FileNaming.sanitize(pageURL.host ?? "web"), isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "photo.stack").font(.system(size: 28)).foregroundStyle(.tint).frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download \(urls.count) file\(urls.count == 1 ? "" : "s")").font(.headline)
                    Text("From \(pageURL.host ?? pageURL.absoluteString)").font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Save to") {
                HStack {
                    Text((folder ?? defaultFolder).path).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.prompt = "Save Here"
                        if panel.runModal() == .OK { folder = panel.url }
                    }
                }
            }
            HStack {
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Download Later") { start(now: false) }
                Button("Start Download") { start(now: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 500)
    }

    private func start(now: Bool) {
        state.addFiles(urls, folder: folder ?? defaultFolder, referrer: pageURL, startNow: now)
        close()
    }
}
