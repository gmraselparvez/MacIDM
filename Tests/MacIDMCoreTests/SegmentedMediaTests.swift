import Foundation
import Testing
@testable import MacIDMCore

/// Counts requests per host so tests can see how a download was split.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [String] = []
    func add(_ r: String) { lock.lock(); ranges.append(r); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return ranges }
}

@Suite struct ChunkedRequestTests {
    @Test func walksSegmentsInChunksAndStaysCorrect() async throws {
        let payload = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        MockServer.register("chunks.mock", .init(payload: payload))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = EngineConfig(downloadsRoot: root, partsRoot: root.appendingPathComponent("p"),
                                  minSplitSize: 64 * 1024, bufferSize: 16 * 1024)
        config.maxRequestBytes = 100_000
        let engine = DownloadEngine(config: config, session: MockServer.session())
        let item = DownloadItem(url: URL(string: "https://chunks.mock/v.mp4")!, requestedSegments: 4)
        await engine.start(item) { _ in }
        let result = try #require(await engine.wait(item.id))
        #expect(result.status == .completed, "\(result.errorMessage ?? "")")
        #expect(try Data(contentsOf: result.savedPath!) == payload)
        // 2 MB in 100 KB chunks needs at least 20 range requests (plus the probe).
        #expect(MockServer.requestCount("chunks.mock") >= 21)
    }
}

@Suite struct ResolvedMediaTests {
    @Test func parsesMergedHTTPStreams() throws {
        let json = #"""
        {"id":"abc","title":"Clip","requested_formats":[
          {"format_id":"137","protocol":"https","url":"https://r1.googlevideo.com/v","ext":"mp4","filesize":24257051,
           "vcodec":"avc1","acodec":"none","http_headers":{"User-Agent":"UA"}},
          {"format_id":"140","protocol":"https","url":"https://r1.googlevideo.com/a","ext":"m4a","filesize_approx":957523,
           "vcodec":"none","acodec":"mp4a"}]}
        """#
        let r = try #require(ResolvedMedia.parse(Data(json.utf8)))
        #expect(r.id == "abc" && r.title == "Clip" && r.streams.count == 2)
        #expect(r.streams[0].hasVideo && !r.streams[0].hasAudio && r.streams[0].size == 24_257_051)
        #expect(r.streams[0].headers["User-Agent"] == "UA")
        #expect(r.streams[1].ext == "m4a" && r.streams[1].size == 957_523)
    }

    @Test func singleFormatAndRejectsStreamingProtocols() {
        let single = #"{"id":"x","title":"T","protocol":"https","url":"https://e.com/f.mp4","ext":"mp4","vcodec":"avc1","acodec":"mp4a"}"#
        #expect(ResolvedMedia.parse(Data(single.utf8))?.streams.count == 1)
        let hls = #"{"id":"x","title":"T","protocol":"m3u8_native","url":"https://e.com/i.m3u8","ext":"mp4"}"#
        #expect(ResolvedMedia.parse(Data(hls.utf8)) == nil)
    }

    @Test func ffmpegArgumentsPerChoice() {
        let v = URL(fileURLWithPath: "/w/stream0.mp4"), a = URL(fileURLWithPath: "/w/stream1.m4a")
        let merge = YTDLPService.ffmpegArguments(inputs: [v, a], choice: .video(maxHeight: 1080), output: URL(fileURLWithPath: "/o/x.mp4"))
        #expect(merge.contains("0:v:0") && merge.contains("1:a:0") && merge.contains("copy") && merge.contains("+faststart"))
        let mp3 = YTDLPService.ffmpegArguments(inputs: [a], choice: .audio(format: .mp3), output: URL(fileURLWithPath: "/o/x.mp3"))
        #expect(mp3.contains("libmp3lame") && mp3.last == "/o/x.mp3")
        let m4a = YTDLPService.ffmpegArguments(inputs: [a], choice: .audio(format: .m4a), output: URL(fileURLWithPath: "/o/x.m4a"))
        #expect(m4a.contains("copy"))
    }
}
