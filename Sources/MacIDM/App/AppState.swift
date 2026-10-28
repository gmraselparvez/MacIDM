import AppKit
import Foundation
import MacIDMCore

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
        ])
        engine = DownloadEngine(config: Self.currentConfig())
        items = store.load()

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
        applySettings()
        drainInbox()
        pump()
    }

    /// Picks up downloads sent by the browser extension via the native host.
    func drainInbox() {
        for request in Inbox().drain() {
            guard let (url, headers, fileName) = request.validated() else { continue }
            add(urlString: url.absoluteString, fileName: fileName, headers: headers)
        }
    }

    /// yt-dlp and ffmpeg locations; refreshed after an update.
    @Published private(set) var mediaTools = MediaTools.locate()

    func refreshMediaTools() {
        mediaTools = MediaTools.locate()
        applySettings()
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
            ffmpegPath: tools.ffmpeg)
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
             headers: [String: String]? = nil) -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return false }
        let count = segments ?? defaults.integer(forKey: SettingsKey.segments)
        var item = DownloadItem(url: url, fileName: FileNaming.sanitize(fileName), destinationDir: folder, requestedSegments: count)
        item.headers = headers?.isEmpty == false ? headers : nil
        items.insert(item, at: 0)
        if startNow { manualStart.insert(item.id) }
        scheduleSave(immediate: true)
        pump()
        return true
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
    func addMedia(url: URL, choice: MediaChoice, title: String, folder: URL? = nil) {
        var item = DownloadItem(url: url, fileName: title, destinationDir: folder)
        item.media = MediaRequest(choice: choice, title: title)
        item.category = choice.isAudio ? .music : .video
        items.insert(item, at: 0)
        manualStart.insert(item.id)
        scheduleSave(immediate: true)
        pump()
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
        let statusChanged = old.status != update.status
        scheduleSave(immediate: statusChanged)
        guard statusChanged, !update.status.isActive else { return }
        switch update.status {
        case .completed: notify("Download complete", update.displayName)
        case .failed where update.interruptedByNetwork != true:
            notify("Download failed", "\(update.displayName): \(update.errorMessage ?? "")")
        default: break
        }
        pump()
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
        do { try store.save(items) } catch { NSLog("MacIDM: failed to save downloads: \(error)") }
    }
}
