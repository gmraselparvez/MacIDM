import AppKit
import Foundation
import MacIDMCore
import ServiceManagement

enum SettingsKey {
    static let segments = "segments"
    static let downloadFolder = "downloadFolder"
    static let retries = "retries"
    static let userAgent = "userAgent"
    static let maxConcurrent = "maxConcurrent"
    static let speedLimitEnabled = "speedLimitEnabled"
    static let speedLimitKBps = "speedLimitKBps"
    static let clipboardWatcher = "clipboardWatcher"
    static let scheduleEnabled = "scheduleEnabled"
    static let scheduleStart = "scheduleStartMinute"
    static let scheduleStopEnabled = "scheduleStopEnabled"
    static let scheduleStop = "scheduleStopMinute"
    static let sleepWhenDone = "sleepWhenDone"
    static let notifications = "notifications"
    static let askBeforeDownload = "askBeforeDownload"
    static let showProgressWindow = "showProgressWindow"
    static let shortcutPinterest = "shortcutPinterest"
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    /// A copied link waiting for the user to confirm.
    @Published var pendingClipboardURL: String?
    /// True while a scheduled run is in progress (queue started by the scheduler).
    @Published private(set) var scheduledRunActive = false

    private let store = DownloadStore()
    private let engine: DownloadEngine
    private var saveTask: Task<Void, Never>?

    private let clipboard = ClipboardWatcher()
    private let network = NetworkMonitor()
    private let notifier = Notifier()
    let windows = WindowPresenter()
    private let shortcuts = GlobalShortcuts()
    /// False when another app already uses the Pinterest shortcut.
    @Published private(set) var pinterestShortcutRegistered = true
    private var scheduleTimer: Timer?
    private var lastScheduleCheck = Date()
    /// Queued items the user explicitly started; they ignore the schedule.
    private var manualStart = Set<UUID>()
    /// Set while the Mac is going to sleep so nothing new starts.
    private var suspended = false

    private var defaults: UserDefaults { .standard }

    static var defaultDownloadFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacIDM", isDirectory: true)
    }

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.segments: 8,
            SettingsKey.downloadFolder: Self.defaultDownloadFolder.path,
            SettingsKey.retries: 5,
            SettingsKey.userAgent: EngineConfig.safariUserAgent,
            SettingsKey.maxConcurrent: 3,
            SettingsKey.speedLimitEnabled: false,
            SettingsKey.speedLimitKBps: 1024,
            SettingsKey.clipboardWatcher: false,
            SettingsKey.scheduleEnabled: false,
            SettingsKey.scheduleStart: 2 * 60,
            SettingsKey.scheduleStopEnabled: false,
            SettingsKey.scheduleStop: 7 * 60,
            SettingsKey.sleepWhenDone: false,
            SettingsKey.notifications: true,
            SettingsKey.askBeforeDownload: true,
            SettingsKey.showProgressWindow: true,
        ])
        engine = DownloadEngine(config: Self.currentConfig())
        items = DemoData.isEnabled ? DemoData.items() : store.load()
        if DemoData.isEnabled { suspended = true } // show, don't download

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSleep() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }

        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Inbox.notificationName), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainInbox() }
        }
        clipboard.onLink = { [weak self] link in self?.handleCopiedLink(link) }
        network.onRestored = { [weak self] in self?.requeueNetworkFailures() }
        network.start()
        notifier.requestAuthorization()

        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSchedule() }
        }
        // Older versions kept a single-file yt-dlp here; it unpacks Python on every run. Use the unpacked build.
        let legacy = MediaTools.managedBinDir.appendingPathComponent("yt-dlp")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDir), !isDir.boolValue {
            try? FileManager.default.removeItem(at: legacy)
            mediaTools = MediaTools.locate()
        }
        applySettings()
        registerShortcuts()
        BrowserTab.startTracking()
        loadYtdlpVersion()
        // Keep browser registrations and the extension copy pointing at this copy of the app.
        if let hostPath { NativeHostInstaller().refreshInstalled(hostPath: hostPath) }
        try? syncExtensionFolder()
        drainInbox()
        pump()
    }

    /// Picks up downloads sent by the browser extension via the native host.
    func drainInbox() {
        for request in Inbox().drain() {
            guard let (url, headers, fileName) = request.validated() else { continue }
            if request.type == "formats", let id = request.requestID {
                answerFormats(url: url, headers: headers, requestID: id)
            } else if request.type == "pinterest" {
                showPinterest(url: url.absoluteString)
            } else if request.type == "batch" {
                let files = request.batchURLs
                guard !files.isEmpty else { continue }
                if defaults.bool(forKey: SettingsKey.askBeforeDownload) {
                    windows.show(key: "batch-\(UUID().uuidString)", title: "Download Files", floating: true) { close in
                        ConfirmBatchView(urls: files, pageURL: url, close: close).environmentObject(self)
                    }
                } else {
                    addFiles(files, folder: Self.categoryFolder(.images).appendingPathComponent(FileNaming.sanitize(url.host ?? "web")),
                             referrer: url, startNow: true)
                }
            } else if request.isMedia, let code = request.choice, let choice = MediaChoice(code: code) {
                // Picked from the quality menu on the page.
                let title = fileName.isEmpty ? url.absoluteString : fileName
                if defaults.bool(forKey: SettingsKey.askBeforeDownload) {
                    showConfirmMedia(url: url, choice: choice, title: title, headers: headers)
                } else {
                    showProgressWindowIfEnabled(addMedia(url: url, choice: choice, title: title, headers: headers))
                }
            } else if request.isMedia {
                showGrabVideo(url: url.absoluteString, headers: headers)
            } else if defaults.bool(forKey: SettingsKey.askBeforeDownload) {
                showConfirm(url: url, headers: headers, suggestedName: fileName)
            } else if let id = add(urlString: url.absoluteString, fileName: fileName, headers: headers) {
                showProgressWindowIfEnabled(id)
            }
        }
    }

    /// Recent quality lists, so reloading a page or reopening the menu answers instantly.
    private var formatsCache: [URL: (date: Date, response: FormatsResponse)] = [:]

    /// Runs yt-dlp for the browser's quality menu and leaves the answer for the helper to relay.
    private func answerFormats(url: URL, headers: [String: String], requestID: String) {
        if let cached = formatsCache[url], Date().timeIntervalSince(cached.date) < 15 * 60 {
            try? Inbox().writeResponse(JSONEncoder().encode(cached.response), id: requestID)
            return
        }
        let tools = mediaTools
        Task {
            let response: FormatsResponse
            if let ytdlp = tools.ytdlp {
                do {
                    response = FormatsResponse(info: try await YTDLPService.fetchInfo(url: url, ytdlp: ytdlp, headers: headers,
                                                                                    jsRuntime: tools.jsRuntime))
                } catch {
                    response = FormatsResponse(error: error.localizedDescription)
                }
            } else {
                response = FormatsResponse(error: MediaError.toolMissing.localizedDescription)
            }
            if response.ok { formatsCache[url] = (Date(), response) }
            try? Inbox().writeResponse(JSONEncoder().encode(response), id: requestID)
        }
    }

    // MARK: - Windows

    /// Default folder for a category: `<download folder>/<Category>`.
    static func categoryFolder(_ category: MacIDMCore.Category) -> URL {
        currentConfig().downloadsRoot.appendingPathComponent(category.rawValue, isDirectory: true)
    }

    /// "Download File Info": choose name, category and folder before starting.
    func showConfirm(url: URL, headers: [String: String] = [:], suggestedName: String = "") {
        windows.show(key: "confirm-\(UUID().uuidString)", title: "Download File Info", floating: true) { close in
            ConfirmDownloadView(url: url, headers: headers, suggestedName: suggestedName, close: close)
                .environmentObject(self)
        }
    }

    /// Confirm a video download picked on the page: quality, folder, then Start / Later / Cancel.
    func showConfirmMedia(url: URL, choice: MediaChoice, title: String, headers: [String: String]) {
        let options = formatsCache[url]?.response.choices ?? []
        windows.show(key: "confirm-media-\(UUID().uuidString)", title: "Download Video", floating: true) { close in
            ConfirmMediaView(url: url, title: title, headers: headers, initial: choice, options: options, close: close)
                .environmentObject(self)
        }
    }

    func showProgressWindow(_ id: UUID) {
        windows.show(key: "progress-\(id.uuidString)", title: item(id)?.displayName ?? "Download") { close in
            ProgressWindowView(id: id, close: close).environmentObject(self)
        }
    }

    func showProgressWindowIfEnabled(_ id: UUID) {
        if defaults.bool(forKey: SettingsKey.showProgressWindow) { showProgressWindow(id) }
    }

    /// The video grabber as its own window, pre-filled and fetching right away.
    func showGrabVideo(url: String = "", headers: [String: String] = [:]) {
        windows.show(key: "grab-\(url)", title: "Grab Video") { close in
            GrabVideoSheet(initialURL: url, headers: headers, autoFetch: !url.isEmpty, onClose: close)
                .environmentObject(self)
        }
    }

    /// yt-dlp and ffmpeg locations; refreshed after an update.
    @Published private(set) var mediaTools = MediaTools.locate()

    @Published private(set) var ytdlpVersion: String?
    @Published private(set) var checkingYtdlpVersion = false
    @Published private(set) var updatingYtdlp = false
    @Published private(set) var ytdlpUpdateMessage: String?

    func refreshMediaTools() {
        mediaTools = MediaTools.locate()
        applySettings()
        loadYtdlpVersion()
    }

    /// yt-dlp unpacks itself on every run (~5–10 s), so the version is loaded once and kept.
    func loadYtdlpVersion() {
        guard let ytdlp = mediaTools.ytdlp else { ytdlpVersion = nil; return }
        checkingYtdlpVersion = true
        Task {
            let version = await YTDLPService.version(ytdlp)
            if let version { ytdlpVersion = version }
            checkingYtdlpVersion = false
        }
    }

    func updateYtdlp() {
        guard !updatingYtdlp else { return }
        updatingYtdlp = true
        ytdlpUpdateMessage = nil
        Task {
            do {
                if let installed = try await YTDLPService.installLatest(currentVersion: ytdlpVersion) {
                    ytdlpUpdateMessage = "Updated to \(installed)."
                } else {
                    ytdlpUpdateMessage = "You have the latest version."
                }
            } catch {
                ytdlpUpdateMessage = error.localizedDescription
            }
            updatingYtdlp = false
            refreshMediaTools()
        }
    }

    // MARK: - Global shortcuts

    /// The saved Pinterest shortcut; nil when turned off. Defaults to ⌥⇧P.
    var pinterestShortcut: KeyCombo? {
        get {
            guard let data = defaults.data(forKey: SettingsKey.shortcutPinterest) else { return .pinterestDefault }
            return (try? JSONDecoder().decode(KeyCombo?.self, from: data)) ?? .pinterestDefault
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: SettingsKey.shortcutPinterest)
            registerShortcuts()
            objectWillChange.send()
        }
    }

    private func registerShortcuts() {
        pinterestShortcutRegistered = shortcuts.register(id: 1, combo: pinterestShortcut) { [weak self] in
            self?.pinterestFromBrowser()
        }
    }

    /// The Pinterest shortcut: open the board or pin showing in the browser.
    func pinterestFromBrowser() {
        switch BrowserTab.currentURL() {
        case .success(let url) where PinterestService.isPinterest(url) && PinterestService.target(for: url) != nil:
            showPinterest(url: url.absoluteString)
        case .success:
            explain("Open a Pinterest board or pin first",
                    "The shortcut downloads the Pinterest board or pin showing in your browser's current tab.")
        case .failure(.notAllowed(let browser)):
            explain("Allow MacIDM to read \(browser)'s current tab",
                    "Open System Settings › Privacy & Security › Automation, and turn on \(browser) under MacIDM.",
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"))
        case .failure:
            explain("No browser window found", "Open a Pinterest board or pin in Chrome, Edge, Brave or Safari, then press the shortcut.")
        }
    }

    private func explain(_ title: String, _ message: String, settingsURL: URL? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if settingsURL != nil { alert.addButton(withTitle: "Open System Settings") }
        if alert.runModal() == .alertSecondButtonReturn, let settingsURL { NSWorkspace.shared.open(settingsURL) }
    }

    // MARK: - Open at login

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        objectWillChange.send()
    }

    // MARK: - Browser setup

    /// The helper sits next to the app executable (inside the .app, or in the SwiftPM build folder).
    var hostPath: URL? {
        let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MacIDMHost")
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    /// A copy of the extension in Application Support, so its path stays valid when the app moves or updates.
    static var installedExtensionFolder: URL {
        DownloadStore.appSupportDir.appendingPathComponent("BrowserExtension/chrome", isDirectory: true)
    }

    /// Copies the bundled extension to its stable folder when it's missing or out of date.
    @discardableResult
    func syncExtensionFolder() throws -> URL {
        let target = Self.installedExtensionFolder
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension/chrome"),
              FileManager.default.fileExists(atPath: bundled.path) else { return target }
        func version(_ dir: URL) -> String? {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) as? [String: Any])?["version"] as? String
        }
        if version(bundled) != version(target) {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundled, to: target)
        }
        return target
    }

    static let browserBundleIDs = [
        "Google Chrome": "com.google.Chrome", "Microsoft Edge": "com.microsoft.edgemac",
        "Brave": "com.brave.Browser", "Chromium": "org.chromium.Chromium",
    ]

    /// Registers the helper, puts the extension in place, and opens the browser's extensions page.
    func setUpBrowser(_ browser: NativeHostInstaller.Browser) throws {
        guard let hostPath else { throw CocoaError(.fileNoSuchFile) }
        try NativeHostInstaller().install(browser, hostPath: hostPath)
        let folder = try syncExtensionFolder()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(folder.path, forType: .string)
        if let id = Self.browserBundleIDs[browser.name],
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
           let page = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open([page], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Per-download options (IDM's Speed Limiter / Options on completion tabs)

    struct CompletionOptions: Equatable {
        var openFile = false
        var showInFinder = false
        var closeWindow = false
    }

    @Published var completionOptions: [UUID: CompletionOptions] = [:]

    /// nil removes the per-download cap.
    func setSpeedLimit(_ id: UUID, kilobytesPerSecond: Int?) {
        guard var item = item(id) else { return }
        item.speedLimit = kilobytesPerSecond.map { Int64(max(1, $0)) * 1024 }
        replace(item)
        scheduleSave(immediate: true)
        let cap = item.speedLimit
        Task { await engine.setSpeedLimit(id, bytesPerSecond: cap) }
    }

    private func runCompletionActions(_ item: DownloadItem) {
        guard let options = completionOptions.removeValue(forKey: item.id) else { return }
        if options.openFile { open(item.id) }
        if options.showInFinder { reveal(item.id) }
        if options.closeWindow { windows.close("progress-\(item.id.uuidString)") }
    }

    static func currentConfig() -> EngineConfig {
        let d = UserDefaults.standard
        let tools = MediaTools.locate()
        return EngineConfig(
            userAgent: d.string(forKey: SettingsKey.userAgent) ?? EngineConfig.safariUserAgent,
            retries: d.integer(forKey: SettingsKey.retries),
            downloadsRoot: URL(fileURLWithPath: d.string(forKey: SettingsKey.downloadFolder) ?? defaultDownloadFolder.path),
            partsRoot: DownloadStore.appSupportDir.appendingPathComponent("Parts", isDirectory: true),
            ytdlpPath: tools.ytdlp,
            ffmpegPath: tools.ffmpeg,
            jsRuntimePath: tools.jsRuntime)
    }

    /// Re-reads settings: engine config, speed limit, clipboard watcher, concurrency.
    func applySettings() {
        let config = Self.currentConfig()
        let limit: Int64 = defaults.bool(forKey: SettingsKey.speedLimitEnabled)
            ? Int64(max(1, defaults.integer(forKey: SettingsKey.speedLimitKBps))) * 1024 : 0
        Task {
            await engine.update(config: config)
            await engine.setSpeedLimit(bytesPerSecond: limit)
        }
        clipboard.setEnabled(defaults.bool(forKey: SettingsKey.clipboardWatcher))
        if !defaults.bool(forKey: SettingsKey.scheduleEnabled) { scheduledRunActive = false }
        pump()
    }

    func item(_ id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    var activeItems: [DownloadItem] { items.filter { $0.status.isActive } }
    var totalSpeed: Double { activeItems.reduce(0) { $0 + $1.speed } }
    var queuedCount: Int { items.filter { $0.status == .queued }.count }

    // MARK: - Actions

    /// Adds a download. `startNow` starts it as soon as a slot is free; otherwise it waits for the scheduler.
    @discardableResult
    func add(urlString: String, fileName: String = "", folder: URL? = nil, segments: Int? = nil, startNow: Bool = true,
             headers: [String: String]? = nil, category: MacIDMCore.Category? = nil) -> UUID? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        let count = segments ?? defaults.integer(forKey: SettingsKey.segments)
        var item = DownloadItem(url: url, fileName: FileNaming.sanitize(fileName), destinationDir: folder, requestedSegments: count)
        item.headers = headers?.isEmpty == false ? headers : nil
        if let category { item.category = category }
        items.insert(item, at: 0)
        if startNow { manualStart.insert(item.id) }
        scheduleSave(immediate: true)
        pump()
        return item.id
    }

    /// The Pinterest window as its own window (from the browser), fetching right away.
    func showPinterest(url: String = "") {
        windows.show(key: "pinterest-\(url)", title: "Download from Pinterest") { close in
            PinterestView(initialURL: url, autoFetch: !url.isEmpty, onClose: close).environmentObject(self)
        }
    }

    /// Queues the images and/or videos of a pin or board. Videos with a direct MP4 use the segmented
    /// engine; streaming-only ones go to the video grabber.
    func addPinterest(_ collection: PinterestService.Collection, images: Bool, videos: Bool, folder: URL, startNow: Bool) {
        let segments = defaults.integer(forKey: SettingsKey.segments)
        var new: [DownloadItem] = []
        let referer = ["Referer": "https://www.pinterest.com/"]
        for pin in collection.pins {
            if pin.isVideo {
                guard videos else { continue }
                if let mp4 = pin.videoURL {
                    var item = DownloadItem(url: mp4, fileName: PinterestService.fileName(for: pin, url: mp4),
                                            destinationDir: folder, requestedSegments: segments)
                    item.headers = referer
                    item.category = .video
                    new.append(item)
                } else {
                    var item = DownloadItem(url: pin.pageURL, fileName: pin.title.isEmpty ? "pin-\(pin.id)" : pin.title,
                                            destinationDir: folder)
                    item.media = MediaRequest(choice: .best, title: pin.title.isEmpty ? "pin-\(pin.id)" : pin.title)
                    item.category = .video
                    new.append(item)
                }
            } else if images, let image = pin.imageURL {
                var item = DownloadItem(url: image, fileName: PinterestService.fileName(for: pin, url: image),
                                        destinationDir: folder, requestedSegments: segments)
                item.headers = referer
                item.category = .images
                new.append(item)
            }
        }
        add(items: new, startNow: startNow)
    }

    /// Queues plain files picked in the browser (e.g. images from the image grabber).
    func addFiles(_ urls: [URL], folder: URL, referrer: URL?, startNow: Bool) {
        let segments = defaults.integer(forKey: SettingsKey.segments)
        add(items: urls.map { url in
            var item = DownloadItem(url: url, destinationDir: folder, requestedSegments: segments)
            if let referrer { item.headers = ["Referer": referrer.absoluteString] }
            return item
        }, startNow: startNow)
    }

    /// Adds many links at once. `startNow: false` leaves them queued for the scheduler.
    func addBatch(_ urls: [URL], startNow: Bool) {
        let segments = defaults.integer(forKey: SettingsKey.segments)
        add(items: urls.map { DownloadItem(url: $0, requestedSegments: segments) }, startNow: startNow)
    }

    private func add(items new: [DownloadItem], startNow: Bool) {
        // Oldest first in the queue, newest on top of the list.
        items.insert(contentsOf: new.reversed(), at: 0)
        if startNow { manualStart.formUnion(new.map(\.id)) }
        scheduleSave(immediate: true)
        pump()
    }

    // MARK: - Import / export

    func exportList(to url: URL) throws {
        let data = url.pathExtension.lowercased() == "txt"
            ? Data(ListTransfer.exportText(items).utf8)
            : try ListTransfer.exportJSON(items)
        try data.write(to: url, options: .atomic)
    }

    /// Imports a MacIDM export or a text list; imported items wait in the queue. Returns how many were added.
    @discardableResult
    func importList(from url: URL) throws -> Int {
        let imported = try ListTransfer.importItems(from: Data(contentsOf: url),
                                                    requestedSegments: defaults.integer(forKey: SettingsKey.segments))
        let existing = Set(items.filter { $0.status != .completed }.map(\.url))
        let new = imported.filter { !existing.contains($0.url) }
        add(items: new, startNow: false)
        return new.count
    }

    /// Adds a video/audio download handled by yt-dlp.
    @discardableResult
    func addMedia(url: URL, choice: MediaChoice, title: String, folder: URL? = nil, headers: [String: String]? = nil,
                  startNow: Bool = true) -> UUID {
        var item = DownloadItem(url: url, fileName: title, destinationDir: folder)
        item.media = MediaRequest(choice: choice, title: title)
        item.headers = headers?.isEmpty == false ? headers : nil
        item.category = choice.isAudio ? .music : .video
        items.insert(item, at: 0)
        if startNow { manualStart.insert(item.id) }
        scheduleSave(immediate: true)
        pump()
        return item.id
    }

    /// Puts items back in the queue; they start when a slot is free.
    func resume(_ ids: Set<UUID>) {
        enqueue(ids, manual: true)
        pump()
    }

    /// Starts items immediately, ignoring the concurrency limit and schedule.
    func startNow(_ ids: Set<UUID>) {
        enqueue(ids, manual: true)
        for id in ids where item(id)?.status == .queued { start(id) }
    }

    /// Adds items to the scheduler's queue without starting them now.
    func addToScheduledQueue(_ ids: Set<UUID>) {
        enqueue(ids, manual: false)
        for id in ids { manualStart.remove(id) }
        pump()
    }

    func pause(_ ids: Set<UUID>) {
        for id in ids {
            guard let item = item(id) else { continue }
            manualStart.remove(id)
            if item.status.isActive {
                Task { await engine.pause(id) }
            } else if item.status == .queued {
                setStatus(id, .paused)
            }
        }
        scheduleSave(immediate: true)
    }

    func pauseAll() { pause(Set(items.filter { $0.status.isActive || $0.status == .queued }.map(\.id))) }
    func resumeAll() { resume(Set(items.filter { $0.status == .paused || $0.status == .failed }.map(\.id))) }

    func cancel(_ ids: Set<UUID>) {
        for id in ids {
            guard let item = item(id), item.status != .completed else { continue }
            manualStart.remove(id)
            Task {
                await engine.cancel(id)
                await MainActor.run {
                    guard var current = self.item(id) else { return }
                    current.status = .cancelled
                    current.segments = []
                    current.speed = 0
                    self.replace(current)
                    self.scheduleSave(immediate: true)
                    self.pump()
                }
            }
        }
    }

    /// Restarts a failed/cancelled download, keeping progress where possible.
    func retry(_ ids: Set<UUID>) { resume(ids) }

    /// Replaces the URL of a download (e.g. an expired link) and resumes; progress is kept if the file is identical.
    func updateURL(_ id: UUID, to urlString: String) {
        guard var item = item(id), let url = URL(string: urlString), !item.status.isActive else { return }
        item.url = url
        item.finalURL = nil
        replace(item)
        resume([id])
    }

    func remove(_ ids: Set<UUID>, deleteFiles: Bool) {
        for id in ids {
            manualStart.remove(id)
            let saved = item(id)?.savedPath
            Task {
                await engine.cancel(id)
                if deleteFiles, let saved { try? FileManager.default.trashItem(at: saved, resultingItemURL: nil) }
            }
        }
        items.removeAll { ids.contains($0.id) }
        scheduleSave(immediate: true)
        pump()
    }

    func reveal(_ id: UUID) {
        guard let item = item(id) else { return }
        if let path = item.savedPath, FileManager.default.fileExists(atPath: path.path) {
            NSWorkspace.shared.activateFileViewerSelecting([path])
        } else {
            let root = Self.currentConfig().downloadsRoot
            let folder = item.destinationDir ?? root.appendingPathComponent(item.category.rawValue)
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: folder.path) ? folder : root)
        }
    }

    func open(_ id: UUID) {
        guard let path = item(id)?.savedPath else { return }
        NSWorkspace.shared.open(path)
    }

    // MARK: - Queue

    private func enqueue(_ ids: Set<UUID>, manual: Bool) {
        for id in ids {
            guard var item = item(id), item.status.canResume else { continue }
            if item.status == .cancelled { item.segments = [] }
            item.status = .queued
            item.errorMessage = nil
            replace(item)
            if manual { manualStart.insert(id) }
        }
        scheduleSave(immediate: true)
    }

    /// Starts queued downloads while there are free slots.
    private func pump() {
        guard !suspended else { return }
        let scheduled = defaults.bool(forKey: SettingsKey.scheduleEnabled)
        let max = Swift.max(1, defaults.integer(forKey: SettingsKey.maxConcurrent))
        let ids = QueueManager.idsToStart(items, maxConcurrent: max) { [manualStart, scheduledRunActive] item in
            !scheduled || scheduledRunActive || manualStart.contains(item.id)
        }
        for id in ids { start(id) }
        checkScheduledRunDone()
    }

    private func start(_ id: UUID) {
        guard var item = item(id) else { return }
        manualStart.remove(id)
        item.status = .probing
        item.errorMessage = nil
        replace(item)
        let snapshot = item
        Task {
            await engine.start(snapshot) { [weak self] update in
                Task { @MainActor in self?.apply(update) }
            }
        }
    }

    // MARK: - Scheduler

    private func checkSchedule() {
        let now = Date()
        defer { lastScheduleCheck = now }
        guard defaults.bool(forKey: SettingsKey.scheduleEnabled) else { return }
        let schedule = DailySchedule(
            startMinute: defaults.integer(forKey: SettingsKey.scheduleStart),
            stopMinute: defaults.bool(forKey: SettingsKey.scheduleStopEnabled) ? defaults.integer(forKey: SettingsKey.scheduleStop) : nil)
        if schedule.stopCrossed(from: lastScheduleCheck, to: now) {
            scheduledRunActive = false
            // Stop everything and keep it queued for the next window.
            for item in activeItems { pauseToQueue(item.id) }
        } else if schedule.startCrossed(from: lastScheduleCheck, to: now) {
            scheduledRunActive = queuedCount > 0
            pump()
        }
    }

    private func checkScheduledRunDone() {
        guard scheduledRunActive, activeItems.isEmpty, queuedCount == 0 else { return }
        scheduledRunActive = false
        if defaults.bool(forKey: SettingsKey.sleepWhenDone) {
            notify("Scheduled downloads finished", "Putting the Mac to sleep.")
            saveNow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Power.sleepNow() }
        }
    }

    /// Pauses a running download and puts it back in the queue.
    private func pauseToQueue(_ id: UUID) {
        Task {
            await engine.pause(id)
            await MainActor.run { self.setStatus(id, .queued) }
        }
    }

    // MARK: - Sleep, wake, network

    private func handleSleep() {
        suspended = true
        let ids = activeItems.map(\.id)
        for id in ids {
            manualStart.insert(id) // resume on wake regardless of schedule
            pauseToQueue(id)
        }
    }

    private func handleWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                self?.suspended = false
                self?.requeueNetworkFailures()
            }
        }
    }

    /// Re-queues downloads that failed because the network dropped.
    private func requeueNetworkFailures() {
        let ids = items.filter { $0.status == .failed && $0.interruptedByNetwork == true }.map(\.id)
        if !ids.isEmpty { enqueue(Set(ids), manual: true) }
        pump()
    }

    // MARK: - Clipboard

    private func handleCopiedLink(_ text: String) {
        guard QueueManager.isLikelyDownload(text), pendingClipboardURL == nil,
              !items.contains(where: { $0.url.absoluteString == text }) else { return }
        pendingClipboardURL = text
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - State

    private func apply(_ update: DownloadItem) {
        guard let index = items.firstIndex(where: { $0.id == update.id }) else { return }
        let old = items[index]
        // Ignore late progress from a download the user has since cancelled.
        if old.status == .cancelled && update.status != .completed { return }
        // pauseToQueue already moved it back to the queue; don't let the final "paused" update undo that.
        if old.status == .queued && update.status == .paused { return }
        items[index] = update
        updateProgressWindowTitle(update)
        let statusChanged = old.status != update.status
        scheduleSave(immediate: statusChanged)
        guard statusChanged, !update.status.isActive else { return }
        switch update.status {
        case .completed:
            notify("Download complete", update.displayName)
            runCompletionActions(update)
        case .failed where update.interruptedByNetwork != true:
            notify("Download failed", "\(update.displayName): \(update.errorMessage ?? "")")
        default: break
        }
        pump()
    }

    private func updateProgressWindowTitle(_ item: DownloadItem) {
        let key = "progress-\(item.id.uuidString)"
        guard windows.isOpen(key) else { return }
        let pct = item.progress.map { "\(Int($0 * 100))% " } ?? ""
        windows.setTitle(key, item.status == .completed ? "Download complete" : pct + item.displayName)
    }

    private func notify(_ title: String, _ body: String) {
        guard defaults.bool(forKey: SettingsKey.notifications) else { return }
        notifier.post(title: title, body: body)
    }

    private func setStatus(_ id: UUID, _ status: DownloadStatus) {
        guard var item = item(id) else { return }
        item.status = status
        item.speed = 0
        replace(item)
        scheduleSave(immediate: true)
    }

    private func replace(_ item: DownloadItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
    }

    private func scheduleSave(immediate: Bool) {
        if immediate {
            saveTask?.cancel()
            saveTask = nil
            saveNow()
            return
        }
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveTask = nil
            self?.saveNow()
        }
    }

    func saveNow() {
        guard !DemoData.isEnabled else { return }
        do { try store.save(items) } catch { NSLog("MacIDM: failed to save downloads: \(error)") }
    }
}
