import Foundation
import Testing
@testable import MacIDMCore

@Suite struct MediaParsingTests {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/zoo.json")

    @Test func parsesRealYtDlpJSON() throws {
        let info = try YTDLPService.parseInfo(Data(contentsOf: fixture))
        #expect(info.title == "Me at the zoo")
        #expect(info.extractor == "Youtube")
        #expect(info.duration == 19)
        #expect(info.formats.count == 24)
        #expect(info.videoHeights.first == 240)
        #expect(info.choices.first == .best)
        #expect(info.choices.contains(.audio(format: .mp3)))
        #expect(info.estimatedSize(for: .audio(format: .m4a)) != nil)
        #expect(info.estimatedSize(for: .best) != nil)
    }

    @Test func rejectsPlaylists() {
        let data = Data(#"{"_type":"playlist","title":"x","entries":[]}"#.utf8)
        #expect(throws: MediaError.self) { try YTDLPService.parseInfo(data) }
    }

    @Test func parsesProgressLines() {
        #expect(MediaProgress.parse("MACIDM|1048576|4194304|NA|524288.5|6") ==
                MediaProgress(downloaded: 1_048_576, total: 4_194_304, speed: 524_288.5, eta: 6))
        // Falls back to the estimate, tolerates NA.
        #expect(MediaProgress.parse("MACIDM|10|NA|2000.0|NA|NA") == MediaProgress(downloaded: 10, total: 2000, speed: nil, eta: nil))
        #expect(MediaProgress.parse("[download] 10%") == nil)
    }

    @Test func classifiesErrors() {
        #expect(MediaError.classify(stderr: "ERROR: [generic] Unsupported URL: https://example.com") == .unsupported)
        #expect(MediaError.classify(stderr: "ERROR: [Netflix] This video is DRM protected") == .drmProtected)
        #expect(MediaError.classify(stderr: "ERROR: [youtube] abc: Sign in to confirm your age") == .loginRequired)
        #expect(MediaError.classify(stderr: "ERROR: [youtube] abc: Video unavailable") == .unavailable)
        #expect(MediaError.classify(stderr: "ERROR: Requested format is not available")
                == .failed("That quality isn't available for this video. Pick another one."))
        #expect(MediaError.classify(stderr: "WARNING: x\nERROR: something odd") == .failed("something odd"))
    }

    @Test func refusesKnownDRMServices() {
        for s in ["https://www.netflix.com/watch/80100172", "https://www.disneyplus.com/video/x", "https://open.spotify.com/track/1",
                  "https://tv.apple.com/us/show/x", "https://www.amazon.com/gp/video/detail/B0"] {
            #expect(MediaError.isKnownDRMService(URL(string: s)!), "\(s)")
        }
        for s in ["https://www.youtube.com/watch?v=x", "https://vimeo.com/1", "https://www.amazon.com/dp/B0", "https://notnetflix.com/"] {
            #expect(!MediaError.isKnownDRMService(URL(string: s)!), "\(s)")
        }
    }

    @Test func buildsArguments() {
        let args = YTDLPService.downloadArguments(
            url: URL(string: "https://example.com/v")!, choice: .video(maxHeight: 720),
            outputDir: URL(fileURLWithPath: "/tmp/out"), ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            headers: ["Referer": "https://example.com/"])
        #expect(args.suffix(2) == ["--", "https://example.com/v"])
        #expect(args.contains("bv*[height<=720]+ba/b[height<=720]"))
        #expect(args.contains("/tmp/out/%(title).150B [%(id)s].%(ext)s"))
        #expect(args.contains("Referer:https://example.com/"))
        #expect(args.contains("--merge-output-format"))
        let audio = YTDLPService.downloadArguments(url: URL(string: "https://e.com/v")!, choice: .audio(format: .mp3),
                                                   outputDir: URL(fileURLWithPath: "/tmp"), ffmpeg: nil)
        #expect(audio.contains("-x") && audio.contains("mp3") && !audio.contains("--ffmpeg-location"))
    }
}

/// A stand-in for yt-dlp: prints progress for two streams, writes the file, prints its path.
private let fakeYtDlp = #"""
#!/bin/zsh
out=""; url=""
while (( $# )); do
  case "$1" in
    -o) out="$2"; shift ;;
    --) url="$2"; shift ;;
  esac
  shift
done
case "$url" in
  *drm*) echo "ERROR: [Fake] This video is DRM protected" >&2; exit 1 ;;
  *nosite*) echo "ERROR: Unsupported URL: $url" >&2; exit 1 ;;
esac
trap 'exit 130' INT
delay=0; [[ "$url" == *slow* ]] && delay=0.2
for i in 1 2 3 4; do echo "MACIDM|$((i*250))|1000|NA|5000.0|1"; sleep $delay; done
for i in 1 2; do echo "MACIDM|$((i*100))|200|NA|5000.0|1"; sleep $delay; done
dir="${out:h}"
file="$dir/Fake Video [abc].mp4"
mkdir -p "$dir"; head -c 1200 /dev/zero > "$file"
echo "$file"
"""#

@Suite(.serialized) struct MediaDownloaderTests {
    func setup() throws -> (URL, EngineConfig) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tool = root.appendingPathComponent("yt-dlp")
        try fakeYtDlp.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let config = EngineConfig(downloadsRoot: root.appendingPathComponent("Downloads"),
                                  partsRoot: root.appendingPathComponent("parts"),
                                  progressInterval: 0, ytdlpPath: tool)
        return (root, config)
    }

    @Test func downloadsAndReportsProgressAcrossStreams() async throws {
        let (root, config) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        var item = DownloadItem(url: URL(string: "https://video.example/watch")!)
        item.media = MediaRequest(choice: .best, title: "Fake Video")
        let maxDone = ManagedMax()
        let result = await MediaDownloader(item: item, config: config) { maxDone.record($0.downloadedBytes) }.run()
        #expect(result.status == .completed, "\(result.errorMessage ?? "")")
        #expect(result.savedPath?.lastPathComponent == "Fake Video [abc].mp4")
        #expect(result.savedPath?.deletingLastPathComponent().lastPathComponent == "Video")
        #expect(result.totalSize == 1200)
        #expect(maxDone.value == 1200) // 1000 from the video stream + 200 from audio
    }

    @Test func reportsDRMClearly() async throws {
        let (root, config) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        var item = DownloadItem(url: URL(string: "https://drm.example/watch")!)
        item.media = MediaRequest(choice: .audio(format: .mp3))
        let result = await MediaDownloader(item: item, config: config) { _ in }.run()
        #expect(result.status == .failed)
        #expect(result.errorMessage == MediaError.drmProtected.errorDescription)
    }

    @Test func pausesWhenCancelled() async throws {
        let (root, config) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = DownloadEngine(config: config)
        var item = DownloadItem(url: URL(string: "https://slow.example/watch")!)
        item.media = MediaRequest(choice: .best)
        await engine.start(item) { _ in }
        try await Task.sleep(nanoseconds: 300_000_000)
        await engine.pause(item.id)
        // pause() waits for the task, so the final state is already reported; start again to finish.
        await engine.start(item) { _ in }
        let result = try #require(await engine.wait(item.id))
        #expect(result.status == .completed)
    }

    @Test func missingToolIsAClearError() async {
        var item = DownloadItem(url: URL(string: "https://e.com/v")!)
        item.media = MediaRequest(choice: .best)
        let config = EngineConfig(downloadsRoot: FileManager.default.temporaryDirectory, partsRoot: FileManager.default.temporaryDirectory)
        let result = await MediaDownloader(item: item, config: config) { _ in }.run()
        #expect(result.errorMessage == MediaError.toolMissing.errorDescription)
    }
}

private final class ManagedMax: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value: Int64 = 0
    func record(_ v: Int64) { lock.lock(); value = max(value, v); lock.unlock() }
}
