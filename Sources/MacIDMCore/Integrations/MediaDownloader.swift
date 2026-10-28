import Foundation

/// Downloads a video/audio item. yt-dlp picks the streams; when they're plain HTTP files MacIDM fetches
/// them with its own parallel, chunked engine and joins them with ffmpeg. Otherwise yt-dlp downloads them.
/// Cancelling pauses it; progress is kept for the next run either way.
public actor MediaDownloader {
    private var item: DownloadItem
    private let config: EngineConfig
    private let onUpdate: @Sendable (DownloadItem) -> Void
    private let session: URLSession
    private let limiter: SpeedLimiter?
    private let itemLimiter: SpeedLimiter?
    /// Per-stream progress for the segmented path, shown as one combined bar.
    private var streamItems: [Int: DownloadItem] = [:]
    private var streamSizes: [Int64?] = []
    private var lastStateSave = Date.distantPast

    /// YouTube slows down long requests; yt-dlp uses the same 10 MB chunk size.
    static let chunkBytes: Int64 = 10 * 1024 * 1024
    private var lastEmit = Date.distantPast
    /// Bytes from streams already finished (video, then audio, are separate downloads).
    /// One entry per stream yt-dlp fetches (video, then audio); shown as segments in the details view.
    private var streams: [(total: Int64?, done: Int64)] = []
    private var lastDownloaded: Int64 = 0

    public init(item: DownloadItem, config: EngineConfig, session: URLSession = .shared, limiter: SpeedLimiter? = nil,
                itemLimiter: SpeedLimiter? = nil, onUpdate: @escaping @Sendable (DownloadItem) -> Void) {
        self.item = item
        self.config = config
        self.session = session
        self.limiter = limiter
        self.itemLimiter = itemLimiter
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

        // Fast path: parallel connections. Falls back to yt-dlp for anything it can't handle.
        if let ffmpeg = config.ffmpegPath, let resolved = try? await resolve(ytdlp, media: media) {
            do {
                try await downloadSegmented(resolved, media: media, dir: dir, ffmpeg: ffmpeg)
                return
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                // Keep going with yt-dlp below.
            }
        }

        do {
            try await runYtDlp(ytdlp, media: media, dir: dir, headers: YTDLPService.withoutCookies(item.headers ?? [:]))
        } catch MediaError.loginRequired where item.headers?["Cookie"] != nil {
            try await runYtDlp(ytdlp, media: media, dir: dir, headers: item.headers ?? [:])
        }
    }

    // MARK: - Segmented path

    private func resolve(_ ytdlp: URL, media: MediaRequest) async throws -> ResolvedMedia? {
        let headers = item.headers ?? [:]
        do {
            return try await YTDLPService.resolveStreams(url: item.url, choice: media.choice, ytdlp: ytdlp,
                                                         headers: YTDLPService.withoutCookies(headers),
                                                         jsRuntime: config.jsRuntimePath)
        } catch MediaError.loginRequired where headers["Cookie"] != nil {
            return try await YTDLPService.resolveStreams(url: item.url, choice: media.choice, ytdlp: ytdlp,
                                                         headers: headers, jsRuntime: config.jsRuntimePath)
        }
    }

    /// Working folder for this item's streams; kept between runs so pausing and quitting don't lose progress.
    private var workDir: URL { config.partsRoot.appendingPathComponent("\(item.id.uuidString)-media", isDirectory: true) }

    private func stateURL(_ i: Int) -> URL { workDir.appendingPathComponent("stream\(i).json") }

    private func loadState(_ i: Int) -> DownloadItem? {
        guard let data = try? Data(contentsOf: stateURL(i)) else { return nil }
        return try? JSONDecoder().decode(DownloadItem.self, from: data)
    }

    private func saveState(_ i: Int, _ stream: DownloadItem) {
        try? JSONEncoder().encode(stream).write(to: stateURL(i), options: .atomic)
    }

    private func downloadSegmented(_ resolved: ResolvedMedia, media: MediaRequest, dir: URL, ffmpeg: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        streamSizes = resolved.streams.map(\.size)
        streamItems = [:]
        var streamConfig = config
        streamConfig.maxRequestBytes = Self.chunkBytes
        streamConfig.downloadsRoot = workDir
        streamConfig.partsRoot = workDir.appendingPathComponent("parts", isDirectory: true)

        var files: [URL] = []
        for (i, stream) in resolved.streams.enumerated() {
            let name = "stream\(i).\(stream.ext)"
            let finished = workDir.appendingPathComponent(name)
            if fm.fileExists(atPath: finished.path), let saved = loadState(i), saved.status == .completed {
                streamItems[i] = saved
                files.append(finished)
                continue
            }
            // Resume this stream's progress if we have it; the stream URL is fresh from yt-dlp every run.
            var sub = loadState(i) ?? DownloadItem(url: stream.url, fileName: name, destinationDir: workDir,
                                                   requestedSegments: item.requestedSegments)
            sub.url = stream.url
            sub.finalURL = nil
            sub.fileName = name
            sub.destinationDir = workDir
            sub.headers = stream.headers.merging(["Referer": item.url.absoluteString]) { a, _ in a }
            if sub.status == .completed { sub.status = .paused; sub.segments = [] } // file vanished: start over
            let downloader = SegmentedDownloader(item: sub, config: streamConfig, session: session,
                                                 limiter: limiter, itemLimiter: itemLimiter) { [weak self] update in
                Task { await self?.streamProgress(i, update) }
            }
            let result = await downloader.run()
            streamItems[i] = result
            saveState(i, result)
            if Task.isCancelled { throw CancellationError() }
            guard result.status == .completed, let path = result.savedPath else {
                throw MediaError.failed(result.errorMessage ?? "Downloading the stream failed.")
            }
            if path != finished {
                try? fm.removeItem(at: finished)
                try fm.moveItem(at: path, to: finished)
            }
            files.append(finished)
            publishProgress()
        }

        // Join video + audio, or convert audio, into the final file.
        item.status = .merging
        item.speed = 0
        emit(force: true)
        let base = FileNaming.sanitize(String("\(resolved.title) [\(resolved.id)]".prefix(180)))
        let ext: String
        switch media.choice {
        case .audio(let format): ext = format.rawValue
        case .best, .video: ext = files.count == 1 ? (files[0].pathExtension.isEmpty ? "mp4" : files[0].pathExtension) : "mp4"
        }
        var target = FileNaming.uniqueURL(for: "\(base).\(ext)", in: dir)
        var result = try await ProcessRunner.run(ffmpeg, YTDLPService.ffmpegArguments(inputs: files, choice: media.choice, output: target))
        if result.status != 0, !media.choice.isAudio {
            // Some codec pairs don't fit in MP4; MKV takes anything.
            try? fm.removeItem(at: target)
            target = FileNaming.uniqueURL(for: "\(base).mkv", in: dir)
            result = try await ProcessRunner.run(ffmpeg, YTDLPService.ffmpegArguments(inputs: files, choice: media.choice, output: target))
        }
        guard result.status == 0 else {
            try? fm.removeItem(at: target)
            throw MediaError.failed("Couldn't join the video and audio: \(result.stderr.prefix(200))")
        }
        try? fm.removeItem(at: workDir)

        item.savedPath = target
        item.fileName = target.lastPathComponent
        if let size = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value { item.totalSize = size }
        for i in item.segments.indices { item.segments[i].finished = true }
        item.status = .completed
        item.dateCompleted = Date()
        item.headers = nil
    }

    /// Progress from one stream's downloader, merged into one bar: each stream's connections, side by side.
    private func streamProgress(_ i: Int, _ update: DownloadItem) {
        streamItems[i] = update
        if Date().timeIntervalSince(lastStateSave) > 2 { // survive the app quitting mid-download
            lastStateSave = Date()
            for (k, s) in streamItems { saveState(k, s) }
        }
        publishProgress()
    }

    private func publishProgress() {
        var offset: Int64 = 0
        var segments: [Segment] = []
        var speed: Double = 0
        var known = true
        for i in streamSizes.indices {
            let stream = streamItems[i]
            let size = stream?.totalSize ?? streamSizes[i]
            for seg in (stream?.segments ?? []).sorted(by: { $0.start < $1.start }) {
                segments.append(Segment(index: segments.count, start: offset + seg.start,
                                        end: seg.end.map { offset + $0 }, downloaded: seg.downloaded, finished: seg.finished))
            }
            if stream?.status == .downloading { speed += stream?.speed ?? 0 }
            if let size { offset += size } else { known = false }
        }
        item.segments = segments
        item.totalSize = known ? offset : nil
        item.acceptsRanges = true
        item.speed = speed
        emit()
    }

    // MARK: - yt-dlp path

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
