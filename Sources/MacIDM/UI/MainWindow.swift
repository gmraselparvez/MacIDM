import MacIDMCore
import SwiftUI

enum SidebarFilter: Hashable {
    case all, downloading, queued, completed, unfinished
    case category(MacIDMCore.Category)

    func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: return true
        case .downloading: return item.status.isActive
        case .queued: return item.status == .queued
        case .completed: return item.status == .completed
        case .unfinished: return item.status != .completed && !item.status.isActive && item.status != .queued
        case .category(let c): return item.category == c
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject private var state: AppState
    @State private var filter: SidebarFilter? = .all
    @State private var selection = Set<UUID>()
    @State private var showingAdd = false
    @State private var showingGrab = false
    @State private var showingBatch = false
    @State private var transferMessage: String?
    @State private var confirmDelete = false

    @State private var search = ""

    private var visible: [DownloadItem] {
        state.items.filter { item in
            (filter ?? .all).matches(item) && (search.isEmpty
                || item.displayName.localizedCaseInsensitiveContains(search)
                || item.url.absoluteString.localizedCaseInsensitiveContains(search))
        }
    }

    private var selectedItems: [DownloadItem] { state.items.filter { selection.contains($0.id) } }

    private var title: String {
        switch filter ?? .all {
        case .all: return "All Downloads"
        case .downloading: return "Downloading"
        case .queued: return "Queued"
        case .completed: return "Completed"
        case .unfinished: return "Unfinished"
        case .category(let c): return c.rawValue
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $filter) {
                Section("Library") {
                    row("All Downloads", "tray.full", .all)
                    row("Downloading", "arrow.down.circle", .downloading)
                    row("Queued", "clock", .queued)
                    row("Completed", "checkmark.circle", .completed)
                    row("Unfinished", "pause.circle", .unfinished)
                }
                Section("Categories") {
                    ForEach(MacIDMCore.Category.allCases) { c in
                        row(c.rawValue, c.symbolName, .category(c))
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                if visible.isEmpty {
                    EmptyDownloadsView(filtered: !state.items.isEmpty || !search.isEmpty,
                                       add: { showingAdd = true }, grab: { showingGrab = true })
                } else {
                    list
                }
                if let item = selectedItems.count == 1 ? selectedItems.first : nil, item.errorMessage != nil {
                    Divider()
                    DownloadDetail(item: item).frame(maxHeight: 190)
                }
                StatusBar()
            }
            .navigationTitle(title)
            .navigationSubtitle(visible.isEmpty ? "" : "\(visible.count) item\(visible.count == 1 ? "" : "s")")
            .searchable(text: $search, placement: .toolbar, prompt: "Search downloads")
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showingAdd) { AddDownloadSheet() }
        .sheet(isPresented: $showingGrab) { GrabVideoSheet() }
        .sheet(isPresented: $showingBatch) { BatchDownloadSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .downloadCommand)) { note in
            (note.object as? String).flatMap(DownloadCommand.init(rawValue:)).map(handle)
        }
        .alert(transferMessage ?? "", isPresented: Binding(get: { transferMessage != nil }, set: { if !$0 { transferMessage = nil } })) {
            Button("OK") { transferMessage = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGrabVideo)) { _ in showingGrab = true }
        .onReceive(NotificationCenter.default.publisher(for: .showAddDownload)) { _ in showingAdd = true }
        .onDrop(of: [.url, .plainText], isTargeted: nil) { providers in
            DropHandler.load(providers) { urls in urls.forEach { state.add(urlString: $0) } }
            return true
        }
        .alert("Download this link?", isPresented: Binding(
            get: { state.pendingClipboardURL != nil },
            set: { if !$0 { state.pendingClipboardURL = nil } })
        ) {
            Button("Download…") {
                if let s = state.pendingClipboardURL, let url = URL(string: s) { state.showConfirm(url: url) }
                state.pendingClipboardURL = nil
            }
            Button("Add to Queue") {
                if let url = state.pendingClipboardURL { state.add(urlString: url, startNow: false) }
                state.pendingClipboardURL = nil
            }
            Button("Ignore", role: .cancel) { state.pendingClipboardURL = nil }
        } message: {
            Text(state.pendingClipboardURL ?? "")
        }
        .confirmationDialog("Remove \(selection.count) download(s)?", isPresented: $confirmDelete) {
            Button("Remove from List") { state.remove(selection, deleteFiles: false); selection = [] }
            Button("Remove and Move Files to Trash", role: .destructive) { state.remove(selection, deleteFiles: true); selection = [] }
        }
    }

    private func handle(_ command: DownloadCommand) {
        switch command {
        case .batch: showingBatch = true
        case .pinterest: state.showPinterest()
        case .importList: importList()
        case .exportList: exportList()
        case .resume: state.resume(selection)
        case .pause: state.pause(selection)
        case .stop: state.cancel(selection)
        case .startNow: state.startNow(selection)
        case .resumeAll: state.resumeAll()
        case .pauseAll: state.pauseAll()
        case .open: selection.forEach { if state.item($0)?.status == .completed { state.open($0) } }
        case .reveal: selection.first.map(state.reveal)
        }
    }

    private func importList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let n = try state.importList(from: url)
            transferMessage = n == 0 ? "No new downloads found in that file." : "Imported \(n) download\(n == 1 ? "" : "s") into the queue."
        } catch {
            transferMessage = "Couldn't import: \(error.localizedDescription)"
        }
    }

    private func exportList() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json, .plainText]
        panel.nameFieldStringValue = "MacIDM downloads.json"
        panel.message = "Save as .json to keep names and settings, or .txt for a plain list of links. Cookies are never exported."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try state.exportList(to: url) } catch { transferMessage = "Couldn't export: \(error.localizedDescription)" }
    }

    /// Finder-style row: a plain symbol tinted with the system accent color.
    private func row(_ title: String, _ symbol: String, _ value: SidebarFilter) -> some View {
        Label(title, systemImage: symbol).tag(value)
    }

    private var list: some View {
        List(visible, selection: $selection) { item in
            DownloadCard(item: item).tag(item.id)
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Resume") { state.resume(ids) }
            Button("Start Now") { state.startNow(ids) }
            Button("Add to Scheduled Queue") { state.addToScheduledQueue(ids) }
            Button("Pause") { state.pause(ids) }
            Button("Stop") { state.cancel(ids) }
            Divider()
            if ids.count == 1, let id = ids.first {
                Button("Show Download Window") { state.showProgressWindow(id) }
                Button("Open") { state.open(id) }
                    .disabled(state.item(id)?.status != .completed)
                Button("Show in Finder") { state.reveal(id) }
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.item(id)?.url.absoluteString ?? "", forType: .string)
                }
                Divider()
            }
            Button("Remove…") { selection = ids; confirmDelete = true }
        } primaryAction: { ids in
            // Double-click: open finished files, otherwise show the download window.
            guard let id = ids.first else { return }
            if state.item(id)?.status == .completed { state.open(id) } else { state.showProgressWindow(id) }
        }
        .onDeleteCommand { if !selection.isEmpty { confirmDelete = true } }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { showingAdd = true } label: { Label("Add URL", systemImage: "plus") }
                .help("Add a download (⌘N)")
            Button { showingGrab = true } label: { Label("Grab Video", systemImage: "play.rectangle.on.rectangle") }
                .help("Download video or audio from a web page (⇧⌘N)")
            Button { showingBatch = true } label: { Label("Batch", systemImage: "list.bullet.rectangle") }
                .help("Download a list of links or a numbered pattern (⌥⌘N)")
            Button { state.resume(selection) } label: { Label("Resume", systemImage: "play.fill") }
                .disabled(!selectedItems.contains { $0.status.canResume })
            Button { state.pause(selection) } label: { Label("Pause", systemImage: "pause.fill") }
                .disabled(!selectedItems.contains { $0.status.isActive || $0.status == .queued })
            Button { state.cancel(selection) } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(!selectedItems.contains { $0.status != .completed && $0.status != .cancelled })
            Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                .disabled(selection.isEmpty)
            SettingsLink14()
        }
    }
}

enum DropHandler {
    /// Collects http(s) URLs from dropped links or text (one per line).
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([String]) -> Void) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
                    let s = url.absoluteString
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion([s]) } }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    let links = (text ?? "").split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { URL(string: $0)?.host != nil && $0.lowercased().hasPrefix("http") }
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion(links) } }
                }
            }
        }
    }
}

/// Opens the Settings window on macOS 13 and 14+.
struct SettingsLink14: View {
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: { Label("Settings", systemImage: "gearshape") }
        }
    }
}
