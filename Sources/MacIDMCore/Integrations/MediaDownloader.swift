import Foundation

/// Runs one yt-dlp download and reports it through the same DownloadItem updates as file downloads.
/// Cancelling pauses it (yt-dlp keeps its .part files and continues on the next run).
public actor MediaDownloader {
    private var item: DownloadItem
    private let config: EngineConfig
    private let onUpdate: @Sendable (DownloadItem) -> Void
    private var lastEmit = Date.distantPast
    /// Bytes from streams already finished (video, then audio, are separate downloads).
    /// One entry per stream yt-dlp fetches (video, then audio); shown as segments in the details view.
    private var streams: [(total: Int64?, done: Int64)] = []
    private var lastDownloaded: Int64 = 0

    public init(item: DownloadItem, config: EngineConfig, onUpdate: @escaping @Sendable (DownloadItem) -> Void) {
        self.item = item
        self.config = config
        self.onUpdate = onUpdate
    }

    public func run() async -> DownloadItem {
        item.errorMessage = nil
        item.interruptedByNetwork = nil
        do {
            try await download()
        } catch {
            if Task.isCancelled || error is CancellationError {
                item.status = .paused
            } else {
                item.status = .failed
                item.errorMessage = error.localizedDescription
            }
        }
        item.speed = 0
        onUpdate(item)
        return item
    }

    private func download() async throws {
        guard let media = item.media else { throw MediaError.failed("Not a media download.") }
        if MediaError.isKnownDRMService(item.url) { throw MediaError.drmProtected }
        guard let ytdlp = config.ytdlpPath else { throw MediaError.toolMissing }
        let dir = item.destinationDir
            ?? config.downloadsRoot.appendingPathComponent((media.choice.isAudio ? Category.music : Category.video).rawValue)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        item.status = .downloading
        item.category = media.choice.isAudio ? .music : .video
        if item.fileName.isEmpty, let title = media.title { item.fileName = title }
        streams = []
        lastDownloaded = 0
        emit(force: true)

        do {
            try await runYtDlp(ytdlp, media: media, dir: dir, headers: YTDLPService.withoutCookies(item.headers ?? [:]))
        } catch MediaError.loginRequired where item.headers?["Cookie"] != nil {
            try await runYtDlp(ytdlp, media: media, dir: dir, headers: item.headers ?? [:])
        }
    }

    private func runYtDlp(_ ytdlp: URL, media: MediaRequest, dir: URL, headers: [String: String]) async throws {
        streams = []
        lastDownloaded = 0
        let process = Process()
        process.executableURL = ytdlp
        process.arguments = YTDLPService.downloadArguments(url: item.url, choice: media.choice, outputDir: dir,
                                                          ffmpeg: config.ffmpegPath, headers: headers,
                                                          jsRuntime: config.jsRuntimePath,
                                                          limitBytesPerSecond: item.speedLimit)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        let stderrTask = Task.detached { String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
        var savedPath: String?
        try await withTaskCancellationHandler {
            for try await line in out.fileHandleForReading.bytes.lines {
                if let progress = MediaProgress.parse(line) {
                    record(progress)
                } else if line.hasPrefix("/") {
                    savedPath = line
                }
            }
        } onCancel: {
            process.interrupt() // SIGINT: yt-dlp stops cleanly and keeps partial data
        }
        process.waitUntilExit()
        let stderr = await stderrTask.value
        if Task.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else { throw MediaError.classify(stderr: stderr) }

        if let savedPath {
            let url = URL(fileURLWithPath: savedPath)
            item.savedPath = url
            item.fileName = url.lastPathComponent
            if let size = (try? FileManager.default.attributesOfItem(atPath: savedPath)[.size] as? NSNumber)?.int64Value {
                item.totalSize = size
                if item.segments.isEmpty {
                    item.segments = [Segment(index: 0, start: 0, end: size - 1, downloaded: size)]
                } else {
                    // Keep one row per stream for the details view, all marked complete.
                    for i in item.segments.indices { item.segments[i].finished = true }
                }
            }
        }
        item.status = .completed
        item.dateCompleted = Date()
        item.headers = nil
    }

    private func record(_ p: MediaProgress) {
        // A drop in downloaded bytes means yt-dlp moved on to the next stream.
        if streams.isEmpty || p.downloaded < lastDownloaded {
            if let last = streams.indices.last { streams[last].done = streams[last].total ?? streams[last].done }
            streams.append((p.total, 0))
        }
        lastDownloaded = p.downloaded
        streams[streams.count - 1] = (p.total, p.downloaded)

        var start: Int64 = 0
        var segments: [Segment] = []
        for (i, s) in streams.enumerated() {
            let length = max(s.total ?? s.done, s.done)
            segments.append(Segment(index: i, start: start, end: s.total == nil ? nil : start + length - 1,
                                    downloaded: s.done, finished: i < streams.count - 1))
            start += length
        }
        item.segments = segments
        item.totalSize = streams.allSatisfy { $0.total != nil } ? start : nil
        item.speed = p.speed ?? 0
        emit()
    }

    private func emit(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) >= config.progressInterval else { return }
        lastEmit = now
        onUpdate(item)
    }
}
