import Foundation

public enum SegmentPlanner {
    public static let maxSegments = 32
    /// Don't create segments smaller than this on the initial split.
    public static let minSegmentSize: Int64 = 256 * 1024

    /// Splits a file into contiguous, non-overlapping segments covering `0..<totalSize`.
    public static func plan(totalSize: Int64?, acceptsRanges: Bool, requested: Int) -> [Segment] {
        guard let size = totalSize, size > 0, acceptsRanges else {
            return [Segment(index: 0, start: 0, end: totalSize.map { $0 - 1 })]
        }
        var count = Int64(min(max(requested, 1), maxSegments))
        count = min(count, max(1, size / minSegmentSize))
        let base = size / count
        let extra = size % count
        var segments: [Segment] = []
        var start: Int64 = 0
        for i in 0..<count {
            let length = base + (i < extra ? 1 : 0)
            segments.append(Segment(index: Int(i), start: start, end: start + length - 1))
            start += length
        }
        return segments
    }

    /// Dynamic segmentation: halves the incomplete segment with the most bytes left and
    /// appends the second half as a new segment. Returns the new segment's index, or nil
    /// if nothing is big enough to be worth another connection.
    @discardableResult
    public static func splitLargest(_ segments: inout [Segment], minSplitSize: Int64) -> Int? {
        let candidate = segments
            .filter { !$0.isComplete && $0.remaining != nil }
            .max { ($0.remaining ?? 0) < ($1.remaining ?? 0) }
        guard let seg = candidate, let remaining = seg.remaining, let end = seg.end,
              remaining >= minSplitSize * 2 else { return nil }
        let mid = seg.current + (remaining - remaining / 2)
        let newIndex = segments.count
        segments[seg.index].end = mid - 1
        segments.append(Segment(index: newIndex, start: mid, end: end))
        return newIndex
    }

    public static func downloadedBytes(_ segments: [Segment]) -> Int64 {
        segments.reduce(0) { $0 + $1.downloaded }
    }
}
