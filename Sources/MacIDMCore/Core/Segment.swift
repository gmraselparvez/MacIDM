import Foundation

/// A byte range of the remote file downloaded over one connection into its own part file.
/// All offsets are 64-bit so files over 4 GB work.
public struct Segment: Codable, Hashable, Sendable {
    public var index: Int
    public var start: Int64
    /// Inclusive end offset; `nil` when the total size is unknown (single stream).
    public var end: Int64?
    public var downloaded: Int64
    /// Set when an unknown-length stream reaches EOF.
    public var finished: Bool

    public init(index: Int, start: Int64, end: Int64?, downloaded: Int64 = 0, finished: Bool = false) {
        self.index = index
        self.start = start
        self.end = end
        self.downloaded = downloaded
        self.finished = finished
    }

    public var length: Int64? { end.map { $0 - start + 1 } }
    /// Next absolute offset to fetch.
    public var current: Int64 { start + downloaded }
    public var remaining: Int64? { length.map { max(0, $0 - downloaded) } }
    public var isComplete: Bool { finished || remaining == 0 }

    /// HTTP `Range` header value that resumes this segment.
    public var rangeHeader: String {
        "bytes=\(current)-\(end.map(String.init) ?? "")"
    }

    /// Brings recorded progress in line with what is actually on disk.
    /// Returns the length the part file should be truncated to.
    public mutating func reconcile(partFileLength: Int64) -> Int64 {
        var value = min(downloaded, partFileLength)
        if let length { value = min(value, length) }
        downloaded = max(0, value)
        if end != nil { finished = false }
        return downloaded
    }
}
