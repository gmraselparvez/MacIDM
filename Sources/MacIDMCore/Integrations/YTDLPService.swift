import Foundation

/// What the user picked in the video grabber.
public enum MediaChoice: Codable, Hashable, Sendable {
    case best
    case video(maxHeight: Int)
    case audio(format: AudioFormat)

    public enum AudioFormat: String, Codable, CaseIterable, Sendable {
        case mp3, m4a
    }

    public var isAudio: Bool { if case .audio = self { return true } else { return false } }

    /// yt-dlp `-f` selector. Video picks the best stream up to the height plus the best audio.
    public var formatSelector: String {
        switch self {
        case .best: return "bv*+ba/b"
        case .video(let h): return "bv*[height<=\(h)]+ba/b[height<=\(h)]"
        case .audio: return "ba/b"
        }
    }

    public var label: String {
        switch self {
        case .best: return "Best quality"
        case .video(let h): return "\(h)p"
        case .audio(let f): return "Audio only (\(f.rawValue.uppercased()))"
        }
    }
}

/// Stored on a DownloadItem that yt-dlp handles instead of the segmented engine.
public struct MediaRequest: Codable, Hashable, Sendable {
    public var choice: MediaChoice
    public var title: String?

    public init(choice: MediaChoice, title: String? = nil) {
        self.choice = choice
        self.title = title
    }
}

public struct MediaFormat: Codable, Hashable, Sendable {
    public var id: String
    public var ext: String?
    public var height: Int?
    public var vcodec: String?
    public var acodec: String?
    public var filesize: Int64?
    public var tbr: Double?
    public var note: String?

    public var hasVideo: Bool { (vcodec ?? "none") != "none" }
    public var hasAudio: Bool { (acodec ?? "none") != "none" }
}

public struct MediaInfo: Sendable, Equatable {
    public var id: String
    public var title: String
    public var extractor: String
    public var duration: Double?
    public var thumbnail: URL?
    public var formats: [MediaFormat]

    /// Distinct video heights, highest first.
    public var videoHeights: [Int] {
        Array(Set(formats.filter(\.hasVideo).compactMap(\.height))).sorted(by: >)
    }

    /// Choices to offer: best, each available height, and audio-only.
    public var choices: [MediaChoice] {
        var list: [MediaChoice] = [.best]
        if videoHeights.count > 1 { list += videoHeights.map { .video(maxHeight: $0) } }
        list += MediaChoice.AudioFormat.allCases.map { .audio(format: $0) }
        return list
    }

    /// Rough download size for a choice, when the site reports sizes.
    public func estimatedSize(for choice: MediaChoice) -> Int64? {
        let bestAudio = formats.filter { $0.hasAudio && !$0.hasVideo && $0.filesize != nil }.max { ($0.tbr ?? 0) < ($1.tbr ?? 0) }
        func video(maxHeight: Int?) -> MediaFormat? {
            // Only formats that report a size can give an estimate.
            formats.filter { $0.hasVideo && $0.filesize != nil && (maxHeight == nil || ($0.height ?? 0) <= maxHeight!) }
                .max { (($0.height ?? 0), ($0.tbr ?? 0)) < (($1.height ?? 0), ($1.tbr ?? 0)) }
        }
        switch choice {
        case .best, .video:
            let h: Int? = { if case .video(let h) = choice { return h } else { return nil } }()
            guard let v = video(maxHeight: h), let vs = v.filesize else { return nil }
            return v.hasAudio ? vs : vs + (bestAudio?.filesize ?? 0)
        case .audio:
            return bestAudio?.filesize
        }
    }
}

public enum MediaError: Error, LocalizedError, Equatable, Sendable {
    case toolMissing
    case unsupported
    case drmProtected
    case loginRequired
    case unavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing: return "yt-dlp isn't installed. Open Settings › Media to set it up."
        case .unsupported: return "This site isn't supported by the video grabber. Try pasting a direct file link instead."
        case .drmProtected: return "This video is DRM-protected. MacIDM doesn't download DRM-protected media."
        case .loginRequired: return "This video needs you to be signed in, or it's private."
        case .unavailable: return "This video isn't available (removed, private, or blocked in your region)."
        case .failed(let message): return message
        }
    }

    /// Streaming services that use DRM. yt-dlp can't download their content, and its generic
    /// fallback would grab unrelated page media (trailers), so we refuse up front.
    public static let drmHosts = [
        "netflix.com", "disneyplus.com", "hulu.com", "primevideo.com", "max.com", "hbomax.com",
        "peacocktv.com", "paramountplus.com", "tv.apple.com", "music.apple.com", "spotify.com",
        "tidal.com", "deezer.com", "crunchyroll.com", "hotstar.com", "zee5.com", "sonyliv.com",
    ]

    public static func isKnownDRMService(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host.hasSuffix("amazon.com") || host.contains(".amazon."), url.path.contains("/video") || url.path.contains("/gp/video") {
            return true
        }
        return drmHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Maps yt-dlp's stderr to a clear message.
    public static func classify(stderr: String) -> MediaError {
        let text = stderr.lowercased()
        if text.contains("drm") { return .drmProtected }
        if text.contains("requested format is not available") {
            return .failed("That quality isn't available for this video. Pick another one.")
        }
        if text.contains("unsupported url") { return .unsupported }
        if text.contains("sign in") || text.contains("login required") || text.contains("log in")
            || text.contains("private video") || text.contains("members-only") || text.contains("cookies") {
            return .loginRequired
        }
        if text.contains("video unavailable") || text.contains("not available") || text.contains("has been removed") {
            return .unavailable
        }
        let lastError = stderr.split(separator: "\n").last { $0.contains("ERROR:") }
            .map { $0.replacingOccurrences(of: "ERROR: ", with: "").trimmingCharacters(in: .whitespaces) }
        return .failed(lastError ?? (stderr.split(separator: "\n").last.map(String.init) ?? "yt-dlp failed."))
    }
}

/// One line of the `--progress-template` output.
public struct MediaProgress: Equatable, Sendable {
    public var downloaded: Int64
    public var total: Int64?
    public var speed: Double?
    public var eta: Double?

    public static let prefix = "MACIDM|"
    public static let template = "download:MACIDM|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s"

    public static func parse(_ line: String) -> MediaProgress? {
        guard line.hasPrefix(prefix) else { return nil }
        let parts = line.dropFirst(prefix.count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5 else { return nil }
        func num(_ s: String) -> Double? { Double(s) }
        guard let downloaded = num(parts[0]) else { return nil }
        let total = num(parts[1]) ?? num(parts[2])
        return MediaProgress(downloaded: Int64(downloaded), total: total.map { Int64($0) },
                             speed: num(parts[3]), eta: num(parts[4]))
    }
}

/// Finds yt-dlp and ffmpeg: user-updatable copy first, then the app bundle, then Homebrew/PATH.
public struct MediaTools: Sendable {
    public var ytdlp: URL?
    public var ffmpeg: URL?

    public static var managedBinDir: URL {
        DownloadStore.appSupportDir.appendingPathComponent("bin", isDirectory: true)
    }

    public static func locate(bundledDir: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin"),
                              extraDirs: [URL] = []) -> MediaTools {
        var dirs = [managedBinDir]
        if let bundledDir { dirs.append(bundledDir) }
        dirs += extraDirs
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        func find(_ name: String) -> URL? {
            dirs.map { $0.appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        return MediaTools(ytdlp: find("yt-dlp"), ffmpeg: find("ffmpeg"))
    }
}

public enum YTDLPService {
    /// Arguments for a download. `outputDir` gets `Title [id].ext`.
    public static func downloadArguments(url: URL, choice: MediaChoice, outputDir: URL,
                                         ffmpeg: URL?, headers: [String: String] = [:]) -> [String] {
        var args = [
            "--newline", "--quiet", "--progress", "--no-warnings", "--no-playlist", "--no-mtime",
            "--concurrent-fragments", "4",
            "--progress-template", MediaProgress.template,
            "--print", "after_move:filepath",
            "-o", outputDir.appendingPathComponent("%(title).150B [%(id)s].%(ext)s").path,
            "-f", choice.formatSelector,
        ]
        if let ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }
        switch choice {
        case .audio(let format):
            args += ["-x", "--audio-format", format.rawValue]
        case .best, .video:
            // Prefer H.264/AAC so the result plays in QuickTime, at the highest resolution available.
            args += ["-S", "res,vcodec:h264,acodec:m4a", "--merge-output-format", "mp4"]
        }
        args += headerArguments(headers)
        args += ["--", url.absoluteString]
        return args
    }

    static func headerArguments(_ headers: [String: String]) -> [String] {
        headers.sorted { $0.key < $1.key }.flatMap { ["--add-header", "\($0.key):\($0.value)"] }
    }

    /// Runs `yt-dlp -J` and returns the formats on offer.
    public static func fetchInfo(url: URL, ytdlp: URL, headers: [String: String] = [:]) async throws -> MediaInfo {
        if MediaError.isKnownDRMService(url) { throw MediaError.drmProtected }
        let args = ["-J", "--no-playlist", "--no-warnings"] + headerArguments(headers) + ["--", url.absoluteString]
        let result = try await ProcessRunner.run(ytdlp, args)
        guard result.status == 0 else { throw MediaError.classify(stderr: result.stderr) }
        return try parseInfo(Data(result.stdout.utf8))
    }

    public static func parseInfo(_ data: Data) throws -> MediaInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaError.failed("yt-dlp returned unreadable data.")
        }
        if json["_type"] as? String == "playlist" {
            throw MediaError.failed("This is a playlist. Paste the link of a single video.")
        }
        func int64(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }
        let formats: [MediaFormat] = (json["formats"] as? [[String: Any]] ?? []).compactMap { f in
            guard let id = f["format_id"] as? String else { return nil }
            return MediaFormat(id: id, ext: f["ext"] as? String, height: (f["height"] as? NSNumber)?.intValue,
                               vcodec: f["vcodec"] as? String, acodec: f["acodec"] as? String,
                               filesize: int64(f["filesize"]) ?? int64(f["filesize_approx"]),
                               tbr: (f["tbr"] as? NSNumber)?.doubleValue, note: f["format_note"] as? String)
        }
        return MediaInfo(id: json["id"] as? String ?? "",
                         title: json["title"] as? String ?? "Untitled",
                         extractor: json["extractor_key"] as? String ?? json["extractor"] as? String ?? "",
                         duration: (json["duration"] as? NSNumber)?.doubleValue,
                         thumbnail: (json["thumbnail"] as? String).flatMap(URL.init(string:)),
                         formats: formats)
    }

    /// Updates the user-writable copy of yt-dlp (copying the bundled one there first).
    public static func update(tools: MediaTools) async throws -> String {
        let fm = FileManager.default
        let managed = MediaTools.managedBinDir.appendingPathComponent("yt-dlp")
        if !fm.isExecutableFile(atPath: managed.path) {
            guard let source = tools.ytdlp else { throw MediaError.toolMissing }
            try fm.createDirectory(at: MediaTools.managedBinDir, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: managed)
        }
        let result = try await ProcessRunner.run(managed, ["-U"])
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else { throw MediaError.failed(output.isEmpty ? "Update failed." : output) }
        return output
    }

    public static func version(_ ytdlp: URL) async -> String? {
        guard let r = try? await ProcessRunner.run(ytdlp, ["--version"]), r.status == 0 else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs a process to completion and collects its output.
public enum ProcessRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public static func run(_ executable: URL, _ arguments: [String]) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        return await withTaskCancellationHandler {
            async let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
            let (o, e) = await (stdout, stderr)
            process.waitUntilExit()
            return Result(status: process.terminationStatus,
                          stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
        } onCancel: {
            process.interrupt()
        }
    }
}
