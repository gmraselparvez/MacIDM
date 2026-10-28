import Foundation
import Testing
@testable import MacIDMCore

@Suite struct RangeSplittingTests {
    @Test func splitsEvenlyAndContiguously() {
        let size: Int64 = 10_000_003
        let segs = SegmentPlanner.plan(totalSize: size, acceptsRanges: true, requested: 8)
        #expect(segs.count == 8)
        #expect(segs.first?.start == 0)
        #expect(segs.last?.end == size - 1)
        for (a, b) in zip(segs, segs.dropFirst()) { #expect(a.end! + 1 == b.start) }
        #expect(segs.compactMap(\.length).reduce(0, +) == size)
        let lengths = segs.compactMap(\.length)
        #expect(lengths.max()! - lengths.min()! <= 1)
    }

    @Test func clampsSegmentCount() {
        #expect(SegmentPlanner.plan(totalSize: 1 << 40, acceptsRanges: true, requested: 100).count == 32)
        #expect(SegmentPlanner.plan(totalSize: 1 << 40, acceptsRanges: true, requested: 0).count == 1)
        // Small files don't get split into tiny segments.
        #expect(SegmentPlanner.plan(totalSize: 300_000, acceptsRanges: true, requested: 8).count == 1)
    }

    @Test func singleStreamWhenNoRangesOrUnknownSize() {
        let noRanges = SegmentPlanner.plan(totalSize: 5_000_000, acceptsRanges: false, requested: 8)
        #expect(noRanges == [Segment(index: 0, start: 0, end: 4_999_999)])
        let unknown = SegmentPlanner.plan(totalSize: nil, acceptsRanges: true, requested: 8)
        #expect(unknown.count == 1 && unknown[0].end == nil && !unknown[0].isComplete)
    }

    @Test func handlesFilesOver4GB() {
        let size: Int64 = 6 * 1024 * 1024 * 1024 + 7
        let segs = SegmentPlanner.plan(totalSize: size, acceptsRanges: true, requested: 8)
        #expect(segs.last?.end == size - 1)
        #expect(segs.compactMap(\.length).reduce(0, +) == size)
    }

    @Test func dynamicSplitTakesHalfOfLargestRemaining() {
        var segs = [
            Segment(index: 0, start: 0, end: 999_999, downloaded: 1_000_000),
            Segment(index: 1, start: 1_000_000, end: 9_999_999, downloaded: 1_000_000),
        ]
        let newIndex = SegmentPlanner.splitLargest(&segs, minSplitSize: 100_000)
        #expect(newIndex == 2)
        // Segment 1 had 8,000,000 left starting at 2,000,000 → split at 6,000,000.
        #expect(segs[1].end == 5_999_999)
        #expect(segs[2].start == 6_000_000 && segs[2].end == 9_999_999 && segs[2].downloaded == 0)
        #expect(segs[1].remaining! + segs[2].remaining! == 8_000_000)
    }

    @Test func dynamicSplitSkipsSmallRemainders() {
        var segs = [Segment(index: 0, start: 0, end: 999, downloaded: 10)]
        #expect(SegmentPlanner.splitLargest(&segs, minSplitSize: 1_000) == nil)
        #expect(segs.count == 1)
    }
}

@Suite struct ResumeMathTests {
    @Test func rangeHeaderResumesFromCurrentOffset() {
        let seg = Segment(index: 3, start: 1_000, end: 1_999, downloaded: 250)
        #expect(seg.current == 1_250)
        #expect(seg.remaining == 750)
        #expect(seg.rangeHeader == "bytes=1250-1999")
        #expect(Segment(index: 0, start: 0, end: nil).rangeHeader == "bytes=0-")
    }

    @Test func reconcileTrustsTheSmallerOfRecordAndDisk() {
        var seg = Segment(index: 0, start: 0, end: 999, downloaded: 600)
        #expect(seg.reconcile(partFileLength: 400) == 400)   // crashed before write
        #expect(seg.downloaded == 400)
        var seg2 = Segment(index: 0, start: 0, end: 999, downloaded: 300)
        #expect(seg2.reconcile(partFileLength: 900) == 300)  // file longer than record → truncate
        var seg3 = Segment(index: 0, start: 0, end: 99, downloaded: 500)
        #expect(seg3.reconcile(partFileLength: 500) == 100)  // never past segment length
        #expect(seg3.isComplete)
    }

    @Test func contentRangeTotal() {
        #expect(ProbeService.totalFromContentRange("bytes 0-0/12345") == 12345)
        #expect(ProbeService.totalFromContentRange("bytes 0-0/7000000000") == 7_000_000_000)
        #expect(ProbeService.totalFromContentRange("bytes 0-0/*") == nil)
    }

    @Test func persistedItemsComeBackPaused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DownloadStore(fileURL: dir.appendingPathComponent("d.json"))
        var item = DownloadItem(url: URL(string: "https://example.com/a.zip")!, fileName: "a.zip")
        item.status = .downloading
        item.totalSize = 5_000_000_000
        item.segments = [Segment(index: 0, start: 0, end: 4_999_999_999, downloaded: 4_500_000_000)]
        item.speed = 123
        try store.save([item])
        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].status == .paused)
        #expect(loaded[0].segments == item.segments)
        #expect(loaded[0].speed == 0)
        try? FileManager.default.removeItem(at: dir)
    }
}

@Suite struct FilenameParsingTests {
    let url = URL(string: "https://example.com/files/report%20final.pdf?x=1")!

    @Test func prefersRFC5987FilenameStar() {
        let cd = #"attachment; filename="fallback.txt"; filename*=UTF-8''na%C3%AFve%20file.txt"#
        #expect(FileNaming.fileName(contentDisposition: cd, url: url) == "naïve file.txt")
    }

    @Test func quotedAndBareFilenames() {
        #expect(FileNaming.parseContentDisposition(#"attachment; filename="my \"cool\" file.zip""#) == #"my "cool" file.zip"#)
        #expect(FileNaming.parseContentDisposition("attachment; filename=data.csv; size=10") == "data.csv")
        #expect(FileNaming.parseContentDisposition("inline") == nil)
    }

    @Test func fallsBackToURLPathThenTimestamp() {
        #expect(FileNaming.fileName(contentDisposition: nil, url: url) == "report final.pdf")
        let bare = URL(string: "https://example.com/")!
        let fixed = Date(timeIntervalSince1970: 0)
        let name = FileNaming.fileName(contentDisposition: nil, url: bare, now: fixed)
        #expect(name.hasPrefix("download-19") || name.hasPrefix("download-1970"))
        #expect(FileNaming.fileName(contentDisposition: nil, url: URL(string: "https://e.com/get")!, mimeType: "application/zip") == "get.zip")
    }

    @Test func sanitizesPathTraversal() {
        #expect(FileNaming.fileName(contentDisposition: #"attachment; filename="../../etc/passwd""#, url: url) == "passwd")
        #expect(FileNaming.sanitize(".hidden") == "hidden")
        #expect(FileNaming.sanitize("a:b") == "a-b")
    }

    @Test func avoidsOverwriting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileNaming.uniqueURL(for: "a.zip", in: dir).lastPathComponent == "a.zip")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.zip").path, contents: Data())
        #expect(FileNaming.uniqueURL(for: "a.zip", in: dir).lastPathComponent == "a (1).zip")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a (1).zip").path, contents: Data())
        #expect(FileNaming.uniqueURL(for: "a.zip", in: dir).lastPathComponent == "a (2).zip")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("README").path, contents: Data())
        #expect(FileNaming.uniqueURL(for: "README", in: dir).lastPathComponent == "README (1)")
    }

    @Test func categorizesByExtension() {
        #expect(Category.from(fileName: "movie.MKV") == .video)
        #expect(Category.from(fileName: "song.flac") == .music)
        #expect(Category.from(fileName: "x.tar.gz") == .archives)
        #expect(Category.from(fileName: "Installer.dmg") == .programs)
        #expect(Category.from(fileName: "paper.pdf") == .documents)
        #expect(Category.from(fileName: "noext") == .other)
    }
}

@Suite struct MergingTests {
    @Test func mergesPartsInOrderAndVerifiesSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let chunks = ["hello ", "parallel ", "world"].map { Data($0.utf8) }
        let parts = chunks.enumerated().map { i, d -> URL in
            let u = dir.appendingPathComponent("part\(i)")
            try! d.write(to: u)
            return u
        }
        let out = dir.appendingPathComponent("out.txt")
        try FileMerger.merge(parts: parts, into: out, expectedSize: 20)
        #expect(try String(contentsOf: out, encoding: .utf8) == "hello parallel world")
    }

    @Test func rejectsWrongSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try Data("abc".utf8).write(to: a)
        try Data("def".utf8).write(to: b)
        #expect(throws: DownloadError.sizeMismatch(expected: 10, actual: 6)) {
            try FileMerger.merge(parts: [a, b], into: dir.appendingPathComponent("o"), expectedSize: 10)
        }
    }

    @Test func validateDetectsGapsAndAcceptsSplitSegments() throws {
        // Out of order by index (as after dynamic splits) but contiguous by start.
        let ok = [
            Segment(index: 0, start: 0, end: 99, downloaded: 100),
            Segment(index: 1, start: 200, end: 299, downloaded: 100),
            Segment(index: 2, start: 100, end: 199, downloaded: 100),
        ]
        try FileMerger.validate(ok, expectedSize: 300)
        let gap = [Segment(index: 0, start: 0, end: 99, downloaded: 50), Segment(index: 1, start: 100, end: 199, downloaded: 100)]
        #expect(throws: DownloadError.incomplete) { try FileMerger.validate(gap, expectedSize: 200) }
    }
}
