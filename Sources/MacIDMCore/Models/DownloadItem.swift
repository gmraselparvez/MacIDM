import Foundation

public enum DownloadStatus: String, Codable, Sendable {
    case queued, probing, downloading, merging, paused, completed, failed, cancelled

    public var isActive: Bool { self == .probing || self == .downloading || self == .merging }
    public var canResume: Bool { self == .paused || self == .failed || self == .queued || self == .cancelled }
}

public struct DownloadItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var finalURL: URL?
    public var fileName: String
    /// Folder chosen by the user; nil means auto-categorize under the downloads root.
    public var destinationDir: URL?
    public var savedPath: URL?
    public var totalSize: Int64?
    public var acceptsRanges: Bool
    public var etag: String?
    public var lastModified: String?
    public var status: DownloadStatus
    public var errorMessage: String?
    public var segments: [Segment]
    public var requestedSegments: Int
    public var category: Category
    public var dateAdded: Date
    public var dateCompleted: Date?
    /// Set when the last failure was a network error, so it can auto-resume when the network returns.
    public var interruptedByNetwork: Bool?
    /// Extra request headers from the browser (Referer, Cookie, User-Agent). Cleared once complete.
    public var headers: [String: String]?
    /// Set for video/audio grabbed through yt-dlp.
    public var media: MediaRequest?

    /// Bytes per second; transient, never persisted.
    public var speed: Double = 0

    enum CodingKeys: String, CodingKey {
        case id, url, finalURL, fileName, destinationDir, savedPath, totalSize, acceptsRanges, etag,
             lastModified, status, errorMessage, segments, requestedSegments, category, dateAdded, dateCompleted, interruptedByNetwork, headers, media
    }

    public init(url: URL, fileName: String = "", destinationDir: URL? = nil, requestedSegments: Int = 8) {
        self.id = UUID()
        self.url = url
        self.fileName = fileName
        self.destinationDir = destinationDir
        self.acceptsRanges = false
        self.status = .queued
        self.segments = []
        self.requestedSegments = requestedSegments
        self.category = Category.from(fileName: fileName.isEmpty ? url.lastPathComponent : fileName)
        self.dateAdded = Date()
    }

    public var downloadedBytes: Int64 { SegmentPlanner.downloadedBytes(segments) }

    public var progress: Double? {
        if status == .completed { return 1 }
        guard let total = totalSize, total > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(total))
    }

    public var eta: TimeInterval? {
        guard status == .downloading, speed > 0, let total = totalSize else { return nil }
        return Double(max(0, total - downloadedBytes)) / speed
    }

    public var displayName: String { fileName.isEmpty ? url.absoluteString : fileName }
}
