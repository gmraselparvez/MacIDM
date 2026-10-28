import Foundation

/// Owns all running downloads. UI-independent; reports state through the `onUpdate` callback.
public actor DownloadEngine {
    public private(set) var config: EngineConfig
    private let session: URLSession
    private var running: [UUID: Task<DownloadItem, Never>] = [:]
    private let limiter = SpeedLimiter()
    /// One limiter per download, so its cap can change while it runs.
    private var itemLimiters: [UUID: SpeedLimiter] = [:]

    public init(config: EngineConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.httpMaximumConnectionsPerHost = SegmentPlanner.maxSegments
            cfg.timeoutIntervalForRequest = 30
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.urlCache = nil
            self.session = URLSession(configuration: cfg)
        }
    }

    public func update(config: EngineConfig) { self.config = config }

    /// Global bandwidth cap across all downloads; 0 turns it off.
    public func setSpeedLimit(bytesPerSecond: Int64) async {
        await limiter.setLimit(bytesPerSecond)
    }

    /// Caps one download; nil or 0 removes the cap. Takes effect immediately if it's running.
    public func setSpeedLimit(_ id: UUID, bytesPerSecond: Int64?) async {
        await itemLimiter(id).setLimit(bytesPerSecond ?? 0)
    }

    private func itemLimiter(_ id: UUID) -> SpeedLimiter {
        if let l = itemLimiters[id] { return l }
        let l = SpeedLimiter()
        itemLimiters[id] = l
        return l
    }

    public func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    public func start(_ item: DownloadItem, onUpdate: @escaping @Sendable (DownloadItem) -> Void) {
        guard running[item.id] == nil else { return }
        let id = item.id
        if item.media != nil {
            let perItem = itemLimiter(id)
            if let cap = item.speedLimit, cap > 0 { Task { await perItem.setLimit(cap) } }
            let downloader = MediaDownloader(item: item, config: config, session: session, limiter: limiter,
                                             itemLimiter: perItem, onUpdate: onUpdate)
            running[id] = Task {
                let result = await downloader.run()
                self.finished(id)
                return result
            }
            return
        }
        let perItem = itemLimiter(id)
        if let cap = item.speedLimit, cap > 0 { Task { await perItem.setLimit(cap) } }
        let downloader = SegmentedDownloader(item: item, config: config, session: session, limiter: limiter,
                                             itemLimiter: perItem, onUpdate: onUpdate)
        running[id] = Task {
            let result = await downloader.run()
            self.finished(id)
            return result
        }
    }

    /// Stops the download, keeping part files so it can resume. Waits until it has stopped.
    public func pause(_ id: UUID) async {
        guard let task = running[id] else { return }
        task.cancel()
        _ = await task.value
    }

    /// Stops the download and deletes its partial data.
    public func cancel(_ id: UUID) async {
        await pause(id)
        try? FileManager.default.removeItem(at: SegmentedDownloader.partsDir(for: id, root: config.partsRoot))
    }

    /// Waits for a running download to end (used by tests).
    public func wait(_ id: UUID) async -> DownloadItem? {
        await running[id]?.value
    }

    private func finished(_ id: UUID) { running[id] = nil }
}
