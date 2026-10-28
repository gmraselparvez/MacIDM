import Foundation

public struct EngineConfig: Sendable {
    public var userAgent: String
    public var retries: Int
    public var downloadsRoot: URL
    public var partsRoot: URL
    /// Dynamic segmentation won't split a segment with less than 2× this left.
    public var minSplitSize: Int64
    public var progressInterval: TimeInterval
    public var bufferSize: Int
    public var ytdlpPath: URL?
    public var ffmpegPath: URL?
    public var jsRuntimePath: URL?
    /// Largest byte range asked for in one request. Some servers (YouTube) slow down long requests,
    /// so each connection then walks its segment in chunks of this size. nil = one request per segment.
    public var maxRequestBytes: Int64?

    public static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    public init(userAgent: String = EngineConfig.safariUserAgent,
                retries: Int = 5,
                downloadsRoot: URL,
                partsRoot: URL,
                minSplitSize: Int64 = 512 * 1024,
                progressInterval: TimeInterval = 0.25,
                bufferSize: Int = 256 * 1024,
                ytdlpPath: URL? = nil,
                ffmpegPath: URL? = nil,
                jsRuntimePath: URL? = nil) {
        self.userAgent = userAgent
        self.retries = retries
        self.downloadsRoot = downloadsRoot
        self.partsRoot = partsRoot
        self.minSplitSize = minSplitSize
        self.progressInterval = progressInterval
        self.bufferSize = bufferSize
        self.ytdlpPath = ytdlpPath
        self.ffmpegPath = ffmpegPath
        self.jsRuntimePath = jsRuntimePath
    }
}

/// Downloads one item: probe → segmented parallel fetch (with dynamic splitting) → merge.
/// Cancelling the task that runs `run()` pauses the download; progress stays on disk.
public actor SegmentedDownloader {
    private var item: DownloadItem
    private let config: EngineConfig
    private let session: URLSession
    private let onUpdate: @Sendable (DownloadItem) -> Void
    private let limiter: SpeedLimiter?
    private let itemLimiter: SpeedLimiter?

    private var lastEmit = Date.distantPast
    private var sampleStart = Date()
    private var bytesSinceSample: Int64 = 0
    private var smoothedSpeed: Double = 0

    public init(item: DownloadItem, config: EngineConfig, session: URLSession, limiter: SpeedLimiter? = nil,
                itemLimiter: SpeedLimiter? = nil, onUpdate: @escaping @Sendable (DownloadItem) -> Void) {
        self.item = item
        self.limiter = limiter
        self.itemLimiter = itemLimiter
        self.config = config
        self.session = session
        self.onUpdate = onUpdate
    }

    private var partsDir: URL { Self.partsDir(for: item.id, root: config.partsRoot) }

    public static func partsDir(for id: UUID, root: URL) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func partURL(_ index: Int) -> URL {
        partsDir.appendingPathComponent("part\(index)")
    }

    public func run() async -> DownloadItem {
        item.errorMessage = nil
        item.interruptedByNetwork = nil
        do {
            try await prepare()
            do {
                try await downloadAll()
            } catch DownloadError.rangeNotSupported {
                // Server ignored Range (200 instead of 206): restart as one stream.
                resetSegments(acceptsRanges: false)
                try await downloadAll()
            }
            try finish()
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                item.status = .paused
            } else {
                let mapped = DownloadError.map(error)
                item.status = (mapped as? DownloadError) == .diskFull ? .paused : .failed
                item.errorMessage = mapped.localizedDescription
                item.interruptedByNetwork = mapped is URLError ? true : nil
            }
        }
        item.speed = 0
        emit(force: true)
        return item
    }

    // MARK: - Phases

    private func prepare() async throws {
        item.status = .probing
        emit(force: true)
        let prober = ProbeService(session: session, userAgent: config.userAgent)
        var attempt = 0
        var probe: ProbeResult
        while true {
            do {
                probe = try await prober.probe(item.url, headers: item.headers ?? [:])
                break
            } catch {
                if Task.isCancelled { throw CancellationError() }
                attempt += 1
                guard DownloadError.isRetryable(error), attempt <= config.retries else { throw error }
                try await Task.sleep(nanoseconds: UInt64(min(30.0, pow(2.0, Double(attempt - 1))) * 1_000_000_000))
            }
        }
        try Task.checkCancellation()

        let hasProgress = item.downloadedBytes > 0
        if item.segments.isEmpty || (hasProgress && remoteFileChanged(probe)) {
            item.totalSize = probe.totalSize
            item.acceptsRanges = probe.acceptsRanges
            item.etag = probe.etag
            item.lastModified = probe.lastModified
            if item.fileName.isEmpty {
                item.fileName = probe.suggestedFileName
                item.category = Category.from(fileName: item.fileName)
            }
            resetSegments(acceptsRanges: probe.acceptsRanges)
        }
        item.finalURL = probe.finalURL

        try FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)
        item.status = .downloading
        emit(force: true)
    }

    /// True when resuming would corrupt the file: ETag/Last-Modified/size changed, or no range support.
    func remoteFileChanged(_ probe: ProbeResult) -> Bool {
        if !item.acceptsRanges || !probe.acceptsRanges { return true }
        if let old = item.etag, let new = probe.etag, old != new { return true }
        if let old = item.lastModified, let new = probe.lastModified, old != new { return true }
        if let old = item.totalSize, let new = probe.totalSize, old != new { return true }
        return false
    }

    private func resetSegments(acceptsRanges: Bool) {
        try? FileManager.default.removeItem(at: partsDir)
        try? FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)
        item.acceptsRanges = acceptsRanges
        item.segments = SegmentPlanner.plan(totalSize: item.totalSize, acceptsRanges: acceptsRanges,
                                            requested: item.requestedSegments)
    }

    private func downloadAll() async throws {
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                await self?.emit()
            }
        }
        defer { ticker.cancel() }

        try await withThrowingTaskGroup(of: Int.self) { group in
            for seg in item.segments where !seg.isComplete {
                let index = seg.index
                group.addTask { try await self.runSegment(index); return index }
            }
            while try await group.next() != nil {
                // A connection freed up: take over half of the biggest remaining segment.
                if item.acceptsRanges, item.totalSize != nil,
                   let newIndex = SegmentPlanner.splitLargest(&item.segments, minSplitSize: config.minSplitSize) {
                    group.addTask { try await self.runSegment(newIndex); return newIndex }
                }
            }
        }
    }

    private func finish() throws {
        try FileMerger.validate(item.segments, expectedSize: item.totalSize)
        item.status = .merging
        emit(force: true)
        let dir = item.destinationDir ?? config.downloadsRoot.appendingPathComponent(item.category.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = FileNaming.uniqueURL(for: item.fileName, in: dir)
        let parts = item.segments.sorted { $0.start < $1.start }
            .filter { $0.downloaded > 0 }
            .map { partURL($0.index) }
        if parts.isEmpty {
            FileManager.default.createFile(atPath: target.path, contents: nil)
        } else {
            try FileMerger.merge(parts: parts, into: target, expectedSize: item.totalSize)
        }
        try? FileManager.default.removeItem(at: partsDir)
        item.savedPath = target
        item.status = .completed
        item.dateCompleted = Date()
        item.headers = nil // don't keep cookies around
    }

    // MARK: - Per-segment work

    private struct Attempt: Sendable {
        let url: URL
        let segment: Segment
        let part: URL
        let useRange: Bool
        let multiSegment: Bool
        let headers: [String: String]
    }

    /// Syncs the segment with its part file and returns what to request, or nil if already done.
    private func beginAttempt(_ index: Int) throws -> Attempt? {
        var seg = item.segments[index]
        let part = partURL(index)
        let fm = FileManager.default
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let onDisk = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if !item.acceptsRanges { seg.downloaded = 0 } // can't resume a plain stream
        let keep = seg.reconcile(partFileLength: onDisk)
        if keep != onDisk {
            let handle = try FileHandle(forWritingTo: part)
            try handle.truncate(atOffset: UInt64(keep))
            try handle.close()
        }
        item.segments[index] = seg
        if seg.isComplete { return nil }
        return Attempt(url: item.finalURL ?? item.url, segment: seg, part: part,
                       useRange: item.acceptsRanges, multiSegment: item.segments.count > 1,
                       headers: item.headers ?? [:])
    }

    /// Records `count` freshly received bytes, clamped to the segment's (possibly shrunk) end.
    /// Returns how many bytes the caller may write, and whether the segment is now complete.
    private func reserve(_ index: Int, count: Int) -> (allowed: Int, complete: Bool) {
        var seg = item.segments[index]
        var allowed = Int64(count)
        if let remaining = seg.remaining { allowed = min(allowed, remaining) }
        seg.downloaded += allowed
        item.segments[index] = seg
        bytesSinceSample += allowed
        emit()
        return (Int(allowed), seg.isComplete)
    }

    private func endAttempt(_ index: Int) throws {
        if item.segments[index].end == nil {
            item.segments[index].finished = true
        } else if !item.segments[index].isComplete {
            throw DownloadError.incomplete
        }
    }

    nonisolated private func runSegment(_ index: Int) async throws {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                if try await downloadOnce(index) {
                    attempt = 0 // finished a chunk; ask for the next one
                    continue
                }
                return
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                let mapped = DownloadError.map(error)
                attempt += 1
                guard DownloadError.isRetryable(mapped), attempt <= config.retries else { throw mapped }
                let delay = min(30.0, pow(2.0, Double(attempt - 1)))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Fetches the rest of the segment, or its next chunk. Returns true when another request is needed.
    nonisolated private func downloadOnce(_ index: Int) async throws -> Bool {
        guard let job = try await beginAttempt(index) else { return false }
        var rangeHeader = job.segment.rangeHeader
        var chunkEnd: Int64?
        if job.useRange, let maxBytes = config.maxRequestBytes, maxBytes > 0, let end = job.segment.end,
           end - job.segment.current + 1 > maxBytes {
            chunkEnd = job.segment.current + maxBytes - 1
            rangeHeader = "bytes=\(job.segment.current)-\(chunkEnd!)"
        }
        var request = URLRequest(url: job.url, timeoutInterval: 30)
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in job.headers { request.setValue(value, forHTTPHeaderField: name) }
        if job.useRange { request.setValue(rangeHeader, forHTTPHeaderField: "Range") }

        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse }
        switch http.statusCode {
        case 206:
            break
        case 200:
            if job.useRange && (job.segment.current > 0 || job.multiSegment) { throw DownloadError.rangeNotSupported }
        case 403, 410:
            throw DownloadError.linkExpired(http.statusCode)
        default:
            throw DownloadError.http(http.statusCode)
        }

        let handle = try FileHandle(forWritingTo: job.part)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let chunk = config.bufferSize
        var buffer = Data()
        buffer.reserveCapacity(chunk)

        func flush() async throws -> Bool {
            if let limiter { await limiter.acquire(buffer.count) }
            if let itemLimiter { await itemLimiter.acquire(buffer.count) }
            let (allowed, complete) = await reserve(index, count: buffer.count)
            if allowed > 0 {
                do { try handle.write(contentsOf: buffer.prefix(allowed)) } catch { throw DownloadError.map(error) }
            }
            buffer.removeAll(keepingCapacity: true)
            return !complete
        }

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunk, try await !flush() { return false }
        }
        if !buffer.isEmpty, try await !flush() { return false }
        if let chunkEnd {
            // The whole chunk arrived: move on to the next one; a short chunk is a real error.
            if await currentOffset(index) > chunkEnd { return true }
            throw DownloadError.incomplete
        }
        try await endAttempt(index)
        return false
    }

    private func currentOffset(_ index: Int) -> Int64 { item.segments[index].current }

    // MARK: - Progress

    private func emit(force: Bool = false) {
        let now = Date()
        let dt = now.timeIntervalSince(sampleStart)
        if dt >= config.progressInterval {
            let instant = Double(bytesSinceSample) / dt
            smoothedSpeed = smoothedSpeed == 0 ? instant : smoothedSpeed * 0.7 + instant * 0.3
            bytesSinceSample = 0
            sampleStart = now
            if item.status == .downloading { item.speed = smoothedSpeed }
        }
        if force || now.timeIntervalSince(lastEmit) >= config.progressInterval {
            lastEmit = now
            onUpdate(item)
        }
    }
}
