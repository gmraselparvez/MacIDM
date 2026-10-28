import Foundation

/// Pins and boards from Pinterest, read from the same public JSON interface the website uses.
/// yt-dlp only handles video pins; this also gets images at original resolution and whole boards.
public struct PinterestService: Sendable {
    public enum Target: Equatable, Sendable {
        case pin(id: String)
        case board(user: String, slug: String)
        /// pin.it short links redirect to a pin or board.
        case shortLink(URL)
    }

    public struct Pin: Equatable, Sendable {
        public var id: String
        public var title: String
        public var imageURL: URL?
        /// Direct MP4 when Pinterest offers one.
        public var videoURL: URL?
        /// True for video pins that only have a streaming (HLS) version; those go to yt-dlp.
        public var videoNeedsStreaming: Bool
        public var isVideo: Bool { videoURL != nil || videoNeedsStreaming }
        public var pageURL: URL { URL(string: "https://www.pinterest.com/pin/\(id)/")! }
    }

    public struct Collection: Equatable, Sendable {
        public var title: String
        public var pins: [Pin]
        public var isBoard: Bool
        public var images: [Pin] { pins.filter { !$0.isVideo && $0.imageURL != nil } }
        public var videos: [Pin] { pins.filter(\.isVideo) }
    }

    public let session: URLSession
    public let userAgent: String
    /// Your Pinterest cookies from the browser, when the request came from there. Signed out,
    /// Pinterest only shows part of a board; signed in it returns all of it.
    public var cookie: String?
    /// Boards can be huge; stop after this many pins.
    public var maxPins = 2_000

    /// Pinterest answers change all the time, and a cached page (or old cookies) can cut a board short,
    /// so these requests use their own session with no cache and no cookies.
    public static let freshSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    public init(session: URLSession = PinterestService.freshSession, userAgent: String = EngineConfig.safariUserAgent,
                cookie: String? = nil) {
        self.session = session
        self.userAgent = userAgent
        self.cookie = cookie
    }

    // MARK: - Links

    private static let reserved: Set<String> = [
        "pin", "search", "ideas", "today", "settings", "business", "resource", "explore", "videos", "_",
        "login", "signup", "about", "help", "news_hub", "categories", "topics", "shopping", "edit",
    ]

    public static func isPinterest(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "pin.it" || host.contains("pinterest.")
    }

    public static func target(for url: URL) -> Target? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "pin.it" { return .shortLink(url) }
        guard host.contains("pinterest.") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.first == "pin", parts.count >= 2 {
            // /pin/123/ or /pin/some-title--123/
            let raw = parts[1]
            let id = raw.components(separatedBy: "--").last ?? raw
            return id.allSatisfy(\.isNumber) && !id.isEmpty ? .pin(id: id) : nil
        }
        if parts.count >= 2, !reserved.contains(parts[0].lowercased()), !parts[0].hasPrefix("_") {
            return .board(user: parts[0].removingPercentEncoding ?? parts[0], slug: parts[1].removingPercentEncoding ?? parts[1])
        }
        return nil
    }

    // MARK: - Fetching

    public func fetch(_ url: URL) async throws -> Collection {
        guard var target = Self.target(for: url) else {
            throw MediaError.failed("That isn't a Pinterest pin or board link.")
        }
        if case .shortLink(let short) = target {
            guard let resolved = try await resolveRedirect(short), let real = Self.target(for: resolved),
                  real != target else {
                throw MediaError.failed("Couldn't open that pin.it link.")
            }
            target = real
        }
        switch target {
        case .pin(let id):
            let data = try await resource("PinResource", options: ["id": id, "field_set_key": "unauth_react_main_pin"],
                                          handler: "www/pin/[id].js")
            guard let pin = Self.pin(from: data) else { throw MediaError.failed("Pinterest didn't return that pin.") }
            return Collection(title: pin.title.isEmpty ? "Pin \(id)" : pin.title, pins: [pin], isBoard: false)
        case .board(let user, let slug):
            let board = try await resource("BoardResource", options: ["username": user, "slug": slug, "field_set_key": "detailed"],
                                           handler: "www/[username]/[slug].js")
            guard let info = board as? [String: Any], let boardID = info["id"] as? String else {
                throw MediaError.failed("Pinterest didn't return that board. Is it private?")
            }
            let title = info["name"] as? String ?? slug
            let expected = info["pin_count"] as? Int
            var pins: [Pin] = []
            var seen = Set<String>()
            var bookmark: String?
            var retried = false
            while pins.count < maxPins {
                var options: [String: Any] = ["board_id": boardID, "page_size": 50, "field_set_key": "react_grid_pin"]
                if let bookmark { options["bookmarks"] = [bookmark] }
                let (page, next) = try await resourcePage("BoardFeedResource", options: options, handler: "www/[username]/[slug].js")
                for pin in Self.pins(fromFeed: page) where seen.insert(pin.id).inserted { pins.append(pin) }
                if let next { bookmark = next; continue }
                // Pinterest sometimes ends a feed early; if the board says it has more, ask for that page again once.
                if !retried, let expected, pins.count < expected { retried = true; continue }
                break
            }
            return Collection(title: title, pins: Array(pins.prefix(maxPins)), isBoard: true)
        case .shortLink:
            throw MediaError.failed("Couldn't open that pin.it link.")
        }
    }

    private func resolveRedirect(_ url: URL) async throws -> URL? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        return response.url
    }

    private func resource(_ name: String, options: [String: Any], handler: String) async throws -> Any? {
        try await resourcePage(name, options: options, handler: handler).data
    }

    /// One call to Pinterest's resource API, retried a few times (it sometimes stalls).
    private func resourcePage(_ name: String, options: [String: Any], handler: String) async throws -> (data: Any?, bookmark: String?) {
        let payload = try JSONSerialization.data(withJSONObject: ["options": options, "context": [String: Any]()])
        var components = URLComponents(string: "https://www.pinterest.com/resource/\(name)/get/")!
        components.queryItems = [URLQueryItem(name: "source_url", value: "/"),
                                 URLQueryItem(name: "data", value: String(decoding: payload, as: UTF8.self))]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(handler, forHTTPHeaderField: "X-Pinterest-PWS-Handler")
        if let cookie, !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        var lastError: Error = MediaError.failed("Pinterest didn't respond.")
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse }
                if http.statusCode == 404 { throw MediaError.failed("Pinterest says that pin or board doesn't exist (or is private).") }
                guard http.statusCode == 200 else { throw DownloadError.http(http.statusCode) }
                return Self.parsePage(data)
            } catch let error as MediaError {
                throw error
            } catch {
                lastError = error
                if Task.isCancelled { throw CancellationError() }
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 700_000_000)
            }
        }
        throw lastError
    }

    // MARK: - Parsing (static so it's testable)

    static func parsePage(_ data: Data) -> (data: Any?, bookmark: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["resource_response"] as? [String: Any] else { return (nil, nil) }
        let bookmark = response["bookmark"] as? String
        return (response["data"], bookmark == nil || bookmark == "-end-" || bookmark!.isEmpty ? nil : bookmark)
    }

    public static func pin(from data: Any?) -> Pin? {
        guard let p = data as? [String: Any], let id = p["id"] as? String else { return nil }
        let title = [p["title"], p["grid_title"], p["seo_title"], p["description"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let images = p["images"] as? [String: Any]
        let best = (images?["orig"] ?? images?["736x"] ?? images?["474x"]) as? [String: Any]
        let image = (best?["url"] as? String).flatMap(URL.init(string:))
        var video: URL?
        var streaming = false
        if let list = (p["videos"] as? [String: Any])?["video_list"] as? [String: Any], !list.isEmpty {
            // Prefer the largest direct MP4; otherwise it's a streaming-only video.
            let mp4s = list.compactMap { key, value -> (Int, URL)? in
                guard let v = value as? [String: Any], let s = v["url"] as? String, s.lowercased().contains(".mp4"),
                      let url = URL(string: s) else { return nil }
                return ((v["height"] as? Int) ?? Int(key.filter(\.isNumber)) ?? 0, url)
            }
            video = mp4s.max { $0.0 < $1.0 }?.1
            streaming = video == nil
        }
        return Pin(id: id, title: String(title.prefix(120)), imageURL: image, videoURL: video, videoNeedsStreaming: streaming)
    }

    public static func pins(fromFeed data: Any?) -> [Pin] {
        (data as? [[String: Any]] ?? [])
            .filter { ($0["type"] as? String ?? "pin") == "pin" }
            .compactMap { pin(from: $0) }
    }

    /// File name for a pin: its title (or id) plus the extension from the media URL.
    public static func fileName(for pin: Pin, url: URL) -> String {
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        // Titles read best; same-named files get "(1)", "(2)" when saved. Board feeds use long internal ids.
        let base = pin.title.isEmpty ? "pin-\(pin.id.suffix(10))" : pin.title
        return FileNaming.sanitize(String(base.prefix(150)) + "." + ext)
    }
}
