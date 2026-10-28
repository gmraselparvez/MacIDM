import CryptoKit
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

    /// Compact form used by the browser extension: "best", "video:720", "audio:mp3".
    public var code: String {
        switch self {
        case .best: return "best"
        case .video(let h): return "video:\(h)"
        case .audio(let f): return "audio:\(f.rawValue)"
        }
    }

    public init?(code: String) {
        let parts = code.split(separator: ":").map(String.init)
        switch (parts.first, parts.count) {
        case ("best", 1): self = .best
        case ("video", 2): guard let h = Int(parts[1]), h > 0 else { return nil }; self = .video(maxHeight: h)
        case ("audio", 2): guard let f = AudioFormat(rawValue: parts[1]) else { return nil }; self = .audio(format: f)
        default: return nil
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
    case noFormats
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing: return "yt-dlp isn't installed. Open Settings › Media to set it up."
        case .unsupported: return "This site isn't supported by the video grabber. Try pasting a direct file link instead."
        case .drmProtected: return "This video is DRM-protected. MacIDM doesn't download DRM-protected media."
        case .loginRequired: return "This video needs you to be signed in, or it's private."
        case .unavailable: return "This video isn't available (removed, private, or blocked in your region)."
        case .noFormats: return "The site didn't offer any downloadable formats for this video. Try Settings › Video › Check for Updates."
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
    /// Deno or Node.js. YouTube needs a JavaScript runtime for yt-dlp to see all formats.
    public var jsRuntime: URL?

    static func isExecutableFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    public static var managedBinDir: URL {
        DownloadStore.appSupportDir.appendingPathComponent("bin", isDirectory: true)
    }

    public init(ytdlp: URL? = nil, ffmpeg: URL? = nil, jsRuntime: URL? = nil) {
        self.ytdlp = ytdlp
        self.ffmpeg = ffmpeg
        self.jsRuntime = jsRuntime
    }

    public static func locate(bundledDir: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin"),
                              extraDirs: [URL] = []) -> MediaTools {
        var dirs = [managedBinDir]
        if let bundledDir { dirs.append(bundledDir) }
        dirs += extraDirs
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        func find(_ name: String) -> URL? {
            for dir in dirs {
                // yt-dlp's unpacked macOS build lives in a folder: yt-dlp/yt-dlp_macos (+ _internal).
                for candidate in [dir.appendingPathComponent(name), dir.appendingPathComponent("\(name)/\(name)_macos")]
                where isExecutableFile(candidate) {
                    return candidate
                }
            }
            return nil
        }
        return MediaTools(ytdlp: find("yt-dlp"), ffmpeg: find("ffmpeg"), jsRuntime: find("deno") ?? find("node"))
    }
}

public enum YTDLPService {
    /// Arguments for a download. `outputDir` gets `Title [id].ext`.
    public static func downloadArguments(url: URL, choice: MediaChoice, outputDir: URL,
                                         ffmpeg: URL?, headers: [String: String] = [:], jsRuntime: URL? = nil,
                                         limitBytesPerSecond: Int64? = nil) -> [String] {
        var args = [
            "--newline", "--quiet", "--progress", "--no-warnings", "--no-playlist", "--no-mtime",
            "--concurrent-fragments", "4",
            "--progress-template", MediaProgress.template,
            "--print", "after_move:filepath",
            "-o", outputDir.appendingPathComponent("%(title).150B [%(id)s].%(ext)s").path,
            "-f", choice.formatSelector,
        ]
        if let ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }
        args += jsRuntimeArguments(jsRuntime)
        if let limit = limitBytesPerSecond, limit > 0 { args += ["--limit-rate", String(limit)] }
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

    static func jsRuntimeArguments(_ runtime: URL?) -> [String] {
        guard let runtime else { return [] }
        return ["--js-runtimes", "\(runtime.lastPathComponent):\(runtime.path)"]
    }

    /// The browser's cookies make YouTube treat yt-dlp as a signed-in web client, which can hide every
    /// format. So cookies are only sent on a retry, when the site says sign-in is needed.
    public static func withoutCookies(_ headers: [String: String]) -> [String: String] {
        headers.filter { $0.key.caseInsensitiveCompare("Cookie") != .orderedSame && $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame }
    }

    static func headerArguments(_ headers: [String: String]) -> [String] {
        headers.sorted { $0.key < $1.key }.flatMap { ["--add-header", "\($0.key):\($0.value)"] }
    }

    /// Runs `yt-dlp -J` and returns the formats on offer.
    public static func fetchInfo(url: URL, ytdlp: URL, headers: [String: String] = [:], jsRuntime: URL? = nil) async throws -> MediaInfo {
        if MediaError.isKnownDRMService(url) { throw MediaError.drmProtected }
        func attempt(_ headers: [String: String]) async throws -> MediaInfo {
            // --ignore-no-formats-error: report "no formats" ourselves instead of a misleading format error.
            let args = ["-J", "--no-playlist", "--no-warnings", "--ignore-no-formats-error"]
                + jsRuntimeArguments(jsRuntime) + headerArguments(headers) + ["--", url.absoluteString]
            let result = try await ProcessRunner.run(ytdlp, args)
            guard result.status == 0 else { throw MediaError.classify(stderr: result.stderr) }
            let info = try parseInfo(Data(result.stdout.utf8))
            guard info.formats.contains(where: { $0.hasVideo || $0.hasAudio }) else { throw MediaError.noFormats }
            return info
        }
        do {
            return try await attempt(withoutCookies(headers))
        } catch let error as MediaError where (error == .loginRequired || error == .noFormats) && headers["Cookie"] != nil {
            return try await attempt(headers)
        }
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

    static let releaseBase = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/")!

    /// Installs the latest official unpacked macOS build (yt-dlp_macos.zip) into `dir/yt-dlp/`, after
    /// checking it against the release's SHA2-256SUMS. The unpacked build starts in a fraction of a second
    /// and never extracts Python into temporary folders (which macOS can refuse to run).
    /// Returns the installed version, or nil if `currentVersion` is already the latest.
    public static func installLatest(currentVersion: String?, into dir: URL = MediaTools.managedBinDir,
                                     session: URLSession = .shared) async throws -> String? {
        let (sums, _) = try await session.data(from: releaseBase.appendingPathComponent("SHA2-256SUMS"))
        guard let line = String(decoding: sums, as: UTF8.self).split(separator: "\n")
                .first(where: { $0.hasSuffix(" yt-dlp_macos.zip") }),
              let expected = line.split(separator: " ").first.map(String.init) else {
            throw MediaError.failed("Couldn't read the yt-dlp release checksums.")
        }
        let target = dir.appendingPathComponent("yt-dlp", isDirectory: true)
        let latestTag = try? await latestVersion(session: session)
        if let latestTag, latestTag == currentVersion, MediaTools.isExecutableFile(target.appendingPathComponent("yt-dlp_macos")) {
            return nil
        }
        let (zip, _) = try await session.download(from: releaseBase.appendingPathComponent("yt-dlp_macos.zip"))
        defer { try? FileManager.default.removeItem(at: zip) }
        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
        guard digest.map({ String(format: "%02x", $0) }).joined() == expected else {
            throw MediaError.failed("The yt-dlp download didn't match its published checksum, so it wasn't installed.")
        }
        let fm = FileManager.default
        let staging = dir.appendingPathComponent(".yt-dlp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let unzip = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, staging.path])
        guard unzip.status == 0, MediaTools.isExecutableFile(staging.appendingPathComponent("yt-dlp_macos")) else {
            throw MediaError.failed("Couldn't unpack yt-dlp: \(unzip.stderr)")
        }
        try? fm.removeItem(at: target) // also clears an older single-file yt-dlp of the same name
        try fm.moveItem(at: staging, to: target)
        return await version(target.appendingPathComponent("yt-dlp_macos")) ?? latestTag ?? "latest"
    }

    /// The newest release tag, from GitHub's redirect for /releases/latest.
    public static func latestVersion(session: URLSession = .shared) async throws -> String {
        var request = URLRequest(url: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest")!)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        return response.url?.lastPathComponent ?? ""
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

/// Answer for the browser's on-page quality menu. The app builds it (it runs yt-dlp); the helper relays it.
public struct FormatsResponse: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Sendable {
        public var code: String
        public var label: String
        public var size: Int64?

        public init(code: String, label: String, size: Int64?) {
            self.code = code
            self.label = label
            self.size = size
        }
    }

    public var ok: Bool
    public var title: String?
    public var choices: [Choice]?
    public var error: String?

    public init(info: MediaInfo) {
        ok = true
        title = info.title
        choices = info.choices.map { Choice(code: $0.code, label: Self.label($0), size: info.estimatedSize(for: $0)) }
    }

    public init(error: String) {
        ok = false
        self.error = error
    }

    /// IDM-style menu labels: "MP4 · 1080p HD", "MP3 · audio only".
    public static func label(_ choice: MediaChoice) -> String {
        switch choice {
        case .best: return "MP4 · best quality"
        case .video(let h): return "MP4 · \(h)p" + (h >= 2160 ? " 4K" : h >= 720 ? " HD" : "")
        case .audio(let f): return "\(f.rawValue.uppercased()) · audio only"
        }
    }
}
