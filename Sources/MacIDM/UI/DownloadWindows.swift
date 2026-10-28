import AppKit
import MacIDMCore
import SwiftUI

/// IDM's "Download File Info": confirm the name, category and folder before a download starts.
struct ConfirmDownloadView: View {
    @EnvironmentObject private var state: AppState
    let url: URL
    let headers: [String: String]
    let close: () -> Void

    @State private var fileName: String
    @State private var category: MacIDMCore.Category
    @State private var folder: URL
    @State private var customFolder = false
    @State private var nameEdited = false
    @State private var size: Int64?
    @State private var resumable: Bool?
    @State private var checking = true

    init(url: URL, headers: [String: String], suggestedName: String, close: @escaping () -> Void) {
        self.url = url
        self.headers = headers
        self.close = close
        let name = suggestedName.isEmpty ? FileNaming.fileName(contentDisposition: nil, url: url) : suggestedName
        let category = MacIDMCore.Category.from(fileName: name)
        _fileName = State(initialValue: name)
        _category = State(initialValue: category)
        _folder = State(initialValue: AppState.categoryFolder(category))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: category.symbolName).font(.system(size: 30)).foregroundStyle(.tint).frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download File Info").font(.headline)
                    Text(url.absoluteString).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("File name").foregroundStyle(.secondary)
                    TextField("File name", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: fileName) { _ in nameEdited = true }
                }
                GridRow {
                    Text("Category").foregroundStyle(.secondary)
                    Picker("", selection: $category) {
                        ForEach(MacIDMCore.Category.allCases) { Label($0.rawValue, systemImage: $0.symbolName).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: category) { c in if !customFolder { folder = AppState.categoryFolder(c) } }
                }
                GridRow {
                    Text("Save to").foregroundStyle(.secondary)
                    HStack {
                        Text(folder.path).lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(folder.path)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if checking { ProgressView().controlSize(.small) }
                        Text(sizeText).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Download Later") { start(now: false) }
                Button("Start Download") { start(now: true) }.keyboardShortcut(.defaultAction)
            }
            .disabled(FileNaming.sanitize(fileName).isEmpty)
        }
        .padding(18)
        .frame(width: 520)
        .task { await probe() }
    }

    private var sizeText: String {
        if checking { return "Checking…" }
        let s = size.map(Format.bytes) ?? "Unknown"
        switch resumable {
        case .some(true): return "\(s) · resumable, segmented download"
        case .some(false): return "\(s) · server doesn't support resuming"
        case .none: return s
        }
    }

    private func probe() async {
        let probe = try? await ProbeService(session: .shared, userAgent: AppState.currentConfig().userAgent)
            .probe(url, headers: headers)
        checking = false
        guard let probe else { return }
        size = probe.totalSize
        resumable = probe.acceptsRanges
        if !nameEdited {
            fileName = probe.suggestedFileName
            nameEdited = false
            category = MacIDMCore.Category.from(fileName: probe.suggestedFileName)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            customFolder = true
        }
    }

    private func start(now: Bool) {
        let id = state.add(urlString: url.absoluteString, fileName: fileName, folder: folder,
                           startNow: now, headers: headers, category: category)
        close()
        if now, let id { state.showProgressWindowIfEnabled(id) }
    }
}

/// Download box for a video quality picked from the on-page menu.
struct ConfirmMediaView: View {
    @EnvironmentObject private var state: AppState
    let url: URL
    let title: String
    let headers: [String: String]
    let options: [FormatsResponse.Choice]
    let close: () -> Void

    @State private var code: String
    @State private var folder: URL?

    init(url: URL, title: String, headers: [String: String], initial: MediaChoice,
         options: [FormatsResponse.Choice], close: @escaping () -> Void) {
        self.url = url
        self.title = title
        self.headers = headers
        // Always offer the picked quality, even if the list wasn't cached.
        self.options = options.contains { $0.code == initial.code } ? options
            : [FormatsResponse.Choice(code: initial.code, label: FormatsResponse.label(initial), size: nil)] + options
        self.close = close
        _code = State(initialValue: initial.code)
    }

    private var choice: MediaChoice { MediaChoice(code: code) ?? .best }
    private var selected: FormatsResponse.Choice {
        options.first { $0.code == code } ?? FormatsResponse.Choice(code: code, label: FormatsResponse.label(choice), size: nil)
    }
    private var targetFolder: URL { folder ?? AppState.categoryFolder(choice.isAudio ? .music : .video) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: choice.isAudio ? "music.note" : "play.rectangle.fill")
                    .font(.system(size: 30)).foregroundStyle(.tint).frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(2)
                    Text(url.absoluteString).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    // Already picked on the page; shown, not asked again.
                    Text("Quality").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(selected.label).fontWeight(.medium)
                        if let size = selected.size {
                            Text(Format.bytes(size)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                GridRow {
                    Text("Save to").foregroundStyle(.secondary)
                    HStack {
                        Text(targetFolder.path).lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading).help(targetFolder.path)
                        Button("Choose…", action: chooseFolder)
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
        .frame(width: 520)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = targetFolder
        panel.prompt = "Save Here"
        if panel.runModal() == .OK { folder = panel.url }
    }

    private func start(now: Bool) {
        let id = state.addMedia(url: url, choice: choice, title: title, folder: folder, headers: headers, startNow: now)
        close()
        if now { state.showProgressWindowIfEnabled(id) }
    }
}

/// IDM-style download window: "Download status / Speed Limiter / Options on completion" tabs,
/// a progress bar, and (under Show details) the per-connection map and table.
struct ProgressWindowView: View {
    @EnvironmentObject private var state: AppState
    let id: UUID
    let close: () -> Void

    enum Tab: String, CaseIterable { case status = "Download status", limiter = "Speed Limiter", completion = "Options on completion" }
    @State private var tab: Tab = .status
    /// Details start hidden in every window; "Show details >>" opens them.
    @State private var showDetails = false
    @State private var limitOn = false
    @State private var limitKB = 1024

    var body: some View {
        Group {
            if let item = state.item(id) {
                content(item)
            } else {
                Text("This download was removed.").padding(30).frame(width: 540)
            }
        }
        .onAppear {
            if let cap = state.item(id)?.speedLimit { limitOn = true; limitKB = Int(cap / 1024) }
        }
    }

    private func content(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            GroupBox {
                Group {
                    switch tab {
                    case .status: statusTab(item)
                    case .limiter: limiterTab(item)
                    case .completion: completionTab(item)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                .padding(6)
            }

            ProgressView(value: item.progress ?? 0)
                .progressViewStyle(.linear)
                .tint(item.status == .failed ? .red : .green)
                .scaleEffect(x: 1, y: 2.2, anchor: .center)
                .padding(.vertical, 4)
                .opacity(item.totalSize == nil && item.status.isActive ? 0.4 : 1)

            buttons(item)

            if showDetails {
                Text(item.media == nil ? "Start positions and download progress by connections"
                                       : "Download progress by stream")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                SegmentBar(item: item, height: 16)
                ConnectionsTable(item: item)
                    .frame(height: min(CGFloat(max(item.segments.count, 3)) * 24 + 28, 200))
            }
        }
        .padding(16)
        .frame(width: 540)
    }

    private func statusTab(_ item: DownloadItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text(item.url.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .gridCellColumns(2)
            }
            .padding(.bottom, 4)
            row("Status") { statusText(item) }
            row("File size") { Text(item.totalSize.map(Format.bytes) ?? "Unknown") }
            row("Downloaded") {
                Text(Format.bytes(item.downloadedBytes) + (item.progress.map { String(format: " (%.2f %%)", $0 * 100) } ?? ""))
            }
            row("Transfer rate") { Text(item.status == .downloading ? Format.speed(item.speed) : "—") }
            row("Time left") { Text(item.eta.map(Format.duration) ?? "—") }
            row("Resume capability") {
                Text(item.media != nil ? "Yes" : item.acceptsRanges ? "Yes" : item.segments.isEmpty ? "Unknown" : "No")
            }
            if let saved = item.savedPath {
                row("Saved to") { Text(saved.path).lineLimit(1).truncationMode(.head) }
            }
        }
        .monospacedDigit()
    }

    private func statusText(_ item: DownloadItem) -> some View {
        let (text, color): (String, Color) = {
            switch item.status {
            case .queued: return ("Waiting in queue", .secondary)
            case .probing: return ("Connecting…", .blue)
            case .downloading: return ("Receiving data…", .blue)
            case .merging: return ("Joining parts…", .blue)
            case .paused: return (item.errorMessage ?? "Paused", item.errorMessage == nil ? .orange : .red)
            case .completed: return ("Download complete", .green)
            case .failed: return (item.errorMessage ?? "Failed", .red)
            case .cancelled: return ("Stopped", .secondary)
            }
        }()
        return Text(text).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private func limiterTab(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Limit the speed of this download", isOn: $limitOn)
            HStack {
                Text("Maximum speed")
                SpeedField(kilobytesPerSecond: $limitKB)
            }
            .disabled(!limitOn)
            Text(item.media == nil
                 ? "This applies on top of the global limit in Settings. Changes take effect immediately."
                 : "For videos, the limit takes effect when the download starts or resumes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: limitOn) { _ in applyLimit() }
        .onChange(of: limitKB) { _ in if limitOn { applyLimit() } }
    }

    private func applyLimit() {
        state.setSpeedLimit(id, kilobytesPerSecond: limitOn ? limitKB : nil)
    }

    private func completionTab(_ item: DownloadItem) -> some View {
        let binding = Binding(get: { state.completionOptions[id] ?? .init() },
                              set: { state.completionOptions[id] = $0 })
        return VStack(alignment: .leading, spacing: 10) {
            Text("When this download finishes:")
            Toggle("Open the file", isOn: binding.openFile)
            Toggle("Show it in Finder", isOn: binding.showInFinder)
            Toggle("Close this window", isOn: binding.closeWindow)
        }
        .disabled(item.status == .completed)
    }

    @ViewBuilder
    private func buttons(_ item: DownloadItem) -> some View {
        HStack {
            Button(showDetails ? "<< Hide details" : "Show details >>") { showDetails.toggle() }
            Spacer()
            if item.status == .completed {
                Button("Open Folder") { state.reveal(id) }
                Button("Open") { state.open(id); close() }.keyboardShortcut(.defaultAction)
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            } else {
                if item.status.isActive || item.status == .queued {
                    Button("Pause") { state.pause([id]) }.frame(minWidth: 80)
                } else {
                    Button("Resume") { state.resume([id]) }.keyboardShortcut(.defaultAction)
                }
                Button("Cancel") { state.cancel([id]); close() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func row<V: View>(_ title: String, @ViewBuilder value: () -> V) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            value()
        }
    }
}

/// N. / Downloaded / Info for each connection, like IDM's details list.
private struct ConnectionsTable: View {
    let item: DownloadItem

    struct Row: Identifiable {
        let id: Int
        let downloaded: String
        let info: String
    }

    private var rows: [Row] {
        item.segments.sorted { $0.start < $1.start }.enumerated().map { n, seg in
            let info = info(for: seg)
            return Row(id: n + 1, downloaded: Format.bytes(seg.downloaded),
                       info: item.media == nil ? info : "\(streamName(n)) — \(info)")
        }
    }

    /// yt-dlp fetches the picture first, then the sound; audio-only downloads have one stream.
    private func streamName(_ n: Int) -> String {
        if item.media?.choice.isAudio == true { return "Audio stream" }
        return n == 0 ? "Video stream" : n == 1 ? "Audio stream" : "Stream \(n + 1)"
    }

    private func info(for seg: Segment) -> String {
        if seg.isComplete || item.status == .completed { return "Complete" }
        switch item.status {
        case .probing: return "Connecting…"
        case .downloading: return seg.downloaded == 0 ? "Send GET…" : "Receiving data…"
        case .paused, .cancelled: return "Paused"
        case .failed: return "Error"
        case .queued: return "Waiting"
        default: return ""
        }
    }

    var body: some View {
        Table(rows) {
            TableColumn("N.") { Text("\($0.id)").monospacedDigit() }.width(32)
            TableColumn("Downloaded") { Text($0.downloaded).monospacedDigit() }.width(110)
            TableColumn("Info") { Text($0.info) }
        }
    }
}
